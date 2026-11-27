import std/[asyncdispatch, asyncnet, json, nativesockets, options, os, osproc, strutils]
import chronicles
import session_control
import ../ipc/socket
import ../core/shell_profiles
import ../daemon/shell_runner
import ../daemon/process_handle
import ../daemon/process_runner
import ../types/runtime_values
import ../types/model
import ../utils/process_options
from posix import chmod, execvp, getppid, getuid, lstat, onSignal,
  SIGTERM, SIGINT, SIGHUP, SIGKILL, Mode, Stat
import logs
import ../utils/runtime_deadlines

const
  SolSocket = cint(1)
  SoPeerCred = cint(17)

type
  Ucred {.importc: "struct ucred", header: "<sys/socket.h>", bycopy.} = object
    pid: cint
    uid: cuint
    gid: cuint

  ShellManagerState* = ref object
    apps*: seq[Process]
    overlays*: seq[Process]
    configuredShell: string
    runner*: ShellRunner
    model*: Model
    niriSocketPath*: string
    ownsShell*: bool

proc readSocketOption(
    fd: cint, level, option: cint, value: pointer, length: ptr cint
): cint {.importc: "getsockopt", header: "<sys/socket.h>".}

when defined(linux):
  const PrSetParentDeathSignal {.importc: "PR_SET_PDEATHSIG", header: "<sys/prctl.h>".}: cint = 1
  proc setParentDeathSignal(option: cint, signal, arg3, arg4, arg5: culong): cint {.
    importc: "prctl", header: "<sys/prctl.h>".}

proc runManagedShell*(args: openArray[string]): int =
  if args.len < 2:
    return 1
  let owner = parseInt(args[0])
  if int(getppid()) != owner:
    return 1
  when defined(linux):
    if setParentDeathSignal(PrSetParentDeathSignal, culong(SIGKILL), 0, 0, 0) != 0:
      stderr.writeLine("triad: failed to watch shell manager: " & osErrorMsg(osLastError()))
      return 1
  # The owner may have exited before the kernel registered the signal.
  if int(getppid()) != owner:
    return 1
  let argv = allocCStringArray(args[1 .. ^1])
  defer: deallocCStringArray(argv)
  discard execvp(argv[0], argv)
  stderr.writeLine("triad: failed to execute shell " & args[1] & ": " & osErrorMsg(osLastError()))
  1

var shutdownSignal {.volatile.}: cint

proc installShellManagerSignals() =
  onSignal(SIGTERM, SIGINT, SIGHUP):
    shutdownSignal = sig

proc peerUid(socket: AsyncSocket): int =
  var cred: Ucred
  var length = cint(sizeof(cred))
  if readSocketOption(cint(socket.getFd()), SolSocket, SoPeerCred, addr cred, addr length) != 0:
    return -1
  int(cred.uid)

proc stringSeq(node: JsonNode): seq[string] =
  if node == nil or node.kind != JArray:
    return @[]
  for item in node:
    result.add(item.getStr())

proc profileFromJson(node: JsonNode): ShellProfileConfig =
  ShellProfileConfig(
    name: node{"name"}.getStr(),
    launch: stringSeq(node{"launch"}),
    stop: stringSeq(node{"stop"}),
    niriCompat: node{"niriCompat"}.getBool(),
  )

proc modelFromControlPayload(payload: JsonNode): Model =
  var shells = ShellsConfig(
    configured: true,
    enabled: payload{"enabled"}.getBool(true),
    active: payload{"active"}.getStr(),
    cycle: stringSeq(payload{"cycle"}),
  )
  if payload{"profiles"} != nil and payload{"profiles"}.kind == JArray:
    for item in payload{"profiles"}:
      shells.profiles.add(profileFromJson(item))
  shells.watchdog = ShellWatchdogConfig(
    enabled: payload{"watchdog", "enabled"}.getBool(),
    fallback: payload{"watchdog", "fallback"}.getStr(),
    exclusiveFocusTimeoutMs: int32(payload{"watchdog", "exclusiveFocusTimeoutMs"}.getInt()),
  )
  var model = Model(shells: shells)
  model.sessionLocked = payload{"session_locked"}.getBool()
  model.layerFocusExclusive = payload{"layer_focus_exclusive"}.getBool()
  let envNode = payload{"environment"}
  if envNode != nil and envNode.kind == JArray:
    for item in envNode:
      model.environment.add(
        EnvironmentEntryConfig(
          name: item{"name"}.getStr(),
          value: item{"value"}.getStr(),
          unset: item{"unset"}.getBool(),
        )
      )
  model

proc reapChildren(children: var seq[Process]) =
  var index = 0
  while index < children.len:
    if children[index].peekExitCode() == -1:
      inc index
      continue
    children[index].close()
    children.delete(index)

proc applyShellConfig(state: ShellManagerState, payload: JsonNode) =
  var next = modelFromControlPayload(payload)
  let configuredShell = next.shells.active
  if state.ownsShell and configuredShell == state.configuredShell and
      next.shells.hasShellProfile(state.model.shells.active):
    next.shells.active = state.model.shells.active
  if state.ownsShell and not sameShellsConfig(state.model.shells, next.shells):
    state.runner.switchShell(state.model, next, state.niriSocketPath, "config changed")
  state.configuredShell = configuredShell
  state.model = next

proc selectShell(state: ShellManagerState, target, reason: string) =
  if not state.ownsShell or target == state.model.shells.active or
      not state.model.shells.hasShellProfile(target):
    return
  var next = state.model
  next.shells.active = target
  state.runner.switchShell(state.model, next, state.niriSocketPath, reason)
  state.model = next

