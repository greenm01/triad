import std/[os, osproc, posix, strutils, times]
import logs, process_io

var shutdownSignal {.volatile.}: cint

proc devModeEnabled(value: string): bool =
  value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]

proc installSignalHandlers() =
  onSignal(SIGTERM, SIGINT, SIGHUP):
    shutdownSignal = sig

proc daemonArgs(): seq[string] =
  if devModeEnabled(getEnv("TRIAD_DEV_MODE", "")):
    putEnv("TRIAD_DEV_MODE", "1")
    if getEnv("TRIAD_BEHAVIOR_LOG", "").len == 0:
      putEnv("TRIAD_BEHAVIOR_LOG", "1")
    result.add("--dev-mode")

proc waitForChild(process: Process): int =
  while true:
    let code = process.peekExitCode()
    if code != -1:
      return code
    if shutdownSignal != 0:
      process.terminate()
      discard process.waitForExit(3000)
      return 128 + int(shutdownSignal)
    sleep(100)

proc terminateChild(process: Process) =
  try:
    process.terminate()
    discard process.waitForExit(3000)
    process.close()
  except CatchableError:
    discard

const SupervisorRestartDelaysMs* = [200'i64, 1000, 2000, 5000, 15000, 30000]

proc restartDelayMs*(status: int, runtimeSec: int64, rapidRestarts: int): int64 =
  if runtimeSec >= 30:
    return if status == 0: SupervisorRestartDelaysMs[0] else: SupervisorRestartDelaysMs[1]
  let index = min(max(rapidRestarts + 1, 1), SupervisorRestartDelaysMs.high)
  SupervisorRestartDelaysMs[index]

proc runSupervisor*(): int =
  let dir = stateDir()
  createDir(dir)
  installSignalHandlers()

  let sessionId =
    if getEnv("TRIAD_SESSION_ID", "").strip().len > 0:
      getEnv("TRIAD_SESSION_ID")
    else:
      newSessionId()
  let sessionLog = getEnv("TRIAD_SESSION_LOG", "")
  let daemonLog = daemonLogPath(dir, sessionId)
  let shellManagerLog = shellManagerLogPath(dir, sessionId)
  let triadBin = getEnv("TRIAD_BIN", getAppFilename())
  let claimId = sessionId & "-supervisor-" & $getCurrentProcessId()
  let startedAt = isoNow()

  var daemonLink = claimSymlink(daemonLog, dir / DaemonLatestName)
  var shellManagerLink = claimSymlink(shellManagerLog, dir / ShellManagerLatestName)
  var recordClaim: SessionClaim
  var rapidRestarts = 0
  var shellManager: Process

  try:
    echo "triad-supervise: starting shell manager, log=", shellManagerLog
    shellManager = startWithLog(triadBin, @["shell-manager"], shellManagerLog)

    while shutdownSignal == 0:
      if shellManager.peekExitCode() != -1:
        echo "triad-supervise: restarting shell manager, log=", shellManagerLog
        shellManager.close()
        shellManager = startWithLog(triadBin, @["shell-manager"], shellManagerLog)

      let startSec = epochTime().int64
      echo "triad-supervise: starting triad, log=", daemonLog

      var process: Process
      try:
        process = startWithLog(triadBin, daemonArgs(), daemonLog)
      except CatchableError as e:
        echo "triad-supervise: failed to start triad: ", e.msg
        return 1

      let record = SessionLogRecord(
        claimId: claimId,
        sessionId: sessionId,
        sessionPid: parseInt(getEnv("TRIAD_SESSION_PID", $getCurrentProcessId())),
        supervisorPid: getCurrentProcessId(),
        shellManagerPid: shellManager.processID,
        daemonPid: process.processID,
        stateDir: dir,
        sessionLog: sessionLog,
        daemonLog: daemonLog,
        startedAt: startedAt,
        supervisorProtocol: SupervisorProtocolVersion,
      )
      if recordClaim.path.len == 0:
        recordClaim = claimSessionRecord(currentSessionPath(dir), record)
      elif not writeClaimedSessionRecord(recordClaim, record):
        echo "triad-supervise: current session metadata claimed by another supervisor; stopping"
        terminateChild(process)
        return 0

      let status = waitForChild(process)
      try:
        process.close()
      except CatchableError:
        discard

      if shutdownSignal != 0:
        return status

      let runtimeSec = epochTime().int64 - startSec
      let restartDelay = restartDelayMs(status, runtimeSec, rapidRestarts)
      if runtimeSec < 30:
        inc rapidRestarts
      else:
        rapidRestarts = 0

      if status == 0:
        echo "triad-supervise: triad exited cleanly after ", runtimeSec, "s; restarting"
      else:
        echo "triad-supervise: triad exited with status ",
          status, " after ", runtimeSec, "s; restarting"
      sleep(restartDelay)
  finally:
    if not shellManager.isNil:
      terminateChild(shellManager)
    restoreSessionRecord(recordClaim)
    restoreSymlink(shellManagerLink)
    restoreSymlink(daemonLink)

  0
