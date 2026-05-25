import std/[json, os, sequtils, strutils]
import live_paths, logs

type
  LiveDoctorError* = object of CatchableError

  RunningDaemon* = object
    pid*: int
    perfStatusCompatible*: bool
    pidFromPerfStatus*: bool

proc fail(prefix, message: string) {.noreturn.} =
  failMessage(prefix, message)
  raise newException(LiveDoctorError, message)

proc isExecutable(path: string): bool =
  fileExists(path) and fpUserExec in getFilePermissions(path)

proc latestProcessMatchingCommand(commandNeedle: string): int =
  for kind, path in walkDir("/proc"):
    if kind != pcDir:
      continue
    let name = path.extractFilename()
    if name.len == 0 or name.anyIt(it notin Digits):
      continue
    let pid = parseInt(name)
    let exe = processExe(pid).extractFilename()
    if exe notin ["sh", "bash", "dash", "busybox"]:
      continue
    let cmdlinePath = path / "cmdline"
    if not fileExists(cmdlinePath):
      continue
    let cmdline = readFile(cmdlinePath).replace('\0', ' ')
    if commandNeedle in cmdline and pid > result:
      result = pid

proc latestLiveTriadPid*(paths: LivePaths): int =
  for kind, path in walkDir("/proc"):
    if kind != pcDir:
      continue
    let name = path.extractFilename()
    if name.len == 0 or name.anyIt(it notin Digits):
      continue
    let pid = parseInt(name)
    if processExe(pid) == paths.liveTriad and pid > result:
      result = pid

proc writeRestartMarker(paths: LivePaths) =
  let marker = paths.managerLoopRestartMarker()
  createDir(marker.parentDir())
  let managerPid = latestProcessMatchingCommand(paths.liveManagerLoop)
  writeFile(
    marker,
    paths.liveManagerLoop & "\n" & isoNow() & "\nmanager_pid=" & $managerPid & "\n",
  )

proc restartRequired(paths: LivePaths, reason: string) {.noreturn.} =
  paths.writeRestartMarker()
  fail(
    "doctor-live",
    reason & "; restart the River/Triad session so River execs the current supervisor, " &
      "then retry nimble liveReload. restart marker: " & paths.managerLoopRestartMarker(),
  )

proc syncPackagedScript(paths: LivePaths, src, dst, name: string) =
  if not fileExists(src):
    fail("doctor-live", "missing repo " & name & " script: " & src)
  if isExecutable(dst) and sameFileContent(src, dst):
    return
  atomicInstall(src, dst, 0o755)
  paths.restartRequired("installed updated " & name & " at " & dst)

proc checkRestartMarker(paths: LivePaths) =
  let marker = paths.managerLoopRestartMarker()
  if not fileExists(marker):
    return

  let lines = readFile(marker).splitLines()
  let markerLoop =
    if lines.len > 0:
      lines[0]
    else:
      ""
  if markerLoop.len > 0 and markerLoop != paths.liveManagerLoop:
    info(
      "doctor-live", "ignoring restart marker for different manager loop: " & markerLoop
    )
    return

  let managerPid = latestProcessMatchingCommand(paths.liveManagerLoop)
  var markerPid = 0
  for line in lines:
    if line.startsWith("manager_pid="):
      try:
        markerPid = parseInt(line["manager_pid=".len ..^ 1])
      except ValueError:
        markerPid = 0
  if managerPid > 0 and markerPid > 0 and managerPid != markerPid:
    removeFile(marker)
    info(
      "doctor-live",
      "cleared stale restart marker after manager pid changed to " & $managerPid,
    )
    return

  fail(
    "doctor-live",
    "restart still required after support script update; restart the River/Triad session, then retry",
  )

proc checkLiveTriadBinary(paths: LivePaths) =
  if not isExecutable(paths.liveTriad):
    fail(
      "doctor-live",
      "installed live triad is missing or not executable: " & paths.liveTriad &
        "; run nimble installSession",
    )

  let logsResult = runProcess(paths.liveTriad, ["logs", "--json"], timeoutMs = 1000)
  if logsResult.status != 0:
    for line in logsResult.output.splitLines():
      if line.len > 0:
        failMessage("doctor-live", "live triad logs check " & line)
    fail(
      "doctor-live",
      "installed live triad is stale or incompatible: " & paths.liveTriad &
        "; it must support offline 'triad logs --json'; run nimble installSession",
    )
  let logsPayload = parseJsonObject(logsResult.output)
  if logsPayload.kind != JObject or not logsPayload.hasKey("ok"):
    fail(
      "doctor-live",
      "installed live triad returned malformed logs JSON: " & paths.liveTriad &
        "; run nimble installSession",
    )

  let help = runProcess(paths.liveTriad, ["--help"], timeoutMs = 1000).output
  for command in ["session", "supervise", "logs"]:
    if ("triad " & command) notin help and (" " & command & " ") notin help:
      fail(
        "doctor-live",
        "installed live triad is stale: " & paths.liveTriad & "; help is missing the " &
          command & " command; run nimble installSession",
      )

  info(
    "doctor-live",
    "live triad binary supports native session commands: " & paths.liveTriad,
  )

