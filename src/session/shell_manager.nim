import std/[asyncdispatch, asyncnet, json, nativesockets, os, osproc, strutils]
import session_control
import ../utils/process_options
from posix import chmod, getuid, onSignal, SIGTERM, SIGINT, SIGHUP, Mode
import logs

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
      )
      state.children.add(process)
      await client.send(
        encodeSessionControl(
          SessionControlKind.SpawnStarted, %*{"pid": process.processID}
        )
      )
    of SessionControlKind.Shutdown:
      shutdownSignal = 1
      return
    else:
      discard

proc acceptClients(listener: AsyncSocket, state: ShellManagerState) {.async.} =
  while shutdownSignal == 0:
    let client = await listener.accept()
    asyncCheck handleClient(client, state)

proc runShellManagerAsync() {.async.} =
  createDir(stateDir())
  let path = stateDir() / "shell-manager.sock"
  if fileExists(path):
    removeFile(path)

  let listener = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  listener.bindUnix(path)
  listener.listen()
  discard chmod(path.cstring, Mode(0o600))
  let state = ShellManagerState(children: @[])
  asyncCheck acceptClients(listener, state)

  while shutdownSignal == 0:
    state.reapChildren()
    poll(50)

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
