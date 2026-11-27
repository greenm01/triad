import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ../src/utils/runtime_deadlines
import ../src/session/[logs, session_control, supervisor]

if paramCount() == 1 and paramStr(1) == "--test-supervisor":
  quit runSupervisor()

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

suite "session claim records":
  test "claim is held only while its claim id remains current":
    let dir = getTempDir() / ("triad-session-claim-" & $getCurrentProcessId())
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)
    defer:
      if dirExists(dir):
        removeDir(dir)

    let path = dir / "current-session.json"
    writeFile(path, """{"claim_id":"claim-a"}""")
    let claim = SessionClaim(path: path, claimId: "claim-a")
    check sessionClaimHeld(claim)

    writeFile(path, """{"claim_id":"claim-b"}""")
    check not sessionClaimHeld(claim)


suite "supervised shell recovery":
  test "rapid shell-manager failures share the supervisor restart backoff":
    let dir = createTempDir("triad-shell-recovery-", "")
    defer: removeDir(dir)
    let fakeTriad = dir / "fake-triad"
    let restarts = dir / "restarts"
    writeFile(fakeTriad, """#!/bin/sh
if [ "$1" = shell-manager ]; then
    printf 'start\n' >> "$TRIAD_TEST_RESTARTS"
    exit 1
fi
exec sleep 30
""")
    setFilePermissions(fakeTriad, {fpUserRead, fpUserWrite, fpUserExec})
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env["XDG_STATE_HOME"] = dir
    env["TRIAD_BIN"] = fakeTriad
    env["TRIAD_TEST_RESTARTS"] = restarts

    let process = startProcess(
      getAppFilename(), args = ["--test-supervisor"], env = env,
      options = {poStdErrToStdOut},
    )
    defer: process.close()
    var launches = 0
    let deadline = monotonicMs() + 10_000
    try:
      while monotonicMs() < deadline and process.peekExitCode() == -1:
        if fileExists(restarts):
          launches = readFile(restarts).count("start")
          if launches >= 3:
            break
        sleep(25)
    finally:
      if process.peekExitCode() == -1:
        process.terminate()
        if process.waitForExit(4000) == -1:
          process.kill()
          discard process.waitForExit()
    let output = process.outputStream().readAll()
    check launches >= 3
    check output.contains("restarting session components in 1000 ms")
    check output.contains("restarting session components in 2000 ms")
