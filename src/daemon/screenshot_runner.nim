import std/[asyncdispatch, json, options, os, tables]
import chronicles
import ../core/msg
import ../ipc/socket
import ../systems/[daemon_view, layout_projection]
import ../types/runtime_values
import ../utils/screenshot_capture
import process_runner
import state

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

proc focusedWindowGeometry*(daemon: TriadDaemon): Rect =
  let focused = daemon.currentModel.activeFocusRiverId()
  if focused != 0 and daemon.desiredPlacements.hasKey(focused):
    return daemon.desiredPlacements[focused]
  let winOpt = daemon.currentModel.windowDataForRiverId(focused)
  if focused != 0 and winOpt.isSome:
    let win = winOpt.get()
    if win.isFloating and win.floatingGeom.w > 0 and win.floatingGeom.h > 0:
      return win.floatingGeom
  daemon.currentModel.primaryScreen()

proc runScreenshotCapture*(
    daemon: ptr TriadDaemon,
    kind: ScreenshotKind,
    requestedPath: string,
    pointerMode: ScreenshotPointerMode,
    writeToDisk, copyToClipboard: bool,
) {.async.} =
  if daemon == nil:
    return
  if daemon.screenshotCaptureActive:
    warn "Screenshot capture skipped; capture already running"
    return

  daemon.screenshotCaptureActive = true
  var path = ""
  try:
    let screenshotConfig = daemon[].currentModel.screenshot
    path =
      if writeToDisk:
        screenshotPathOrDefault(requestedPath, screenshotConfig)
      else:
        screenshotTempPath(screenshotConfig)
    let dir = path.splitFile().dir
    if dir.len > 0:
      try:
        createDir(dir)
      except CatchableError as e:
        warn "Failed to create screenshot directory", path = dir, error = e.msg
        return

    let command = screenshotCaptureCommand(
      kind,
      path,
      screenshotConfig,
      daemon[].currentModel.primaryScreen(),
      daemon[].focusedWindowGeometry(),
      pointerMode,
    )
    info "Screenshot capture started", path = path, screenshotKind = $kind

    let env = daemon[].currentModel.configuredProcessEnv()
    let code = await runShellCommandAsync(command, env)
    if code != 0:
      warn "Screenshot capture failed", path = path, exitCode = code
      return

    var clipboardOk = true
    if copyToClipboard:
      let copyCode = await runShellCommandAsync(
        screenshotClipboardCommand(path, screenshotConfig), env
      )
      if copyCode != 0:
        warn "Screenshot clipboard copy failed", path = path, exitCode = copyCode
        clipboardOk = false
    if not writeToDisk and not clipboardOk:
      return

    info "Screenshot captured", path = path
    let event =
      if writeToDisk:
        %*{"ScreenshotCaptured": {"path": path}}
      else:
        %*{"ScreenshotCaptured": {}}
    asyncCheck broadcastJson($event)
  except CatchableError as e:
    warn "Screenshot capture failed", path = path, error = e.msg
  finally:
    daemon.screenshotCaptureActive = false
    if path.len > 0 and not writeToDisk and fileExists(path):
      try:
        removeFile(path)
      except CatchableError:
        discard
