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

proc requestSessionControl*(
    client: SessionControlClient,
    kind: SessionControlKind,
    expected: SessionControlKind,
    payload: JsonNode = nil,
    attempts = 20,
    retryDelayMs = 100,
): Future[JsonNode] {.async.} =
  if client == nil or client.path.len == 0:
    return nil

  for _ in 0 ..< attempts:
    let socket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    var reply: JsonNode
    var sent = false
    try:
      await socket.connectUnix(client.path)
      await socket.send(encodeSessionControl(kind, payload))
      sent = true
      let line = await socket.recvLine()
      let decoded = decodeSessionControl(line & "\n")
      if decoded.ok and decoded.message.kind == expected:
        reply = decoded.message.payload
    except CatchableError:
      if sent:
        return nil
    finally:
      socket.close()
    if reply != nil:
      return reply
    await sleepAsync(retryDelayMs)
  nil

proc sendSessionControlExpect*(
    client: SessionControlClient,
    kind: SessionControlKind,
    expected: SessionControlKind,
    payload: JsonNode = nil,
    attempts = 20,
    retryDelayMs = 100,
): Future[bool] {.async.} =
  (await client.requestSessionControl(kind, expected, payload, attempts, retryDelayMs)) != nil