proc diagnoseConfigFailure(paths: LivePaths, output: string) =
  let needle = "janet layout \""
  let start = output.find(needle)
  if start < 0:
    return
  let idStart = start + needle.len
  let idEnd = output.find('"', idStart)
  if idEnd <= idStart:
    return
  let layoutId = output[idStart ..< idEnd]
  let example = paths.repoDir / "examples/janet/layouts" / (layoutId & ".janet")
  if not fileExists(example):
    return
  let layoutDir = getHomeDir() / ".config/triad/layouts"
  let target = layoutDir / (layoutId & ".janet")
  failMessage("doctor-live", "matching example layout exists: " & example)
  failMessage("doctor-live", "repair with:")
  failMessage("doctor-live", "  mkdir -p '" & layoutDir & "'")
  failMessage("doctor-live", "  install -m 0644 '" & example & "' '" & target & "'")

proc validateConfig(paths: LivePaths) =
  let result =
    paths.runTriad(["validate-config", "--config", paths.configPath], timeoutMs = 3000)
  if result.status == 0:
    for line in result.output.splitLines():
      if line.len > 0:
        info("doctor-live", "config validation " & line)
    return

  for line in result.output.splitLines():
    if line.len > 0:
      failMessage("doctor-live", "config validation " & line)
  paths.diagnoseConfigFailure(result.output)
  fail("doctor-live", "config validation failed; fix config/assets before live reload")

proc runningTriadPid*(paths: LivePaths): RunningDaemon =
  let resultProc = paths.runTriad(["msg", "perf-status"], timeoutMs = 1000)
  if resultProc.status != 0 or resultProc.output.strip().len == 0:
    return
  let payload = parseJsonObject(resultProc.output)
  if payload.kind != JObject:
    return
  result.perfStatusCompatible =
    payload.jsonString("type") == "perf-status" and payload.hasKey("ok") and
    payload["ok"].kind == JBool and payload["ok"].getBool()
  let pid = payload.jsonInt("pid")
  if pid > 0:
    result.pid = pid
    result.pidFromPerfStatus = true
  elif result.perfStatusCompatible:
    result.pid = paths.latestLiveTriadPid()

proc checkSupervisorMetadata(paths: LivePaths) =
  if not fileExists(paths.metadata):
    fail(
      "doctor-live",
      "missing supervisor metadata: " & paths.metadata &
        "; restart the River/Triad session before live reload",
    )

  let metadata = readJsonFile(paths.metadata)
  let protocol = metadata.jsonInt("supervisor_protocol", -1)
  let supervisorPid = metadata.jsonInt("supervisor_pid")
  let daemonPidRecord = metadata.jsonInt("daemon_pid")

  if protocol < 0:
    fail("doctor-live", "invalid supervisor protocol in " & paths.metadata)
  if protocol < SupervisorProtocolVersion:
    paths.restartRequired(
      "supervisor protocol " & $protocol & " is older than required " &
        $SupervisorProtocolVersion
    )

  if supervisorPid <= 0:
    fail("doctor-live", "invalid supervisor pid in " & paths.metadata)
  if not processExists(supervisorPid):
    fail(
      "doctor-live",
      "supervisor pid " & $supervisorPid & " from " & paths.metadata &
        " is not running; restart the River/Triad session",
    )

  let daemon = paths.runningTriadPid()
  if not daemon.perfStatusCompatible:
    fail(
      "doctor-live",
      "running Triad daemon does not answer perf-status; restart the River/Triad session",
    )

  let daemonPid = if daemon.pid > 0: daemon.pid else: daemonPidRecord
  if daemonPid <= 0:
    fail(
      "doctor-live",
      "running Triad daemon does not expose perf-status pid; restart the River/Triad session",
    )
  if daemon.pidFromPerfStatus and daemonPidRecord != daemonPid:
    fail(
      "doctor-live",
      "supervisor metadata daemon pid " & $daemonPidRecord &
        " does not match live daemon pid " & $daemonPid &
        "; restart the River/Triad session",
    )
  if not processExists(daemonPid):
    fail("doctor-live", "daemon pid " & $daemonPid & " is not running")
  let expectedDaemonExe = getEnv("TRIAD_DOCTOR_EXPECT_DAEMON_EXE", paths.liveTriad)
  if processExe(daemonPid) != expectedDaemonExe:
    fail(
      "doctor-live",
      "daemon pid " & $daemonPid & " is running " & processExe(daemonPid) & ", expected " &
        expectedDaemonExe & "; restart the River/Triad session",
    )

  info(
    "doctor-live",
    "supervisor metadata valid: supervisor=" & $supervisorPid & " daemon=" & $daemonPid &
      " protocol=" & $protocol,
  )

proc runDoctorLive*(paths = livePaths()): int =
  try:
    paths.syncPackagedScript(
      paths.repoDir / "tools/triad-manager-loop.sh",
      paths.liveManagerLoop,
      "manager loop",
    )
    paths.syncPackagedScript(
      paths.repoDir / "tools/river-triad-session.sh",
      paths.liveSessionRunner,
      "session runner",
    )
    paths.checkRestartMarker()
    paths.checkLiveTriadBinary()
    paths.validateConfig()
    paths.checkSupervisorMetadata()
    info("doctor-live", "live session doctor passed")
    0
  except LiveDoctorError:
    1
