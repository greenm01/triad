import std/[algorithm, json, os]
import doctor_live, live_paths

type LiveReloadError* = object of CatchableError

proc logInfo(paths: LivePaths, message: string) =
  paths.logLiveReload("INFO", message)

proc logError(paths: LivePaths, message: string) =
  paths.logLiveReload("ERROR", message)
  failMessage("live-reload", message)

proc fail(paths: LivePaths, message: string) {.noreturn.} =
  paths.logError(message)
  raise newException(LiveReloadError, message)

proc activeTag(state: JsonNode): int =
  state.jsonInt("active_tag")

proc windowIds(state: JsonNode): seq[int] =
  if state.kind != JObject or not state.hasKey("windows") or
      state["windows"].kind != JArray:
    return
  for item in state["windows"]:
    if item.kind == JObject:
      let id = item.jsonInt("id")
      if id > 0:
        result.add(id)
  result.sort()

proc occupiedTags(state: JsonNode): seq[int] =
  if state.kind != JObject or not state.hasKey("windows") or
      state["windows"].kind != JArray:
    return
  for item in state["windows"]:
    if item.kind == JObject:
      let tag = item.jsonInt("tag_id")
      if tag > 0 and tag notin result:
        result.add(tag)
  result.sort()

proc snapshotSuspiciousCollapse(previousPath, candidatePath: string): bool =
  if getEnv("TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE", "") == "1":
    return false
  if not fileExists(previousPath):
    return false
  let previous = readJsonFile(previousPath)
  let candidate = readJsonFile(candidatePath)
  if previous.jsonString("schema") != "triad-live-restore-v2" or
      candidate.jsonString("schema") != "triad-live-restore-v2":
    return false
  let previousWindows = previous.windowIds()
  previousWindows.len > 1 and previousWindows == candidate.windowIds() and
    previous.occupiedTags().len > 1 and candidate.occupiedTags().len == 1

proc snapshotSummary(state: JsonNode): string =
  "active_tag=" & $state.activeTag() & " focused_window=" &
    $state.jsonInt("focused_window") & " windows=" & $state.windowIds().len

proc writeJson(path: string, payload: JsonNode) =
  createDir(path.parentDir())
  writeFile(path, $payload & "\n")

proc snapshotRestoreState(paths: LivePaths): tuple[path: string, activeTag: int] =
  let response = paths.runTriad(["msg", "dump-live-restore-state"], timeoutMs = 3000)
  if response.status != 0:
    paths.fail(
      "native live restore snapshot timed out or failed; aborting reload to preserve state"
    )
  let snapshot = parseJsonObject(response.output)
  if snapshot.jsonString("schema") != "triad-live-restore-v2":
    paths.fail(
      "native live restore snapshot had an unsupported schema; aborting reload to preserve state"
    )
  let tag = snapshot.activeTag()
  if tag <= 0:
    paths.fail("native live restore snapshot did not include active_tag")

  let tmp = paths.restorePath & ".tmp." & $getCurrentProcessId()
  tmp.writeJson(snapshot)
  if snapshotSuspiciousCollapse(paths.restorePath, tmp):
    removeFile(tmp)
    paths.fail(
      "native live restore snapshot collapsed existing workspaces; set " &
        "TRIAD_LIVE_RELOAD_USE_RETAINED_RESTORE=1 to replay the retained snapshot " &
        "or TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE=1 to overwrite it"
    )
  moveFile(tmp, paths.restorePath)
  paths.logInfo("snapshotted native state to " & paths.restorePath)
  paths.logInfo("captured " & snapshot.snapshotSummary())
  (paths.restorePath, tag)

proc useRetainedRestoreState(paths: LivePaths): tuple[path: string, activeTag: int] =
  if not fileExists(paths.restorePath):
    paths.fail("retained live restore snapshot is missing: " & paths.restorePath)
  let snapshot = readJsonFile(paths.restorePath)
  if snapshot.jsonString("schema") != "triad-live-restore-v2":
    paths.fail("retained live restore snapshot could not be reactivated")
  let tag = snapshot.activeTag()
  if tag <= 0:
    paths.fail("retained live restore snapshot could not be reactivated")
  snapshot["restore_status"] = %"pending"
  if snapshot.hasKey("applied_at_unix_ms"):
    snapshot.delete("applied_at_unix_ms")
  if snapshot.hasKey("applied_by_pid"):
    snapshot.delete("applied_by_pid")
  paths.restorePath.writeJson(snapshot)
  paths.logInfo("reactivated retained live restore snapshot at " & paths.restorePath)
  paths.logInfo("retained " & snapshot.snapshotSummary())
  (paths.restorePath, tag)

proc enableLiveReloadDevMode(paths: LivePaths) =
  let marker = paths.runtimeDir / "triad-live-dev-mode"
  createDir(marker.parentDir())
  writeFile(marker, "1\n")
  paths.logInfo("enabled one-shot dev mode for replacement daemon via " & marker)

proc backupLiveBinaries(paths: LivePaths): string =
  if not fileExists(paths.liveTriad):
    paths.fail("missing installed live binary: " & paths.liveTriad)
  if not fileExists(paths.liveTriadNiri):
    paths.fail("missing installed live binary: " & paths.liveTriadNiri)
  result = paths.liveReloadLogDir() / ("rollback-" & $getCurrentProcessId())
  createDir(result)
  copyFile(paths.liveTriad, result / "triad")
  copyFile(paths.liveTriadNiri, result / "triad_niri")
  paths.logInfo("backed up live binaries to " & result)

