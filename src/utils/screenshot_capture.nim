import std/[asyncdispatch, os, osproc, posix, streams, strtabs, strutils, times]
import ../core/[defaults, msg]
from ../types/core import Rect
import ../types/runtime_values
import process_options
import process_tree

const
  ShellTimeoutExitCode* = 124
  DefaultShellCommandTimeoutMs* = 30000

type ShellCommandResult* = object
  exitCode*: int
  output*: string
  timedOut*: bool

proc shellQuote*(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc homeDirPath(): string =
  result = getHomeDir()
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc expandUserPath*(path: string): string =
  if path == "~" or path == "~/":
    return homeDirPath()
  if path.startsWith("~/"):
    return homeDirPath() / path[2 .. ^1]
  path

proc screenshotPathOrDefault*(path: string, config: ScreenshotConfig): string =
  if path.len > 0:
    return expandUserPath(path)
  let dir =
    if config.directory.strip().len > 0:
      expandUserPath(config.directory.strip())
    else:
      getHomeDir() / "Pictures" / "Screenshots"
  let prefix =
    if config.filenamePrefix.strip().len > 0:
      config.filenamePrefix.strip()
    else:
      DefaultScreenshotFilenamePrefix
  dir / (prefix & "-" & $getTime().toUnix() & ".png")

proc screenshotTempPath*(config: ScreenshotConfig): string =
  let prefix =
    if config.filenamePrefix.strip().len > 0:
      config.filenamePrefix.strip()
    else:
      DefaultScreenshotFilenamePrefix
  getTempDir() / (prefix & "-clipboard-" & $getTime().toUnix() & ".png")

proc geometryArg*(rect: Rect): string =
  $rect.x & "," & $rect.y & " " & $max(1'i32, rect.w) & "x" & $max(1'i32, rect.h)

proc screenshotPointerEnabled*(
    mode: ScreenshotPointerMode, config: ScreenshotConfig
): bool =
  case mode
  of ScreenshotPointerMode.PointerShow: true
  of ScreenshotPointerMode.PointerHide: false
  of ScreenshotPointerMode.PointerDefault: config.showPointer

proc screenshotRegionSelectorCommand*(config: ScreenshotConfig): string =
  if config.regionSelectorCommand.strip().len > 0:
    config.regionSelectorCommand.strip()
  else:
    DefaultScreenshotRegionSelectorCommand

proc screenshotCaptureCommand*(
    kind: ScreenshotKind,
    path: string,
    config: ScreenshotConfig,
    screenRect, windowRect: Rect,
    pointerMode: ScreenshotPointerMode,
    regionGeometry = "",
): string =
  let captureCommand =
    if config.captureCommand.strip().len > 0:
      config.captureCommand.strip()
    else:
      DefaultScreenshotCaptureCommand
  let pointerFlag = if screenshotPointerEnabled(pointerMode, config): " -c" else: ""

  case kind
  of ScreenshotKind.ShotRegion:
    captureCommand & pointerFlag & " -g " & shellQuote(regionGeometry.strip()) & " " &
      shellQuote(path)
  of ScreenshotKind.ShotScreen:
    captureCommand & pointerFlag & " -g " & shellQuote(geometryArg(screenRect)) & " " &
      shellQuote(path)
  of ScreenshotKind.ShotWindow:
    captureCommand & pointerFlag & " -g " & shellQuote(geometryArg(windowRect)) & " " &
      shellQuote(path)

proc screenshotClipboardCommand*(path: string, config: ScreenshotConfig): string =
  let clipboardCommand =
    if config.clipboardCommand.strip().len > 0:
      config.clipboardCommand.strip()
    else:
      DefaultScreenshotClipboardCommand
  clipboardCommand & " < " & shellQuote(path)

proc descendantPids(rootPid: int32): seq[int32] =
  for kind, path in walkDir("/proc"):
    if kind != pcDir:
      continue
    let pidText = path.extractFilename()
    var numeric = pidText.len > 0
    for ch in pidText:
      if ch notin {'0' .. '9'}:
        numeric = false
        break
    if not numeric:
      continue
    try:
      let pid = int32(parseInt(pidText))
      if isDescendantProcess(rootPid, pid):
        result.add(pid)
    except CatchableError:
      discard

proc signalPid(pid: int32, signal: cint) =
  if pid <= 0:
    return
  try:
    discard posix.kill(Pid(pid), signal)
  except CatchableError:
    discard

proc terminateProcessTree(process: Process) =
  if process == nil:
    return
  let rootPid = int32(process.processID)
  let children = descendantPids(rootPid)
  for pid in children:
    signalPid(pid, SIGTERM)
  try:
    if process.running():
      process.terminate()
      discard process.waitForExit(1000)
  except CatchableError:
    discard
  if process.running():
    for pid in children:
      signalPid(pid, SIGKILL)
    try:
      process.kill()
      discard process.waitForExit()
    except CatchableError:
      discard

proc waitShellCommand(
    process: Process, timeoutMs, pollMs: int
): Future[tuple[exitCode: int, timedOut: bool]] {.async.} =
  let deadline =
    if timeoutMs > 0:
      epochTime() + float(timeoutMs) / 1000.0
    else:
      0.0
  while true:
    let code = process.peekExitCode()
    if code != -1:
      return (code, false)
    if timeoutMs > 0 and epochTime() >= deadline:
      terminateProcessTree(process)
      return (ShellTimeoutExitCode, true)
    await sleepAsync(pollMs)

proc runShellCommandAsync*(
    command: string, env: StringTableRef = nil, pollMs = 50, timeoutMs = 0
): Future[int] {.async.} =
  var process: Process
  var finished = false
  try:
    process = startProcess(
      "sh", args = @["-c", command], env = env, options = InheritedProcessOptions
    )
    let commandResult = await waitShellCommand(process, timeoutMs, pollMs)
    finished = true
    return commandResult.exitCode
  finally:
    if process != nil:
      if not finished:
        try:
          terminateProcessTree(process)
        except CatchableError:
          discard
      try:
        process.close()
      except CatchableError:
        discard

proc runShellCommandCaptureAsync*(
    command: string, env: StringTableRef = nil, pollMs = 50, timeoutMs = 0
): Future[ShellCommandResult] {.async.} =
  var process: Process
  var finished = false
  try:
    process = startProcess(
      "sh", args = @["-c", command], env = env, options = {poUsePath, poStdErrToStdOut}
    )
    let commandResult = await waitShellCommand(process, timeoutMs, pollMs)
    result.exitCode = commandResult.exitCode
    result.timedOut = commandResult.timedOut
    finished = true
    try:
      result.output = process.outputStream().readAll()
    except CatchableError:
      result.output = ""
  finally:
    if process != nil:
      if not finished:
        try:
          terminateProcessTree(process)
        except CatchableError:
          discard
      try:
        process.close()
      except CatchableError:
        discard

proc parseExitCodeFile(path: string): int =
  try:
    parseInt(readFile(path).strip())
  except CatchableError:
    ShellTimeoutExitCode

proc runDetachedShellCommandCaptureAsync*(
    command: string, env: StringTableRef = nil, pollMs = 50, timeoutMs = 0
): Future[ShellCommandResult] {.async.} =
  let timeoutSeconds = max(1, (max(timeoutMs, 1000) + 999) div 1000)
  let stamp = $(int(epochTime() * 1000))
  let base =
    getTempDir() / ("triad-shell-capture-" & $getCurrentProcessId() & "-" & stamp)
  let outPath = base & ".out"
  let errPath = base & ".err"
  let codePath = base & ".code"
  try:
    let inner =
      "timeout " & $timeoutSeconds & " env LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=dumb sh -lc " &
      shellQuote(command) & " > " & shellQuote(outPath) & " 2> " & shellQuote(errPath) &
      "; code=$?; printf '%s\\n' \"$code\" > " & shellQuote(codePath)
    let launch = "setsid -f sh -lc " & shellQuote(inner)
    let launchCode = await runShellCommandAsync(launch, env, pollMs, timeoutMs = 5000)
    if launchCode != 0:
      result.exitCode = launchCode
      result.timedOut = launchCode == ShellTimeoutExitCode
      return

    let deadline =
      if timeoutMs > 0:
        epochTime() + float(timeoutMs + 2000) / 1000.0
      else:
        epochTime() + float(DefaultShellCommandTimeoutMs + 2000) / 1000.0
    while not fileExists(codePath) and epochTime() < deadline:
      await sleepAsync(pollMs)

    if not fileExists(codePath):
      result.exitCode = ShellTimeoutExitCode
      result.timedOut = true
      return

    result.exitCode = parseExitCodeFile(codePath)
    result.timedOut = result.exitCode == ShellTimeoutExitCode
    try:
      result.output = readFile(outPath)
    except CatchableError:
      result.output = ""
    if result.output.len == 0 and result.exitCode != 0:
      try:
        result.output = readFile(errPath)
      except CatchableError:
        result.output = ""
  finally:
    for path in [outPath, errPath, codePath]:
      if fileExists(path):
        try:
          removeFile(path)
        except CatchableError:
          discard
