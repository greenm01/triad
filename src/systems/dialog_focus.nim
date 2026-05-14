import std/options
import ../state/engine
import focus, window_policy

proc flushPendingDialogFocus*(model: var Model): bool =
  if model.overviewActive or model.sessionLocked or
      model.pendingDialogFocusWindows.len == 0:
    return false

  let pendingWindows = model.pendingDialogFocusWindows
  model.pendingDialogFocusWindows = @[]
  var kept: seq[WindowId] = @[]
  for winId in pendingWindows:
    let winOpt = model.windowData(winId)
    if winOpt.isNone:
      result = true
      continue

    let win = winOpt.get()
    if not win.windowAdmitted() or not win.isFloating or win.isMinimized or
        win.parentExternalId == NullExternalWindowId or
        not model.parentFocusAllowed(winId, win.parentExternalId):
      result = true
      continue

    if model.parentReadyForDialogFocus(win.parentExternalId):
      discard model.focusWindow(winId, retargetViewport = false)
      result = true
    else:
      kept.add(winId)

  if kept.len != pendingWindows.len:
    result = true
  model.pendingDialogFocusWindows = kept
