import std/[json, os, posix, times]

const
  SupervisorProtocolVersion* = 1
  SessionLatestName* = "triad-session-latest.log"
  LegacySessionLatestName* = "river-triad-session-latest.log"
  DaemonLatestName* = "triad-latest.log"
  CurrentSessionName* = "current-session.json"

type
  LinkClaim* = object
    path*: string
    target*: string
    previous*: string

  SessionClaim* = object
    path*: string
    claimId*: string
    previous*: string
    hadPrevious*: bool

  SessionLogRecord* = object
    claimId*: string
    sessionId*: string
    sessionPid*: int
    supervisorPid*: int
    daemonPid*: int
    stateDir*: string
    sessionLog*: string
    daemonLog*: string
    startedAt*: string
    supervisorProtocol*: int

proc renamePath(
  oldPath, newPath: cstring
): cint {.importc: "rename", header: "<stdio.h>".}

proc stateDir*(): string =
  getEnv("XDG_STATE_HOME", getHomeDir() / ".local/state") / "triad"

proc isoNow*(): string =
  now().format("yyyy-MM-dd'T'HH:mm:sszzz")

proc timestamp*(): string =
  now().format("yyyyMMdd-HHmmss")

proc newSessionId*(): string =
  timestamp() & "-" & $getCurrentProcessId()

proc sessionLogPath*(stateDir, sessionId: string): string =
  stateDir / ("triad-session-" & sessionId & ".log")

proc daemonLogPath*(stateDir, sessionId: string): string =
  stateDir / ("triad-" & sessionId & ".log")

proc currentSessionPath*(stateDir: string): string =
  stateDir / CurrentSessionName

proc symlinkTarget*(path: string): string =
  var buffer = newString(4096)
  let size = readlink(path.cstring, buffer.cstring, buffer.len)
  if size < 0:
    return ""
  buffer.setLen(size)
  buffer

proc replaceSymlink*(target, linkPath: string): bool =
  let tmp = linkPath & ".tmp." & $getCurrentProcessId()
  discard unlink(tmp.cstring)
  if symlink(target.cstring, tmp.cstring) != 0:
    return false
  if renamePath(tmp.cstring, linkPath.cstring) != 0:
    discard unlink(tmp.cstring)
    return false
  true

proc claimSymlink*(target, linkPath: string): LinkClaim =
  result = LinkClaim(path: linkPath, target: target, previous: symlinkTarget(linkPath))
  discard replaceSymlink(target, linkPath)

proc restoreSymlink*(claim: LinkClaim) =
  if claim.path.len == 0 or symlinkTarget(claim.path) != claim.target:
    return
  if claim.previous.len > 0:
    discard replaceSymlink(claim.previous, claim.path)

proc recordJson*(record: SessionLogRecord): JsonNode =
  %*{
    "version": 1,
    "claim_id": record.claimId,
    "session_id": record.sessionId,
    "session_pid": record.sessionPid,
    "supervisor_pid": record.supervisorPid,
    "daemon_pid": record.daemonPid,
    "state_dir": record.stateDir,
    "session_log": record.sessionLog,
    "daemon_log": record.daemonLog,
    "started_at": record.startedAt,
    "supervisor_protocol": record.supervisorProtocol,
  }

proc writeAtomic*(path, content: string) =
  let tmp = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmp, content)
  moveFile(tmp, path)

proc claimSessionRecord*(path: string, record: SessionLogRecord): SessionClaim =
  result = SessionClaim(path: path, claimId: record.claimId)
  if fileExists(path):
    result.previous = readFile(path)
    result.hadPrevious = true
  writeAtomic(path, $record.recordJson())

proc restoreSessionRecord*(claim: SessionClaim) =
  if claim.path.len == 0 or not fileExists(claim.path):
    return
  let current =
    try:
      parseFile(claim.path)
    except CatchableError:
      return
  if current{"claim_id"}.getStr() != claim.claimId:
    return
  if claim.hadPrevious:
    writeAtomic(claim.path, claim.previous)
  else:
    removeFile(claim.path)

proc readCurrentSession*(stateDir = stateDir()): JsonNode =
  let path = currentSessionPath(stateDir)
  if not fileExists(path):
    return newJNull()
  try:
    parseFile(path)
  except CatchableError:
    newJNull()

proc logsJson*(stateDir = stateDir()): JsonNode =
  let record = readCurrentSession(stateDir)
  if record.kind == JNull:
    return %*{
      "ok": false,
      "error": "no current Triad session metadata",
      "path": currentSessionPath(stateDir),
    }
  %*{"ok": true, "session": record}

proc renderLogs*(stateDir = stateDir()): string =
  let payload = logsJson(stateDir)
  if not payload["ok"].getBool():
    return "triad: " & payload["error"].getStr() & ": " & payload["path"].getStr()

  let session = payload["session"]
  result.add("session: " & session{"session_id"}.getStr() & "\n")
  result.add("session log: " & session{"session_log"}.getStr() & "\n")
  result.add("daemon log: " & session{"daemon_log"}.getStr() & "\n")
  result.add("session pid: " & $session{"session_pid"}.getInt() & "\n")
  result.add("supervisor pid: " & $session{"supervisor_pid"}.getInt() & "\n")
  result.add("daemon pid: " & $session{"daemon_pid"}.getInt())
