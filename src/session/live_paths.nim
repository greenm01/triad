import std/[json, os, osproc, posix, streams, times]

type
  LivePaths* = object
    repoDir*: string
    binDir*: string
    runtimeDir*: string
    stateHome*: string
    stateDir*: string
    metadata*: string
    liveTriad*: string
    liveTriadNiri*: string
    liveManagerLoop*: string
    liveSessionRunner*: string
    configPath*: string
    restorePath*: string
    triadCli*: string

  ProcessResult* = object
    status*: int
    output*: string

proc renamePath(
  oldPath, newPath: cstring
): cint {.importc: "rename", header: "<stdio.h>".}

proc envOrDefault(name, fallback: string): string =
  result = getEnv(name, "")
  if result.len == 0:
    result = fallback

proc repoDir*(): string =
  result = getEnv("TRIAD_REPO_DIR", "")
  if result.len > 0:
    return result.expandTilde().absolutePath()

  let cwd = getCurrentDir()
  if fileExists(cwd / "triad.nimble") and dirExists(cwd / "tools"):
    return cwd

  let appDir = getAppFilename().parentDir()
  if fileExists(appDir / "triad.nimble") and dirExists(appDir / "tools"):
    return appDir

  result = cwd

proc livePaths*(): LivePaths =
  result.repoDir = repoDir()
  result.binDir =
    envOrDefault("TRIAD_LIVE_BIN_DIR", getHomeDir() / ".local/bin").expandTilde()
  result.runtimeDir = envOrDefault("XDG_RUNTIME_DIR", "/tmp").expandTilde()
  result.stateHome =
    envOrDefault("XDG_STATE_HOME", getHomeDir() / ".local/state").expandTilde()
  result.stateDir = result.stateHome / "triad"
  result.metadata = result.stateDir / "current-session.json"
  result.liveTriad =
    envOrDefault("TRIAD_LIVE_TRIAD_BIN", result.binDir / "triad").expandTilde()
  result.liveTriadNiri = result.binDir / "triad_niri"
  result.liveManagerLoop = envOrDefault(
      "TRIAD_MANAGER_LOOP", result.binDir / "triad-manager-loop"
    )
    .expandTilde()
  result.liveSessionRunner = envOrDefault(
      "TRIAD_SESSION_RUNNER", result.binDir / "river-triad-session"
    )
    .expandTilde()
  result.configPath = envOrDefault(
      "TRIAD_CONFIG", getHomeDir() / ".config/triad/config.kdl"
    )
    .expandTilde()
  result.restorePath = envOrDefault(
      "TRIAD_LIVE_RESTORE_PATH", result.runtimeDir / "triad-live-restore.json"
    )
    .expandTilde()
  result.triadCli = getEnv("TRIAD_DOCTOR_TRIAD_BIN", "")
  if result.triadCli.len == 0:
    result.triadCli = getAppFilename()

proc managerLoopRestartMarker*(paths: LivePaths): string =
  paths.runtimeDir / "triad-manager-loop-restart-required"

proc liveReloadLogDir*(paths: LivePaths): string =
  paths.stateHome / "triad/live-reload"

proc liveReloadLogFile*(paths: LivePaths): string =
  paths.liveReloadLogDir() / ("live-reload-" & now().format("yyyy-MM-dd") & ".log")

proc logLiveReload*(paths: LivePaths, level, message: string) =
  createDir(paths.liveReloadLogDir())
  let line = now().format("yyyy-MM-dd'T'HH:mm:sszzz") & " [" & level & "] " & message
  let path = paths.liveReloadLogFile()
  var file = open(path, fmAppend)
  defer:
    file.close()
  file.writeLine(line)

proc info*(prefix, message: string) =
  stdout.writeLine(prefix & ": " & message)

proc failMessage*(prefix, message: string) =
  stderr.writeLine(prefix & ": " & message)

proc runProcess*(
    command: string, args: openArray[string] = [], timeoutMs = 0, workingDir = ""
): ProcessResult =
  var process = startProcess(
    command,
    workingDir = workingDir,
    args = args,
    options = {poUsePath, poStdErrToStdOut},
  )
  let status =
    if timeoutMs > 0:
      process.waitForExit(timeoutMs)
    else:
      process.waitForExit()
  if status == -1:
    process.terminate()
    discard process.waitForExit(1000)
  let output = process.outputStream().readAll()
  process.close()
  ProcessResult(status: status, output: output)

proc runTriad*(
    paths: LivePaths, args: openArray[string], timeoutMs = 0
): ProcessResult =
  runProcess(paths.triadCli, args, timeoutMs = timeoutMs, workingDir = paths.repoDir)

proc atomicInstall*(src, dst: string, mode = 0o755) =
  createDir(dst.parentDir())
  let tmp = dst & ".tmp." & $getCurrentProcessId()
  copyFile(src, tmp)
  setFilePermissions(
    tmp,
    {
      fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec,
      fpOthersRead,
    },
  )
  if mode == 0o644:
    setFilePermissions(tmp, {fpUserWrite, fpUserRead, fpGroupRead, fpOthersRead})
  if renamePath(tmp.cstring, dst.cstring) != 0:
    try:
      removeFile(tmp)
    except OSError:
      discard
    raise newException(OSError, "failed to install " & dst)

proc processExists*(pid: int): bool =
  pid > 0 and dirExists("/proc" / $pid)

proc processExe*(pid: int): string =
  if pid <= 0:
    return ""
  try:
    expandSymlink("/proc" / $pid / "exe")
  except OSError:
    ""

proc sameExecutable*(pid: int, expected: string): bool =
  let exe = processExe(pid)
  exe.len > 0 and exe == expected

proc parseJsonObject*(text: string): JsonNode =
  try:
    result = parseJson(text)
  except JsonParsingError:
    result = newJNull()

proc jsonInt*(node: JsonNode, key: string, fallback = 0): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    node[key].getInt()
  else:
    fallback

proc jsonString*(node: JsonNode, key: string, fallback = ""): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    fallback

proc readJsonFile*(path: string): JsonNode =
  if not fileExists(path):
    return newJNull()
  try:
    parseFile(path)
  except CatchableError:
    newJNull()