proc handleClient(client: AsyncSocket, state: ShellManagerState) {.async.} =
  defer:
    client.close()

  if peerUid(client) != int(getuid()):
    return

  while true:
    let line = await client.recvLine()
    if line.len == 0:
      return

    let decoded = decodeSessionControl(line & "\n")
    if not decoded.ok:
      continue

    case decoded.message.kind
    of SessionControlKind.SessionReady:
      state.niriSocketPath = decoded.message.payload{"niri_socket"}.getStr()
      state.applyShellConfig(decoded.message.payload)
      state.ownsShell = decoded.message.payload{"own_shell"}.getBool(false)
      if state.ownsShell and state.runner.trackedProcess == nil and
          not state.runner.pendingLaunchActive:
        state.runner.scheduleShellSpawn(state.model)
        state.runner.spawnPendingShell(
          state.model, state.niriSocketPath, "shell manager session-ready"
        )
      await client.send(
        encodeSessionControl(
          SessionControlKind.ShellManagerReady, %*{"pid": getCurrentProcessId()}
        )
      )
    of SessionControlKind.ConfigChanged:
      state.applyShellConfig(decoded.message.payload)
    of SessionControlKind.WmState:
      state.model.sessionLocked = decoded.message.payload{"session_locked"}.getBool()
      state.model.layerFocusExclusive =
        decoded.message.payload{"layer_focus_exclusive"}.getBool()
    of SessionControlKind.SwitchShell:
      let target = decoded.message.payload{"shell"}.getStr()
      if not state.model.shells.hasShellProfile(target):
        warn "Shell profile not found", profile = target
      else:
        state.selectShell(target, "switch-shell")
    of SessionControlKind.CycleShell:
      state.selectShell(state.model.shells.nextShellName(), "cycle-shell")
    of SessionControlKind.Spawn:
      let argv = stringSeq(decoded.message.payload{"argv"})
      var reply: string
      try:
        if argv.len == 0 or argv[0].len == 0:
          raise newException(ValueError, "spawn requires a command")
        let process = startProcess(
          argv[0], args = argv[1 .. ^1], options = DetachedProcessOptions,
          env = state.model.configuredProcessEnv(),
        )
        state.apps.add(process)
        reply = encodeSessionControl(
          SessionControlKind.SpawnStarted, %*{"pid": process.processID}
        )
      except CatchableError as e:
        let command = if argv.len > 0: argv[0] else: ""
        warn "Failed to spawn command", command = command, error = e.msg
        reply = encodeSessionControl(SessionControlKind.Error, %*{"error": e.msg})
      await client.send(reply)
    of SessionControlKind.ManagerStopping:
      discard
    of SessionControlKind.Shutdown:
      if state.ownsShell:
        state.runner.stopTrackedShell("shutdown")
      shutdownSignal = 1
      return
    else:
      discard


proc handleClientSafely(client: AsyncSocket, state: ShellManagerState) {.async.} =
  try:
    await handleClient(client, state)
  except CatchableError:
    discard
proc acceptClients(listener: AsyncSocket, state: ShellManagerState) {.async.} =
  while shutdownSignal == 0:
    let client = await listener.accept()
    asyncCheck handleClientSafely(client, state)

proc socketPathExists(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc staleManagerSocket(path: string): Future[bool] {.async.} =
  if not socketPathExists(path):
    return false
  if not unixPathIsSocket(path):
    return true
  not await unixSocketAcceptsConnections(path)

proc runShellManagerAsync() {.async.} =
  createDir(stateDir())
  let path = stateDir() / "shell-manager.sock"
  if await staleManagerSocket(path):
    removeFile(path)
  let listener = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  listener.bindUnix(path)
  listener.listen()
  discard chmod(path.cstring, Mode(0o600))

  let state = ShellManagerState(runner: ShellRunner(ownerPid: getCurrentProcessId()))
  asyncCheck acceptClients(listener, state)

  try:
    while shutdownSignal == 0:
      let nowMs = monotonicMs()
      state.runner.advanceShellLifecycle(state.model, state.niriSocketPath, nowMs)
      if state.ownsShell:
        let fallback = state.runner.pollShellWatchdog(state.model, nowMs)
        if fallback.isSome:
          state.selectShell(fallback.get(), "shell watchdog fallback")
        else:
          discard state.runner.pollShellRecovery(
            state.model, state.niriSocketPath, nowMs
          )
      state.runner.advanceTerminatingShells(nowMs)
      state.runner.advanceReleasedShells()
      state.runner.advanceStopCommands(nowMs)
      state.overlays.add(state.runner.takeOverlayProcesses())
      state.apps.reapChildren()
      state.overlays.reapChildren()
      poll(50)
  finally:
    state.runner.stopShellsForShutdown()
    let drainDeadlineMs = monotonicMs() + 2000'i64
    while state.runner.terminatingShells.len > 0 and monotonicMs() < drainDeadlineMs:
      let nowMs = monotonicMs()
      state.runner.advanceTerminatingShells(nowMs)
      state.runner.advanceReleasedShells()
      state.runner.advanceStopCommands(nowMs)
      poll(20)

    for command in state.runner.stopCommands:
      command.process.killProcess()
      command.process.closeProcessHandle()
    state.runner.stopCommands = @[]
    for app in state.apps:
      app.close()
    for child in state.overlays:
      try:
        child.terminate()
        discard child.waitForExit(1000)
        child.close()
      except CatchableError:
        discard
    listener.close()

proc runShellManager*(): int =
  installShellManagerSignals()
  waitFor runShellManagerAsync()
  0