proc restoreLiveBinaries(paths: LivePaths, backupDir: string): bool =
  if backupDir.len == 0:
    paths.logError("no live binary backup is available for rollback")
    return false
  if not fileExists(backupDir / "triad") or not fileExists(backupDir / "triad_niri"):
    paths.logError("live binary backup is incomplete: " & backupDir)
    return false
  atomicInstall(backupDir / "triad", paths.liveTriad)
  atomicInstall(backupDir / "triad_niri", paths.liveTriadNiri)
  paths.logInfo("restored live binaries from " & backupDir)
  true

proc restoreSnapshotApplied(paths: LivePaths): bool =
  let snapshot = readJsonFile(paths.restorePath)
  snapshot.jsonString("restore_status") == "applied"

proc compareRestoreSnapshots(expectedPath, actualText: string): bool =
  let expected = readJsonFile(expectedPath)
  let actual = parseJsonObject(actualText)
  expected.activeTag() == actual.activeTag() and
    expected.windowIds().len == actual.windowIds().len

proc waitRestoreReady(
    paths: LivePaths, snapshotPath: string, expectedActiveTag: int
): bool =
  let triadNiri =
    if fileExists(paths.repoDir / "triad_niri"):
      paths.repoDir / "triad_niri"
    else:
      paths.liveTriadNiri
  for _ in 0 ..< 100:
    if paths.restoreSnapshotApplied():
      let workspaces =
        runProcess(triadNiri, ["msg", "-j", "workspaces"], timeoutMs = 1000)
      if workspaces.status == 0:
        let current =
          paths.runTriad(["msg", "dump-live-restore-state"], timeoutMs = 1000)
        let currentPayload = parseJsonObject(current.output)
        if current.status == 0 and currentPayload.activeTag() == expectedActiveTag:
          if compareRestoreSnapshots(snapshotPath, current.output):
            return true
          paths.logError(
            "restored manager is running, but restored state differs from captured snapshot"
          )
          return false
    sleep(100)
  false

proc waitReloadReady(
    paths: LivePaths, oldPid: int, snapshotPath: string, expectedActiveTag: int
): bool =
  for _ in 0 ..< 50:
    let daemon = paths.runningTriadPid()
    if daemon.pid > 0 and daemon.pid != oldPid:
      if not paths.waitRestoreReady(snapshotPath, expectedActiveTag):
        return false
      let ready = paths.runningTriadPid()
      if ready.pid <= 0 or ready.pid == oldPid:
        paths.logError(
          "restored workspace state became ready, but no replacement triad manager remained"
        )
        return false
      paths.logInfo(
        "installed binaries and reloaded manager pid " & $oldPid & " -> " & $ready.pid &
          "; restored active tag " & $expectedActiveTag & " is ready"
      )
      return true
    sleep(100)
  false

proc rollbackAndFail(paths: LivePaths, backupDir, message: string) {.noreturn.} =
  paths.logError(message)
  if paths.restoreLiveBinaries(backupDir):
    let before = paths.runningTriadPid().pid
    let reload = runProcess(paths.liveTriad, ["msg", "triad-reload"], timeoutMs = 1000)
    if reload.status == 0:
      paths.logInfo("requested reload after restoring previous live binaries")
      discard paths.waitReloadReady(
        before, paths.restorePath, readJsonFile(paths.restorePath).activeTag()
      )
    else:
      paths.logError("restored previous live binaries, but rollback reload IPC failed")
      paths.logError(
        "manual recovery: restart the River/Triad session, or run: setsid " &
          paths.liveTriad &
          " supervise >/tmp/triad-supervise-recovery.log 2>&1 < /dev/null &"
      )
  raise newException(LiveReloadError, message)

proc runLiveReload*(paths = livePaths()): int =
  var backupDir = ""
  try:
    if not fileExists(paths.repoDir / "triad"):
      paths.fail("missing built binary: " & (paths.repoDir / "triad"))
    if not fileExists(paths.repoDir / "triad_niri"):
      paths.fail("missing built binary: " & (paths.repoDir / "triad_niri"))

    if runDoctorLive(paths) != 0:
      paths.fail(
        "live session doctor failed; refusing live reload before installing binaries"
      )

    let oldDaemon = paths.runningTriadPid()
    if oldDaemon.pid <= 0:
      paths.logError("running Triad daemon does not expose perf-status pid")
      paths.logError("restart the River/Triad session, then retry liveReload")
      paths.fail("refusing live reload without a supervisor-backed daemon")
    paths.logInfo(
      "supervisor-backed live runtime confirmed with daemon pid " & $oldDaemon.pid
    )

    let snapshot =
      if getEnv("TRIAD_LIVE_RELOAD_USE_RETAINED_RESTORE", "") == "1":
        paths.useRetainedRestoreState()
      else:
        paths.snapshotRestoreState()
    paths.enableLiveReloadDevMode()

    createDir(paths.binDir)
    backupDir = paths.backupLiveBinaries()
    atomicInstall(paths.repoDir / "triad", paths.liveTriad)
    atomicInstall(paths.repoDir / "triad_niri", paths.liveTriadNiri)

    let reloadCommand =
      if getEnv("TRIAD_LIVE_RELOAD_USE_RETAINED_RESTORE", "") == "1":
        "stop-manager"
      else:
        "triad-reload"
    let reload = paths.runTriad(["msg", reloadCommand], timeoutMs = 1000)
    if reload.status != 0:
      paths.rollbackAndFail(
        backupDir, "installed binaries, but " & reloadCommand & " IPC failed"
      )
    if not paths.waitReloadReady(oldDaemon.pid, snapshot.path, snapshot.activeTag):
      paths.rollbackAndFail(
        backupDir,
        "installed binaries and requested reload, but triad did not become ready",
      )
    0
  except LiveReloadError:
    1
