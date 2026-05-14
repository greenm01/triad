import wayland/native/client
import ../core/[effects, msg, restore_state]
import ../systems/[runtime, runtime_facade]
import ../types/[model, shell_snapshot]
import ../config/[parser, reload_policy]
import ../ipc/[quickshell_compat, socket]
import ../utils/[behavior_log, runtime_log, session_env, wayland_runtime]
import
  bindings_runtime, effects_runtime, input_runtime, live_restore_runtime,
  manage_requests, message_queue, process_runner, quickshell_runner, registry_runtime,
  reload_runtime, render_runtime, state
from ../types/runtime_values import
  nil, BindingMode, KeyBindingConfig, PointerBindingConfig, PointerOpKind,
  PresentationMode, ProtocolSurfacesConfig, QuickshellConfig, Rect, RenderInstruction,
  TerminalConfig, WindowId
import
  std/
    [asyncdispatch, asyncnet, json, nativesockets, options, os, strutils, tables, times]
import fsnotify, chronicles

var daemon = initTriadDaemon()

proc failCli(message: string) =
  stderr.writeLine("triad: " & message)
  quit 1

proc configPathFromArgs(args: seq[string]): string =
  result = getEnv("TRIAD_CONFIG", "")
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg in ["-c", "--config"]:
      if i + 1 >= args.len:
        failCli(arg & " requires a config path")
      result = args[i + 1]
      inc i
    elif arg.startsWith("--config="):
      result = arg["--config=".len ..^ 1]
    inc i

  if result.len > 0:
    result = result.absoluteConfigPath()
  else:
    result = defaultConfigPath().absoluteConfigPath()

proc validateConfigFromArgs(args: seq[string]) =
  let configPath = configPathFromArgs(args)
  let loaded = loadConfigStrict(configPath)
  if not loaded.ok:
    stderr.writeLine("triad: config invalid: " & loaded.error)
    quit 1
  stdout.writeLine("triad: config valid: " & configPath)
  quit 0

proc syncRuntimeUpdate(context: string, msg: Msg): seq[Effect] =
  daemon.runtimeState.applyRuntimeUpdate(msg)

proc syncRuntimeLayoutProjection(context: string, msg: Msg): seq[RenderInstruction] =
  daemon.runtimeState.applyRuntimeLayoutProjection().instructions

proc startAnimationLoop() {.async.} =
  while true:
    {.cast(gcsafe).}:
      daemon.enqueue(Msg(kind: MsgKind.CmdTick))
    await sleepAsync(16) # ~60fps

proc startStartupWindowRulesExpiry() {.async.} =
  await sleepAsync(60_000)
  {.cast(gcsafe).}:
    daemon.enqueue(Msg(kind: MsgKind.CmdExpireStartupWindowRules))

