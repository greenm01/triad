import std/[asyncdispatch, asyncnet, json, nativesockets, options, os, osproc, strutils]
import session_control
import ../ipc/socket
import ../core/shell_profiles
import ../daemon/shell_runner
import ../daemon/process_handle
import ../daemon/process_runner
import ../types/runtime_values
import ../types/model
import ../utils/process_options
from posix import chmod, getuid, lstat, onSignal, SIGTERM, SIGINT, SIGHUP, Mode, Stat
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
    children*: seq[Process]
    runner*: ShellRunner
    model*: Model
    niriSocketPath*: string
    ownsShell*: bool

proc getsockopt(
    fd: cint, level, option: cint, value: pointer, length: ptr cint
): cint {.importc, header: "<sys/socket.h>".}

var shutdownSignal {.volatile.}: cint

proc installShellManagerSignals() =
  onSignal(SIGTERM, SIGINT, SIGHUP):
    shutdownSignal = sig

proc peerUid(socket: AsyncSocket): int =
  var cred: Ucred
  var length = cint(sizeof(cred))
  if getsockopt(cint(socket.getFd()), SolSocket, SoPeerCred, addr cred, addr length) != 0:
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

proc reapChildren(state: ShellManagerState) =
  var index = 0
  while index < state.children.len:
    if state.children[index].peekExitCode() == -1:
      inc index
      continue
    state.children[index].close()
    state.children.delete(index)

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
      state.model = modelFromControlPayload(decoded.message.payload)
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
      let next = modelFromControlPayload(decoded.message.payload)
      if state.ownsShell and
          not sameShellsConfig(state.model.shells, next.shells):
        state.runner.switchShell(state.model, next, state.niriSocketPath, "config changed")
      state.model = next
    of SessionControlKind.WmState:
      state.model.sessionLocked = decoded.message.payload{"session_locked"}.getBool()
      state.model.layerFocusExclusive =
        decoded.message.payload{"layer_focus_exclusive"}.getBool()
    of SessionControlKind.FallbackRequest:
      let target = decoded.message.payload{"shell"}.getStr()
      if state.ownsShell and target.len > 0 and target != state.model.shells.active:
        var next = state.model
        next.shells.active = target
        state.runner.switchShell(state.model, next, state.niriSocketPath, "fallback request")
        state.model = next
    of SessionControlKind.Spawn:
      let argvNode = decoded.message.payload{"argv"}
      if argvNode == nil or argvNode.kind != JArray or argvNode.len == 0:
        continue
      var argv: seq[string] = @[]
      for item in argvNode:
        argv.add(item.getStr())
      let process = startProcess(
        argv[0],
        args = if argv.len > 1: argv[1 .. ^1] else: @[],
        options = DetachedProcessOptions,
        env = state.model.configuredProcessEnv(),
      )
      state.children.add(process)
      await client.send(
        encodeSessionControl(
          SessionControlKind.SpawnStarted, %*{"pid": process.processID}
        )
      )
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

  let state = ShellManagerState(children: @[])
  asyncCheck acceptClients(listener, state)

  try:
    while shutdownSignal == 0:
      let nowMs = monotonicMs()
      state.runner.advanceShellLifecycle(state.model, state.niriSocketPath, nowMs)
      if state.ownsShell:
        let fallback = state.runner.pollShellWatchdog(state.model, nowMs)
        if fallback.isSome and fallback.get() != state.model.shells.active:
          var next = state.model
          next.shells.active = fallback.get()
          state.runner.switchShell(
            state.model, next, state.niriSocketPath, "shell watchdog fallback"
          )
          state.model = next
        else:
          discard state.runner.pollShellRecovery(
            state.model, state.niriSocketPath, nowMs
          )
      state.runner.advanceTerminatingShells(nowMs)
      state.runner.advanceReleasedShells()
      for process in state.runner.takeOverlayProcesses():
        state.children.add(process)
      state.reapChildren()
      poll(50)
  finally:
    if state.ownsShell and state.runner.trackedProcess != nil:
      state.runner.stopTrackedShell("shutdown")

    let drainDeadlineMs = monotonicMs() + 2000'i64
    while (state.runner.pendingLaunchActive or state.runner.terminatingShells.len > 0) and
        monotonicMs() < drainDeadlineMs:
      let nowMs = monotonicMs()
      state.runner.advanceShellLifecycle(state.model, state.niriSocketPath, nowMs)
      state.runner.advanceTerminatingShells(nowMs)
      state.runner.advanceReleasedShells()
      poll(20)

    if state.runner.pendingLaunchActive:
      state.runner.pendingLaunch.process.terminateProcess()
      state.runner.pendingLaunch.process.closeProcessHandle()
      state.runner.pendingLaunchActive = false
    for child in state.children:
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
