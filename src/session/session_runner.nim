import std/[os, osproc, strutils]
import logs, process_io

proc truthy(value: string): bool =
  value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]

proc findExecutable(candidates: openArray[string]): string =
  for candidate in candidates:
    if candidate.len > 0 and fileExists(candidate):
      return candidate
  ""

proc findDbusRunSession(): string =
  result = findExecutable(
    [
      "/usr/bin/dbus-run-session", "/bin/dbus-run-session",
      "/usr/sbin/dbus-run-session", "/sbin/dbus-run-session",
    ]
  )
  if result.len == 0:
    result = findExe("dbus-run-session")

proc findDbusSessionConfig(): string =
  for candidate in ["/usr/share/dbus-1/session.conf", "/etc/dbus-1/session.conf"]:
    if fileExists(candidate) and readFile(candidate).contains("<listen>"):
      return candidate

proc riverBin(): string =
  result = getEnv("TRIAD_RIVER_BIN", "")
  if result.len == 0:
    result = findExe("river")

proc runAndWait(command: string, args: openArray[string]): int =
  let process =
    startProcess(command, args = args, options = {poUsePath, poParentStreams})
  result = process.waitForExit()
  process.close()

proc riverArgs(triadBin: string): seq[string] =
  @["-c", "exec " & quoteShell(triadBin) & " supervise"]

proc startRiver(river, triadBin, dbusRunner, dbusConfig: string): int =
  let riverArgs = riverArgs(triadBin)
  if getEnv("DBUS_SESSION_BUS_ADDRESS", "").len == 0 and dbusRunner.len > 0:
    var args: seq[string]
    if dbusConfig.len > 0:
      echo "triad-session: starting River through ",
        dbusRunner, " --config-file=", dbusConfig
      args = @["--config-file=" & dbusConfig, "--", river] & riverArgs
    else:
      echo "triad-session: starting River through ", dbusRunner
      args = @["--", river] & riverArgs
    return runAndWait(dbusRunner, args)

  echo "triad-session: starting River directly"
  runAndWait(river, riverArgs)

proc runSession*(): int =
  let dir = stateDir()
  createDir(dir)
  let sessionId = newSessionId()
  let sessionLog = sessionLogPath(dir, sessionId)
  redirectProcessStreams(sessionLog)

  putEnv("XDG_CURRENT_DESKTOP", "river")
  putEnv("XDG_SESSION_DESKTOP", "river-triad")
  putEnv("XDG_SESSION_TYPE", "wayland")
  putEnv(
    "PATH",
    getHomeDir() / ".local/bin:/usr/local/bin:/usr/bin:/bin:" & getEnv("PATH", ""),
  )
  putEnv("TRIAD_SESSION_ID", sessionId)
  putEnv("TRIAD_SESSION_LOG", sessionLog)
  putEnv("TRIAD_SESSION_PID", $getCurrentProcessId())

  if truthy(getEnv("TRIAD_SESSION_DEV_MODE", "")):
    putEnv("TRIAD_DEV_MODE", "1")
  else:
    delEnv("TRIAD_DEV_MODE")
    delEnv("TRIAD_BEHAVIOR_LOG")

  discard claimSymlink(sessionLog, dir / SessionLatestName)
  discard claimSymlink(sessionLog, dir / LegacySessionLatestName)

  let river = riverBin()
  if river.len == 0:
    echo "triad-session: river not found; install upstream River or set TRIAD_RIVER_BIN"
    return 1

  let triadBin = getAppFilename()
  let dbusRunner = findDbusRunSession()
  let dbusConfig = findDbusSessionConfig()

  echo "triad-session: starting at ", isoNow()
  echo "triad-session: HOME=", getHomeDir()
  echo "triad-session: XDG_RUNTIME_DIR=", getEnv("XDG_RUNTIME_DIR", "")
  echo "triad-session: WAYLAND_DISPLAY=", getEnv("WAYLAND_DISPLAY", "")
  echo "triad-session: river=", river
  echo "triad-session: triad=", triadBin

  result = startRiver(river, triadBin, dbusRunner, dbusConfig)
  if result != 0 and getEnv("WLR_RENDERER", "").len == 0:
    try:
      if readFile(sessionLog).contains("RendererCreateFailed"):
        echo "triad-session: hardware renderer failed; retrying with WLR_RENDERER=pixman"
        putEnv("WLR_RENDERER", "pixman")
        result = startRiver(river, triadBin, dbusRunner, dbusConfig)
    except CatchableError:
      discard
