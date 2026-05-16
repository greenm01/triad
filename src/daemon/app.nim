import wayland/native/client
import ../core/[defaults, effects, msg, restore_state, shell_profiles]
import ../systems/[runtime, runtime_facade]
import ../state/engine
import ../types/[model, shell_snapshot]
import ../types/projection_values
import ../config/[parser, reload_policy]
from ../ipc/quickshell_compat import chooseNiriCompatSocketPath
import ../ipc/socket
import ../janet/runtime as janet_runtime
import ../utils/[behavior_log, runtime_log, session_env, wayland_runtime]
import
  bindings_runtime, effects_runtime, input_runtime, janet_manifest_runtime,
  live_restore_runtime, manage_requests, message_queue, output_management_runtime,
  process_runner, quickshell_runner, registry_runtime, reload_runtime, render_runtime,
  state, switch_event_runtime
from ../types/runtime_values import nil, PointerOpKind
import
  std/[
    asyncdispatch, asyncnet, json, nativesockets, options, os, sequtils, strutils,
    tables, times,
  ]
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
  daemon.runtimeState.applyRuntimeLayoutProjection(context, $msg.kind).instructions

proc refreshRateFps(refreshRate: int32): int32 =
  if refreshRate <= 0:
    return 0
  max(1'i32, (refreshRate + 500) div 1000)

proc frameRate(model: Model): int32 =
  if model.frameRate > 0:
    return min(MaxFrameRate, max(MinFrameRate, model.frameRate))

  let active = model.outputData(model.activeOutput)
  if active.isSome:
    let fps = active.get().refreshRate.refreshRateFps()
    if fps > 0:
      return min(MaxFrameRate, max(MinFrameRate, fps))

  let primary = model.outputData(model.primaryOutput)
  if primary.isSome:
    let fps = primary.get().refreshRate.refreshRateFps()
    if fps > 0:
      return min(MaxFrameRate, max(MinFrameRate, fps))

  FallbackFrameRate

proc frameIntervalMs(fps: int32): int =
  if fps == FallbackFrameRate:
    return int(DefaultFrameIntervalMs)
  max(1, int(1000.0 / float(max(1'i32, fps)) + 0.5))

proc targetFrameIntervalMs(daemon: TriadDaemon): int =
  daemon.runtimeState.model.frameRate().frameIntervalMs()

proc unixMs(): int64 =
  int64(epochTime() * 1000.0)

proc cursorShakeTickNeeded(daemon: TriadDaemon): bool =
  for state in daemon.cursorShakeBySeat.values:
    if state.enlarged:
      return true

proc cursorVisibilityTickNeeded(daemon: TriadDaemon): bool =
  if daemon.runtimeState.model.cursor.hideAfterInactiveMs <= 0:
    return daemon.cursorHiddenPointers.len > 0
  for pointerId in daemon.cursorLastMotionMsByPointer.keys:
    if not daemon.cursorHiddenPointers.getOrDefault(pointerId, false):
      if daemon.cursorShapeDevices.hasKey(pointerId) and
          daemon.wlPointerGlobalNames.hasKey(pointerId) and
          daemon.wlPointerPointers.hasKey(daemon.wlPointerGlobalNames[pointerId]):
        return true

proc frameTickNeeded(daemon: TriadDaemon): bool =
  daemon.runtimeState.model.needsFrameTick() or daemon.cursorShakeTickNeeded() or
    daemon.cursorVisibilityTickNeeded()

proc frameTickReasons(daemon: TriadDaemon): seq[string] =
  result = daemon.runtimeState.model.frameTickReasons()
  if daemon.cursorShakeTickNeeded():
    result.add("cursor-shake")
  if daemon.cursorVisibilityTickNeeded():
    result.add("cursor-visibility")

proc enqueueFrameTickIfDue(daemon: var TriadDaemon, nowMs: int64) =
  if not daemon.frameTickNeeded():
    daemon.lastFrameTickMs = nowMs
    return
  if daemon.lastFrameTickMs <= 0:
    daemon.lastFrameTickMs = nowMs
  let elapsedMs = nowMs - daemon.lastFrameTickMs
  let frameInterval = int64(daemon.targetFrameIntervalMs())
  if elapsedMs < frameInterval:
    return
  daemon.lastFrameTickMs = nowMs
  daemon.enqueue(
    Msg(
      kind: MsgKind.CmdTick, tickElapsedMs: int32(max(1'i64, min(1000'i64, elapsedMs)))
    )
  )

proc loopPollIntervalMs(daemon: TriadDaemon, nowMs: int64): int =
  result = daemon.targetFrameIntervalMs()
  if daemon.frameTickNeeded():
    let frameInterval = int64(daemon.targetFrameIntervalMs())
    let elapsedMs =
      if daemon.lastFrameTickMs <= 0:
        frameInterval
      else:
        nowMs - daemon.lastFrameTickMs
    result = max(1, int(max(1'i64, frameInterval - elapsedMs)))
  if daemon.configReloadDebouncer.pending:
    result = min(result, max(1, int(daemon.configReloadDebouncer.deadlineMs - nowMs)))

proc perfStatusJson(daemon: TriadDaemon): string =
  let counters = daemon.perfCounters
  var manageRequestReasons = newJObject()
  for reason, count in daemon.manageRequestReasonCounts.pairs:
    manageRequestReasons[reason] = %int(count)
  $(
    %*{
      "ok": true,
      "type": "perf-status",
      "frame_rate": daemon.runtimeState.model.frameRate(),
      "frame_interval_ms": daemon.targetFrameIntervalMs(),
      "frame_tick_active": daemon.frameTickNeeded(),
      "frame_tick_reasons": daemon.frameTickReasons(),
      "counters": {
        "frame_ticks": counters.frameTicks,
        "active_frame_ticks": counters.activeFrameTicks,
        "dirty_frame_ticks": counters.dirtyFrameTicks,
        "render_starts": counters.renderStarts,
        "render_requests": counters.renderRequests,
        "skipped_render_requests": counters.skippedRenderRequests,
        "manage_requests": counters.manageRequests,
      },
      "manage_request_reasons": manageRequestReasons,
    }
  )

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
        daemon.janetRuntime.configure(daemon.runtimeState.model.janet)
        daemon.configureSwitchEventRuntime("config reload")
        result = true
      continue

    if msg.kind == MsgKind.CmdTick:
      inc daemon.perfCounters.frameTicks
      if daemon.frameTickNeeded():
        inc daemon.perfCounters.activeFrameTicks
      daemon.tickCursorShake()
      daemon.tickCursorVisibility()

    let previousModelForShell = daemon.runtimeState.model
    let previousOverview = daemon.runtimeState.model.overviewActive
    let previousRecentWindows = daemon.runtimeState.model.recentWindowsActive
    let previousSessionLocked = daemon.runtimeState.model.sessionLocked
    let previousExitSessionConfirm = daemon.runtimeState.model.exitSessionConfirmOpen
    let previousActiveModifiers = daemon.runtimeState.model.activeModifiers
    let previousShortcutsInhibited =
      daemon.runtimeState.model.keyboardShortcutsInhibited()
    let effects = syncRuntimeUpdate("message", msg)
    if msg.kind == MsgKind.CmdTick and
        effects.anyIt(it.kind == EffectKind.EffManageDirty):
      inc daemon.perfCounters.dirtyFrameTicks
    if msg.kind in {MsgKind.CmdSwitchShell, MsgKind.CmdCycleShell} and
        not sameShellsConfig(
          previousModelForShell.shells, daemon.runtimeState.model.shells
        ):
      daemon.quickshellState.switchShell(
        previousModelForShell,
        daemon.runtimeState.model,
        niriSocketPath,
        "command " & $msg.kind,
      )
    if msg.kind == MsgKind.WlWindowCreated:
      let snapshot = daemon.readModelSnapshot()
      let fallbackWindow = ShellWindow(
        id: msg.windowId,
        pid: msg.createdPid,
        parentId: msg.createdParentWindowId,
        title: msg.title,
        appId: msg.appId,
        identifier: msg.createdIdentifier,
      )
      let currentWindow = snapshot.snapshotWindow(msg.windowId, fallbackWindow)
      let manifestResult =
        daemon.runWindowManifest(msg.appId, snapshot, currentWindow, "window_created")
      if manifestResult.messages.len > 0 and not snapshot.snapshotHasWindow(
        msg.windowId
      ):
        daemon.pendingManifestAdmissionWindows[msg.windowId] = msg.appId
      if not msg.appId.manifestAppIdReady():
        daemon.pendingManifestAppIdWindows[msg.windowId] = true
    elif msg.kind == MsgKind.WlWindowAppId:
      if daemon.pendingManifestAppIdWindows.hasKey(msg.appIdWindowId) and
          msg.updatedAppId.manifestAppIdReady():
        daemon.pendingManifestAppIdWindows.del(msg.appIdWindowId)
        let snapshot = daemon.readModelSnapshot()
        let fallbackWindow = ShellWindow(id: msg.appIdWindowId, appId: msg.updatedAppId)
        let currentWindow = snapshot.snapshotWindow(msg.appIdWindowId, fallbackWindow)
        let manifestResult = daemon.runWindowManifest(
          msg.updatedAppId, snapshot, currentWindow, "window_app_id"
        )
        if manifestResult.messages.len > 0 and
            not snapshot.snapshotHasWindow(msg.appIdWindowId):
          daemon.pendingManifestAdmissionWindows[msg.appIdWindowId] = msg.updatedAppId
    elif msg.kind == MsgKind.WlWindowAdmissionSettled:
      if daemon.pendingManifestAdmissionWindows.hasKey(msg.admissionWindowId):
        let pendingAppId = daemon.pendingManifestAdmissionWindows[msg.admissionWindowId]
        daemon.pendingManifestAdmissionWindows.del(msg.admissionWindowId)
        let snapshot = daemon.readModelSnapshot()
        let fallbackWindow = ShellWindow(id: msg.admissionWindowId, appId: pendingAppId)
        let currentWindow =
          snapshot.snapshotWindow(msg.admissionWindowId, fallbackWindow)
        let appId =
          if currentWindow.appId.manifestAppIdReady():
            currentWindow.appId
          else:
            pendingAppId
        if appId.manifestAppIdReady():
          discard
            daemon.runWindowManifest(appId, snapshot, currentWindow, "window_admitted")
    elif msg.kind == MsgKind.WlWindowDestroyed:
      daemon.pendingManifestAppIdWindows.del(msg.destroyedId)
      daemon.pendingManifestAdmissionWindows.del(msg.destroyedId)
      daemon.lastFullscreenRequests.del(msg.destroyedId)
      daemon.lastMaximizedRequests.del(msg.destroyedId)
    let recentModifiersChanged =
      daemon.runtimeState.model.recentWindowsActive and
      previousActiveModifiers != daemon.runtimeState.model.activeModifiers
    if previousOverview != daemon.runtimeState.model.overviewActive or
        previousRecentWindows != daemon.runtimeState.model.recentWindowsActive or
        previousSessionLocked != daemon.runtimeState.model.sessionLocked or
        previousExitSessionConfirm != daemon.runtimeState.model.exitSessionConfirmOpen or
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
      inc daemon.perfCounters.renderStarts
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
      if eff.kind == EffectKind.EffManageDirty:
        daemon.requestManage("effect:" & $msg.kind)
      else:
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
      if cmd == "dump-live-restore-state" or cmd == "perf-status" or cmd == "dev-mode" or
          cmd.startsWith("dev-mode "):
        let reply = waitFor sendIpcRequest(triadSocketPath(), cmd)
        stdout.writeLine(reply)
      else:
        waitFor sendIpcMsg(triadSocketPath(), cmd)
    except CatchableError as e:
      failCli("socket request failed: " & e.msg)
    return

  configureDevMode(args)
  configureLogging()

  info "Triad process starting",
    pid = getCurrentProcessId(),
    runtimeDir = runtimeDir(),
    waylandDisplay = getEnv("WAYLAND_DISPLAY", ""),
    devMode = devModeEnabled(),
    behaviorLog = behaviorLogEnabled()

  daemon.pendingLiveRestorePath = defaultLiveRestorePath()
  let hadRestoreSnapshot = fileExists(daemon.pendingLiveRestorePath)

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
  daemon.janetRuntime = initJanetRuntime(daemon.runtimeState.model.janet)
  daemon.installInputRuntimeHooks()
  daemon.configureXkbKeymap("initial config")
  daemon.applyAllInputConfig("initial config")
  daemon.resetOutputManagementRetry()
  daemon.applyOutputManagementConfig("initial config")
  daemon.configureSwitchEventRuntime("initial config")
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

  proc snapshotPerfStatusJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.perfStatusJson()

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
      triadSocket, queueMsg, snapshotModel, snapshotLiveRestoreJson,
      snapshotPerfStatusJson,
    )

    if niriSocketPath.len > 0 and niriSocketPath != triadSocket:
      info "Starting Niri-compatible IPC server", path = niriSocketPath
      writeBehaviorEvent("niri_compat_ipc_server_starting", %*{"path": niriSocketPath})
      asyncCheck startIpcServer(
        niriSocketPath, queueMsg, snapshotModel, snapshotLiveRestoreJson,
        snapshotPerfStatusJson,
      )

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
    daemon.pollSwitchEventDevices()

    let nowMs = unixMs()
    daemon.enqueueFrameTickIfDue(nowMs)
    let pollInterval = daemon.loopPollIntervalMs(nowMs)

    # Poll async IPC without sleeping before Wayland events are serviced.
    asyncdispatch.poll(0)

    if daemon.configReloadDebouncer.takeDue(unixMs()):
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
      let shellPollMs = int64(epochTime() * 1000.0)
      let watchdogFallback =
        daemon.quickshellState.pollShellWatchdog(daemon.runtimeState.model, shellPollMs)
      if watchdogFallback.isSome:
        daemon.enqueue(
          Msg(kind: MsgKind.CmdSwitchShell, shellName: watchdogFallback.get())
        )
      else:
        discard daemon.quickshellState.pollQuickshellRecovery(
          daemon.runtimeState.model, niriSocketPath, shellPollMs
        )

    daemon.flushManageRequest()

    if not prepareWaylandRead(daemon.display):
      break

    discard daemon.display.flush()
    if waitForWaylandEvents(daemon.display, pollInterval):
      if daemon.display.read_events() == -1:
        running = false
    else:
      daemon.display.cancel_read()

  daemon.closeSwitchEventDevices()
  daemon.janetRuntime.close()

if isMainModule:
  main()
