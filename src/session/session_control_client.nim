import std/[asyncdispatch, asyncnet, json, nativesockets]
import session_control

type SessionControlClient* = ref object
  path*: string

proc newSessionControlClient*(path: string): SessionControlClient =
  SessionControlClient(path: path)

proc sendSessionControl*(
    client: SessionControlClient, kind: SessionControlKind, payload: JsonNode = nil
): Future[bool] {.async.} =
  if client == nil or client.path.len == 0:
    return false

  let socket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    await socket.connectUnix(client.path)
    await socket.send(encodeSessionControl(kind, payload))
    return true
  except CatchableError:
    return false
  finally:
    socket.close()
