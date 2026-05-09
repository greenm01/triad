import options
import ../state/engine

proc defaultFloatingGeom*(model: DodModel): LegacyRect =
  model.dodDefaultFloatingGeom()

proc chooseFullscreenOutput*(
    model: DodModel; requested: ExternalOutputId): ExternalOutputId =
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
    model: var DodModel; externalId: ExternalWindowId; w, h: int32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDimensions(winId, w, h)

proc updateWindowDecorationHintForExternal*(
    model: var DodModel; externalId: ExternalWindowId; hint: uint32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDecorationHint(winId, hint)

proc updateWindowPresentationHintForExternal*(
    model: var DodModel; externalId: ExternalWindowId; hint: uint32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowPresentationHint(winId, hint)

proc updateWindowParentForExternal*(model: var DodModel;
    externalId: ExternalWindowId; parentExternalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowParent(winId, parentExternalId)

proc updateWindowIdentifierForExternal*(
    model: var DodModel; externalId: ExternalWindowId; identifier: string):
    bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowIdentifier(winId, identifier)

proc updateWindowAppIdForExternal*(
    model: var DodModel; externalId: ExternalWindowId; appId: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowAppId(winId, appId)
  discard model.setWindowKeyboardShortcutsInhibit(winId, false, false)
  true

proc updateWindowTitleForExternal*(
    model: var DodModel; externalId: ExternalWindowId; title: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowTitle(winId, title)
  discard model.setWindowKeyboardShortcutsInhibit(winId, false, false)
  true

proc updateWindowDimensionsHintForExternal*(model: var DodModel;
    externalId: ExternalWindowId; minWidth, minHeight, maxWidth,
    maxHeight: int32): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDimensionsHint(
    winId, minWidth, minHeight, maxWidth, maxHeight)

proc requestFullscreenForExternal*(model: var DodModel;
    externalId: ExternalWindowId; requestedOutput: ExternalOutputId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  model.setWindowFullscreen(
    winId, true, model.chooseFullscreenOutput(requestedOutput))

proc exitFullscreenForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowFullscreen(winId, false)

proc requestMaximizeForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowMaximized(winId, true)

proc requestUnmaximizeForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowMaximized(winId, false)

proc requestMinimizeForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
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

proc focusedWindow*(model: DodModel): WindowId =
  let tagOpt = model.tag(model.activeTag)
  if tagOpt.isNone:
    return NullWindowId
  tagOpt.get().focusedWindow

proc toggleFloatingFocused*(model: var DodModel): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFloating = not win.get().isFloating
  model.setWindowFloating(
    winId, nextFloating,
    if nextFloating: model.defaultFloatingGeom() else: LegacyRect())

proc toggleFullscreenFocused*(model: var DodModel): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFullscreen = not win.get().isFullscreen
  model.setWindowFullscreen(
    winId, nextFullscreen,
    if nextFullscreen: model.chooseFullscreenOutput(NullExternalOutputId)
    else: NullExternalOutputId)

proc toggleMaximizedFocused*(model: var DodModel): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  model.setWindowMaximized(winId, not win.get().isMaximized)

proc minimizeFocused*(model: var DodModel): bool =
  let winId = model.focusedWindow()
  if winId == NullWindowId:
    return false
  let win = model.window(winId)
  if win.isNone:
    return false
  model.requestMinimizeForExternal(win.get().externalId)

proc toggleKeyboardShortcutsInhibitFocused*(model: var DodModel): bool =
  let winId = model.focusedWindow()
  winId != NullWindowId and model.toggleWindowKeyboardShortcutsInhibit(winId)