proc processQueuedMessages(configPath, niriSocketPath: string): bool =
  while daemon.hasQueuedMessages():
    let msg = daemon.popQueuedMessage()

    if msg.kind == MsgKind.WlPointerRelease:
      if daemon.runtimeState.model.pointerOp.kind != PointerOpKind.OpNone:
        if daemon.lastPointerOpSeat != nil:
          daemon.executeEffect(
            Effect(kind: EffectKind.EffOpEnd, endSeat: daemon.lastPointerOpSeat)
          )

    if msg.kind == MsgKind.CmdSpawnTerminal:
      spawnTerminal(daemon.runtimeState.model)
      continue

    if msg.kind == MsgKind.CmdConfigReload:
      if daemon.applyConfigReload(configPath, niriSocketPath):
        result = true
      continue

    if msg.kind == MsgKind.CmdTick:
      daemon.tickCursorShake()

    let previousOverview = daemon.runtimeState.model.overviewActive
    let previousRecentWindows = daemon.runtimeState.model.recentWindowsActive
    let previousSessionLocked = daemon.runtimeState.model.sessionLocked
    let previousActiveModifiers = daemon.runtimeState.model.activeModifiers
    let previousShortcutsInhibited =
      daemon.runtimeState.model.keyboardShortcutsInhibited()
    let effects = syncRuntimeUpdate("message", msg)
    let recentModifiersChanged =
      daemon.runtimeState.model.recentWindowsActive and
      previousActiveModifiers != daemon.runtimeState.model.activeModifiers
    if previousOverview != daemon.runtimeState.model.overviewActive or
        previousRecentWindows != daemon.runtimeState.model.recentWindowsActive or
        previousSessionLocked != daemon.runtimeState.model.sessionLocked or
        recentModifiersChanged or
        previousShortcutsInhibited !=
        daemon.runtimeState.model.keyboardShortcutsInhibited():
      daemon.requestBindingReconfigure("binding profile changed")

    if msg.kind == MsgKind.WlManageStart:
      daemon.riverPhase = RiverPhase.RiverManage
      let instructions = syncRuntimeLayoutProjection("manage layout", msg)
      daemon.proposeDesiredDimensions(instructions)
      daemon.applyManageState()
      daemon.flushPendingManageEffects()
      for eff in effects:
        if eff.kind != EffectKind.EffManageDirty:
          daemon.executeEffect(eff)
      daemon.executeEffect(Effect(kind: EffectKind.EffManageFinish))
      daemon.riverPhase = RiverPhase.RiverIdle
      if not daemon.initialManageComplete:
        daemon.initialManageComplete = true
        info "Initial manage completed",
          outputs = daemon.outputPointers.len,
          windows = daemon.windowPointers.len,
          seats = daemon.seatPointers.len
      daemon.spawnPendingStartupCommands(daemon.runtimeState.model, "initial manage")
      if daemon.postManageBroadcastPending:
        let reason = daemon.postManageBroadcastReason
        daemon.postManageBroadcastPending = false
        daemon.postManageBroadcastReason = ""
        let snapshot = daemon.readModelSnapshot()
        writeBehaviorEvent(
          "niri_compat_post_manage_broadcast",
          %*{"reason": reason, "snapshot": snapshot.snapshotBehaviorPayload()},
        )
        broadcastNiriSnapshot(snapshot)
      continue

    if msg.kind == MsgKind.WlRenderStart:
      daemon.riverPhase = RiverPhase.RiverRender
      let instructions = syncRuntimeLayoutProjection("render layout", msg)
      daemon.recordDesiredPlacements(instructions)
      daemon.renderDesiredPlacements()
      for windowId in daemon.runtimeState.pendingAdmissionWindowIds():
        daemon.enqueue(
          Msg(kind: MsgKind.WlWindowAdmissionSettled, admissionWindowId: windowId)
        )
      daemon.executeEffect(Effect(kind: EffectKind.EffRenderFinish))
      daemon.riverPhase = RiverPhase.RiverIdle
      continue

    for eff in effects:
      daemon.executeEffect(eff)

proc hasInitialRiverState(): bool =
  daemon.outputPointers.len > 0 or daemon.seatPointers.len > 0

proc waitForInitialRiverState(timeoutMs: int): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while not hasInitialRiverState() and epochTime() < deadline:
    if not dispatchPendingWayland(daemon.display):
      return false
    if hasInitialRiverState():
      return true
    if not prepareWaylandRead(daemon.display):
      return false
    if hasInitialRiverState():
      daemon.display.cancel_read()
      return true

    discard daemon.display.flush()
    let remainingMs = max(1, min(16, int((deadline - epochTime()) * 1000.0)))
    if waitForWaylandEvents(daemon.display, remainingMs):
      if daemon.display.read_events() == -1:
        return false
    else:
      daemon.display.cancel_read()

  hasInitialRiverState()

# --- Main Loop ---

