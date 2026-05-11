import options
import floating_policy
import ../state/engine

proc chooseFullscreenOutput*(
    model: Model; requested: ExternalOutputId): ExternalOutputId =
  if requested != NullExternalOutputId and
      model.outputForExternal(requested) != NullOutputId:
    return requested
  if model.primaryOutput != NullOutputId and model.hasOutput(
      model.primaryOutput):
    let output = model.output(model.primaryOutput)
    if output.isSome:
      return output.get().externalId
  if requested != NullExternalOutputId:
    return requested
  NullExternalOutputId

proc updateWindowDimensionsForExternal*(
    model: var Model; externalId: ExternalWindowId; w, h: int32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDimensions(winId, w, h)

proc updateWindowDecorationHintForExternal*(
    model: var Model; externalId: ExternalWindowId; hint: uint32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDecorationHint(winId, hint)

proc updateWindowPresentationHintForExternal*(
    model: var Model; externalId: ExternalWindowId; hint: uint32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowPresentationHint(winId, hint)

proc updateWindowParentForExternal*(model: var Model;
    externalId: ExternalWindowId; parentExternalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  if winOpt.get().parentExternalId == parentExternalId:
    return false
  result = true
  discard model.setWindowParent(winId, parentExternalId)
  if parentExternalId != NullExternalWindowId:
    result = model.applyParentFloatingPolicy(winId, parentExternalId) or result

proc updateWindowIdentifierForExternal*(
    model: var Model; externalId: ExternalWindowId; identifier: string):
    bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowIdentifier(winId, identifier)

proc updateWindowAppIdForExternal*(
    model: var Model; externalId: ExternalWindowId; appId: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowAppId(winId, appId)
  discard model.setWindowKeyboardShortcutsInhibit(winId, false, false)
  true

proc updateWindowTitleForExternal*(
    model: var Model; externalId: ExternalWindowId; title: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowTitle(winId, title)
  discard model.setWindowKeyboardShortcutsInhibit(winId, false, false)
  true

proc updateWindowDimensionsHintForExternal*(model: var Model;
    externalId: ExternalWindowId; minWidth, minHeight, maxWidth,
    maxHeight: int32): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  result = model.setWindowDimensionsHint(
    winId, minWidth, minHeight, maxWidth, maxHeight)
  let winOpt = model.windowData(winId)
  if winOpt.isSome and winOpt.get().parentExternalId != NullExternalWindowId:
    result = model.reconcileParentedWindowPolicy(winId) or result
  else:
    result = model.applyFixedSizeFloatingPolicy(winId) or result

proc requestFullscreenForExternal*(model: var Model;
    externalId: ExternalWindowId; requestedOutput: ExternalOutputId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  model.setWindowFullscreen(
    winId, true, model.chooseFullscreenOutput(requestedOutput))

proc exitFullscreenForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowFullscreen(winId, false)

proc toggleFullscreenForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFullscreen = not win.get().isFullscreen
  model.setWindowFullscreen(
    winId,
    nextFullscreen,
    if nextFullscreen: model.chooseFullscreenOutput(NullExternalOutputId)
    else: NullExternalOutputId)

proc requestMaximizeForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowMaximized(winId, true)

proc requestUnmaximizeForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowMaximized(winId, false)

proc requestMinimizeForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or not model.setWindowMinimized(winId, true):
    return false

  for tagId, tag in model.tagsWithId():
    if tag.focusedWindow == winId:
      var focused = NullWindowId
      for candidateId, candidate in model.windowsOnTagWithId(tagId):
        if not candidate.isMinimized:
          focused = candidateId
          break
      discard model.setTagFocus(tagId, focused)
  true

proc focusedWindow*(model: Model): WindowId =
  let tagOpt = model.tag(model.activeTag)
  if tagOpt.isNone:
    return NullWindowId
  tagOpt.get().focusedWindow

proc toggleFloatingFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFloating = not win.get().isFloating
  model.setWindowFloating(
    winId, nextFloating,
    if nextFloating: model.defaultFloatingGeom() else: GeometryRect())

proc toggleFullscreenFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFullscreen = not win.get().isFullscreen
  model.setWindowFullscreen(
    winId, nextFullscreen,
    if nextFullscreen: model.chooseFullscreenOutput(NullExternalOutputId)
    else: NullExternalOutputId)

proc toggleMaximizedFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  model.setWindowMaximized(winId, not win.get().isMaximized)

proc minimizeFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  if winId == NullWindowId:
    return false
  let win = model.window(winId)
  if win.isNone:
    return false
  model.requestMinimizeForExternal(win.get().externalId)

proc toggleKeyboardShortcutsInhibitFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  winId != NullWindowId and model.toggleWindowKeyboardShortcutsInhibit(winId)
