import std/[json, strutils]

const
  SessionControlProtocolVersion* = 2
  MaxSessionControlLineBytes* = 8192

type
  SessionControlKind* {.pure.} = enum
    SessionReady
    ConfigChanged
    WmState
    Spawn
    ManagerStopping
    Shutdown
    ShellManagerReady
    SpawnStarted
    ShellState
    FallbackRequest
    Error

  SessionControlMessage* = object
    version*: int
    kind*: SessionControlKind
    payload*: JsonNode

proc encodeSessionControl*(kind: SessionControlKind, payload: JsonNode = nil): string =
  let body =
    %*{
      "version": SessionControlProtocolVersion,
      "kind": $kind,
      "payload": if payload == nil: newJObject() else: payload,
    }
  $body & "\n"

proc decodeSessionControl*(
    line: string
): tuple[ok: bool, message: SessionControlMessage, error: string] =
  if line.len == 0 or line.len > MaxSessionControlLineBytes:
    return (false, SessionControlMessage(), "control line length out of range")

  var parsed: JsonNode
  try:
    parsed = parseJson(line.strip())
  except CatchableError:
    return (false, SessionControlMessage(), "invalid control JSON")

  if parsed.kind != JObject or not parsed.hasKey("version") or
      not parsed.hasKey("kind"):
    return (false, SessionControlMessage(), "control envelope missing fields")

  if parsed["version"].kind != JInt or
      parsed["version"].getInt() != SessionControlProtocolVersion:
    return (false, SessionControlMessage(), "unsupported control protocol version")

  if parsed["kind"].kind != JString:
    return (false, SessionControlMessage(), "control kind must be a string")

  var kind: SessionControlKind
  try:
    kind = parseEnum[SessionControlKind](parsed["kind"].getStr())
  except ValueError:
    return (false, SessionControlMessage(), "unknown control kind")

  var payload = newJObject()
  if parsed.hasKey("payload"):
    if parsed["payload"].kind != JObject:
      return (false, SessionControlMessage(), "payload must be an object")
    payload = parsed["payload"]

  (
    true,
    SessionControlMessage(
      version: SessionControlProtocolVersion, kind: kind, payload: payload
    ),
    "",
  )

proc sessionControlPeerAllowed*(peerUid, expectedUid: int): bool =
  expectedUid >= 0 and peerUid == expectedUid
