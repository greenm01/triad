import std/[asyncdispatch, os]
import ipc/[niri_cli, socket]

proc socketPath(): string =
  let niriSocket = getEnv("NIRI_SOCKET", "")
  if niriSocket.len > 0:
    return niriSocket
  triadSocketPath()

proc fail(message: string) =
  stderr.writeLine("triad_niri: " & message)
  quit 1

when isMainModule:
  let request = buildNiriCliRequest(commandLineParams())

  case request.kind
  of NiriCliKind.NckValidate:
    quit 0
  of NiriCliKind.NckInvalid:
    fail(request.error)
  of NiriCliKind.NckRequest:
    let path = socketPath()
    var reply = ""
    try:
      reply = waitFor sendIpcRequest(path, request.socketPayload)
    except CatchableError as e:
      fail("socket request failed: " & e.msg)

    let unwrapped = unwrapNiriReply(reply, request.unwrapKey)
    if not unwrapped.ok:
      fail(unwrapped.output)

    if unwrapped.output.len > 0:
      stdout.writeLine(unwrapped.output)
