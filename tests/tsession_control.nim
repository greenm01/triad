import std/[json, strutils, unittest]
import ../src/session/session_control

suite "session control protocol":
  test "round-trips a versioned message":
    let line = encodeSessionControl(
      SessionControlKind.SpawnStarted, %*{"pid": 4321}
    )
    let decoded = decodeSessionControl(line)
    check decoded.ok
    check decoded.message.version == SessionControlProtocolVersion
    check decoded.message.kind == SessionControlKind.SpawnStarted
    check decoded.message.payload["pid"].getInt() == 4321

  test "rejects a mismatched protocol version":
    let line = """{"version":1,"kind":"Shutdown","payload":{}}""" & "\n"
    let decoded = decodeSessionControl(line)
    check not decoded.ok
    check decoded.error.contains("version")

  test "rejects oversized lines":
    let line = repeat("x", MaxSessionControlLineBytes + 1)
    let decoded = decodeSessionControl(line)
    check not decoded.ok
    check decoded.error.contains("length")

  test "rejects unknown control kinds":
    let line = """{"version":2,"kind":"Nope","payload":{}}""" & "\n"
    let decoded = decodeSessionControl(line)
    check not decoded.ok
    check decoded.error.contains("kind")

  test "only allows the expected peer uid":
    check sessionControlPeerAllowed(1000, 1000)
    check not sessionControlPeerAllowed(1001, 1000)
    check not sessionControlPeerAllowed(-1, -1)

  test "rejects non-object payloads":
    let line = """{"version":2,"kind":"Shutdown","payload":[]}""" & "\n"
    let decoded = decodeSessionControl(line)
    check not decoded.ok
    check decoded.error.contains("payload")