proc main*() =
  let args = commandLineParams()
  if args.len > 0 and args[0] in ["validate-config", "check-config"]:
    let validateArgs =
      if args.len > 1:
        args[1 ..^ 1]
      else:
        @[]
    validateConfigFromArgs(validateArgs)

  if args.len >= 1 and args[0] == "msg":
    if args.len < 2:
      failCli("missing msg command")
    let cmdPart = args[1]
    if cmdPart == "event-stream":
      # Subscription client
      let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      try:
        waitFor client.connectUnix(triadSocketPath())
        waitFor client.send("event-stream\L")
        while not client.isClosed:
          let line = waitFor client.recvLine()
          if line != "":
            echo line
      except CatchableError as e:
        if not client.isClosed:
          client.close()
        failCli("event stream failed: " & e.msg)
      return

    var cmd = ""
    for i in 1 ..< args.len:
      if i > 1:
        cmd.add(" ")
      cmd.add(args[i])
    try:
      if cmd == "dump-live-restore-state":
        let reply = waitFor sendIpcRequest(triadSocketPath(), cmd)
        stdout.writeLine(reply)
      else:
        waitFor sendIpcMsg(triadSocketPath(), cmd)
    except CatchableError as e:
      failCli("socket request failed: " & e.msg)
    return

  configureLogging()

  info "Triad process starting",
    pid = getCurrentProcessId(),
    runtimeDir = runtimeDir(),
    waylandDisplay = getEnv("WAYLAND_DISPLAY", "")

  daemon.pendingLiveRestorePath = defaultLiveRestorePath()
  let hadRestoreSnapshot = fileExists(daemon.pendingLiveRestorePath)
  if hadRestoreSnapshot and getEnv("TRIAD_BEHAVIOR_LOG", "").len == 0 and
      not liveRestoreStateApplied(daemon.pendingLiveRestorePath):
    putEnv("TRIAD_BEHAVIOR_LOG", "1")

  let sessionProblem = currentWaylandSessionProblem()
  if sessionProblem.len > 0:
    fatal "Refusing to start outside a Wayland session", reason = sessionProblem
    quit 1

  daemon.display = connectDisplay(nil)
  if daemon.display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  daemon.registry = daemon.display.getRegistry()
  discard daemon.registry.addListener(registryListener.addr, daemonData(daemon))

  let roundtripResult = daemon.display.roundtrip()
  debug "Wayland registry roundtrip finished", result = roundtripResult

  if daemon.riverManager == nil:
    fatal "river_window_manager_v1 not advertised; Triad must run inside River 0.4+"
    quit 1

  let managerRoundtripResult = daemon.display.roundtrip()
  debug "River manager roundtrip finished",
    result = managerRoundtripResult,
    outputs = daemon.outputPointers.len,
    pendingWindows = pendingWindows.len,
    seats = daemon.seatPointers.len
  if managerRoundtripResult == -1:
    fatal "Failed during River manager initialization roundtrip"
    quit 1

  # Setup and Load Config
  daemon.setupConfig(configPathFromArgs(args))
  let initialLoaded = loadConfigStrict(daemon.configPath)
  let initialConfig =
    if initialLoaded.ok:
      daemon.configWatchPaths = initialLoaded.configPaths
      initialLoaded.config
    else:
      warn "Initial config strict validation failed; falling back to permissive load",
        path = daemon.configPath, error = initialLoaded.error
      daemon.configWatchPaths = @[daemon.configPath]
      loadConfig(daemon.configPath)
  daemon.runtimeState = initRuntimeStateFromConfig(initialConfig)
  daemon.installInputRuntimeHooks()
  daemon.configureXkbKeymap("initial config")
  daemon.applyAllInputConfig("initial config")
  info "Initial config loaded", path = daemon.configPath

  daemon.pendingLiveRestore = loadLiveRestoreState(daemon.pendingLiveRestorePath)
  if daemon.pendingLiveRestore.isSome:
    let state = daemon.pendingLiveRestore.get()
    info "Live restore snapshot loaded",
      path = daemon.pendingLiveRestorePath,
      activeTag = state.activeTag,
      windows = state.tagByWindow.len
    writeLiveRestoreBehaviorEvent(
      "live_restore_loaded", daemon.pendingLiveRestorePath, "startup", state
    )
  elif hadRestoreSnapshot and liveRestoreStateApplied(daemon.pendingLiveRestorePath):
    info "Applied live restore snapshot retained", path = daemon.pendingLiveRestorePath
  elif hadRestoreSnapshot:
    if quarantineLiveRestoreState(daemon.pendingLiveRestorePath):
      warn "Invalid live restore snapshot quarantined",
        path = daemon.pendingLiveRestorePath
    else:
      warn "Invalid live restore snapshot could not be quarantined",
        path = daemon.pendingLiveRestorePath

  if daemon.pendingLiveRestore.isSome and not hasInitialRiverState():
    info "Live restore handoff waiting for initial River state",
      path = daemon.pendingLiveRestorePath
    if not waitForInitialRiverState(250):
      warn "Live restore handoff has no initial River state; retrying startup",
        path = daemon.pendingLiveRestorePath
      quit 0

  info "Triad connected to River",
    outputs = daemon.outputPointers.len, seats = daemon.seatPointers.len

  daemon.applyPendingLiveRestore("startup")

  # Setup Watcher
  daemon.watcher = initWatcher()
  proc onConfigChange(events: seq[PathEvent]) {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.configReloadDebouncer.schedule(int64(epochTime() * 1000.0))

  proc configureConfigWatcher() =
    daemon.watcher = initWatcher()
    let paths =
      if daemon.configWatchPaths.len > 0:
        daemon.configWatchPaths
      else:
        @[daemon.configPath]
    daemon.watcher.register(paths, onConfigChange, treatAsFile = true)

  configureConfigWatcher()

  # Start IPC Server
  proc queueMsg(msg: Msg) {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.enqueue(msg)

  proc snapshotModel(): ShellSnapshot {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.readModelSnapshot()

  proc snapshotLiveRestoreJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.readLiveRestoreJson()

  let triadSocket = triadSocketPath()
  let niriSocketPath = chooseNiriCompatSocketPath(triadSocket)
  var ipcStarted = false

  proc startIpcServers() =
    if ipcStarted:
      return
    ipcStarted = true
    info "Starting Triad IPC server", path = triadSocket
    writeBehaviorEvent("triad_ipc_server_starting", %*{"path": triadSocket})
    asyncCheck startIpcServer(
      triadSocket, queueMsg, snapshotModel, snapshotLiveRestoreJson
    )

    if niriSocketPath.len > 0 and niriSocketPath != triadSocket:
      info "Starting Niri-compatible IPC server", path = niriSocketPath
      writeBehaviorEvent("niri_compat_ipc_server_starting", %*{"path": niriSocketPath})
      asyncCheck startIpcServer(
        niriSocketPath, queueMsg, snapshotModel, snapshotLiveRestoreJson
      )

  # Start Animation Loop
  asyncCheck startAnimationLoop()
  asyncCheck startStartupWindowRulesExpiry()

  # Spawn startup commands after River accepts the initial manage pass.
  daemon.scheduleStartupCommands(daemon.runtimeState.model)
  daemon.quickshellState.scheduleQuickshellSpawn(daemon.runtimeState.model)

  var running = true
  while running:
    if not dispatchPendingWayland(daemon.display):
      break

    # Poll watcher (non-blocking)
    daemon.watcher.poll(0)

    # Poll async (IPC)
    asyncdispatch.poll(16)

    if daemon.configReloadDebouncer.takeDue(int64(epochTime() * 1000.0)):
      daemon.enqueue(Msg(kind: MsgKind.CmdConfigReload))

    # Process Message Queue
    if processQueuedMessages(daemon.configPath, niriSocketPath):
      configureConfigWatcher()
    if daemon.shouldExit:
      running = false
      continue

    if daemon.initialManageComplete:
      startIpcServers()
      daemon.quickshellState.spawnPendingQuickshell(
        daemon.runtimeState.model, niriSocketPath, "initial manage"
      )

    daemon.flushManageRequest()

    if not prepareWaylandRead(daemon.display):
      break

    discard daemon.display.flush()
    if waitForWaylandEvents(daemon.display, 16):
      if daemon.display.read_events() == -1:
        running = false
    else:
      daemon.display.cancel_read()

if isMainModule:
  main()
