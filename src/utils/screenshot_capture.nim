import std/[asyncdispatch, os, osproc, strtabs, strutils, times]
import ../core/[defaults, msg]
from ../types/core import Rect
import ../types/runtime_values
import process_options

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

proc screenshotCaptureCommand*(
    kind: ScreenshotKind,
    path: string,
    config: ScreenshotConfig,
    screenRect, windowRect: Rect,
    pointerMode: ScreenshotPointerMode,
): string =
  let captureCommand =
    if config.captureCommand.strip().len > 0:
      config.captureCommand.strip()
    else:
      DefaultScreenshotCaptureCommand
  let regionSelectorCommand =
    if config.regionSelectorCommand.strip().len > 0:
      config.regionSelectorCommand.strip()
    else:
      DefaultScreenshotRegionSelectorCommand
  let pointerFlag = if screenshotPointerEnabled(pointerMode, config): " -c" else: ""

  case kind
  of ScreenshotKind.ShotRegion:
    captureCommand & pointerFlag & " -g \"$(" & regionSelectorCommand & ")\" " &
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

proc runShellCommandAsync*(
    command: string, env: StringTableRef = nil, pollMs = 50
): Future[int] {.async.} =
  var process: Process
  var finished = false
  try:
    process = startProcess(
      "sh", args = @["-c", command], env = env, options = InheritedProcessOptions
    )
    while true:
      let code = process.peekExitCode()
      if code != -1:
        finished = true
        return code
      await sleepAsync(pollMs)
  finally:
    if process != nil:
      if not finished:
        try:
          if process.running():
            process.terminate()
            discard process.waitForExit(1000)
        except CatchableError:
          discard
      try:
        process.close()
      except CatchableError:
        discard
