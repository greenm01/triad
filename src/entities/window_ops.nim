import options, sequtils, tables
import placement_ops
import ../state/dod_iterators
import ../state/entity_manager
import ../state/id_gen
import ../types/core except Rect
import ../types/dod_model
from ../types/legacy_model import Rect

proc addWindow*(model: var DodModel; externalId: ExternalWindowId; title = "";
    appId = ""; widthProportion = 1.0'f32; heightProportion = 1.0'f32;
    isFloating = false; isFullscreen = false; isMaximized = false;
    isMinimized = false; fullscreenOutput = NullExternalOutputId;
    parentExternalId = NullExternalWindowId; identifier = ""; actualW = 0'i32;
    actualH = 0'i32; minWidth = 0'i32; minHeight = 0'i32; maxWidth = 0'i32;
    maxHeight = 0'i32; hasDecorationHint = false; decorationHint = 0'u32;
    hasPresentationHint = false; presentationHint = 0'u32;
    floatingGeom = Rect(); keyboardShortcutsInhibit = false;
    keyboardShortcutsInhibitBypass = false): WindowId =
  if externalId != NullExternalWindowId and
      model.externalWindowIds.hasKey(externalId):
    return model.externalWindowIds[externalId]

  let id = model.counters.generateWindowId()
  model.windows.insert(WindowData(
    id: id,
    externalId: externalId,
    title: title,
    appId: appId,
    widthProportion: widthProportion,
    heightProportion: heightProportion,
    isFloating: isFloating,
    isFullscreen: isFullscreen,
    isMaximized: isMaximized,
    isMinimized: isMinimized,
    fullscreenOutput: fullscreenOutput,
    parentExternalId: parentExternalId,
    identifier: identifier,
    actualW: actualW,
    actualH: actualH,
    minWidth: minWidth,
    minHeight: minHeight,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    hasDecorationHint: hasDecorationHint,
    decorationHint: decorationHint,
    hasPresentationHint: hasPresentationHint,
    presentationHint: presentationHint,
    floatingGeom: floatingGeom,
    keyboardShortcutsInhibit: keyboardShortcutsInhibit,
    keyboardShortcutsInhibitBypass: keyboardShortcutsInhibitBypass
  ))
  if externalId != NullExternalWindowId:
    model.externalWindowIds[externalId] = id
  model.windowTags[id] = EmptyTagMask
  id

proc setWindowCreatedState*(model: var DodModel; winId: WindowId;
    title = ""; appId = ""; identifier = ""; widthProportion = 1.0'f32;
    heightProportion = 1.0'f32; isFloating = false;
    floatingGeom = Rect(); keyboardShortcutsInhibit = false): bool =
  if model.windows.entity(winId).isNone:
    return false
  let externalId = model.windows.mEntity(winId).externalId
  model.windows.mEntity(winId) = WindowData(
    id: winId,
    externalId: externalId,
    title: title,
    appId: appId,
    identifier: identifier,
    widthProportion: widthProportion,
    heightProportion: heightProportion,
    isFloating: isFloating,
    floatingGeom: floatingGeom,
    keyboardShortcutsInhibit: keyboardShortcutsInhibit
  )
  true

proc destroyWindow*(model: var DodModel; winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false

  var tagIds: seq[TagId] = @[]
  for tagId, placementWinId, _ in model.placementsWithId():
    if placementWinId == winId:
      tagIds.add(tagId)
  for tagId in tagIds:
    discard model.removeWindowFromTag(tagId, winId)

  let externalId = winOpt.get().externalId
  if externalId != NullExternalWindowId:
    model.externalWindowIds.del(externalId)
  model.windowTags.del(winId)
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  for _, tag in model.tagsWithId():
    if tag.focusedWindow == winId:
      model.tags.mEntity(tag.id).focusedWindow = NullWindowId
  model.windows.delete(winId)

proc setWindowMinimized*(
    model: var DodModel; winId: WindowId; minimized: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isMinimized = minimized
  if minimized:
    model.windows.mEntity(winId).isMaximized = false
  true

proc setWindowWidthProportion*(
    model: var DodModel; winId: WindowId; widthProportion: float32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).widthProportion =
    clamp(widthProportion, 0.05'f32, 1.0'f32)
  true

proc setWindowHeightProportion*(
    model: var DodModel; winId: WindowId; heightProportion: float32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).heightProportion =
    clamp(heightProportion, 0.05'f32, 1.0'f32)
  true

proc setWindowTitle*(model: var DodModel; winId: WindowId; title: string):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).title = title
  true

proc setWindowAppId*(model: var DodModel; winId: WindowId; appId: string):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).appId = appId
  true

proc setWindowIdentifier*(
    model: var DodModel; winId: WindowId; identifier: string): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).identifier = identifier
  true

proc setWindowParent*(
    model: var DodModel; winId: WindowId; parentExternalId: ExternalWindowId):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).parentExternalId = parentExternalId
  true

proc setWindowDimensions*(
    model: var DodModel; winId: WindowId; actualW, actualH: int32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).actualW = max(0'i32, actualW)
  model.windows.mEntity(winId).actualH = max(0'i32, actualH)
  true

proc setWindowDimensionsHint*(model: var DodModel; winId: WindowId;
    minWidth, minHeight, maxWidth, maxHeight: int32): bool =
  if model.windows.entity(winId).isNone:
    return false

  var maxW = max(0'i32, maxWidth)
  var maxH = max(0'i32, maxHeight)
  let minW = max(0'i32, minWidth)
  let minH = max(0'i32, minHeight)
  if maxW > 0 and maxW < minW:
    maxW = minW
  if maxH > 0 and maxH < minH:
    maxH = minH

  model.windows.mEntity(winId).minWidth = minW
  model.windows.mEntity(winId).minHeight = minH
  model.windows.mEntity(winId).maxWidth = maxW
  model.windows.mEntity(winId).maxHeight = maxH
  true

proc setWindowDecorationHint*(
    model: var DodModel; winId: WindowId; hint: uint32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).hasDecorationHint = true
  model.windows.mEntity(winId).decorationHint = hint
  true

proc setWindowPresentationHint*(
    model: var DodModel; winId: WindowId; hint: uint32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).hasPresentationHint = true
  model.windows.mEntity(winId).presentationHint = hint
  true

proc setWindowFloating*(model: var DodModel; winId: WindowId;
    floating: bool; floatingGeom = Rect()): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isFloating = floating
  if floating:
    model.windows.mEntity(winId).floatingGeom = floatingGeom
  true

proc setWindowFullscreen*(model: var DodModel; winId: WindowId;
    fullscreen: bool; outputId = NullExternalOutputId): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isFullscreen = fullscreen
  model.windows.mEntity(winId).fullscreenOutput =
    if fullscreen: outputId else: NullExternalOutputId
  true

proc setWindowMaximized*(
    model: var DodModel; winId: WindowId; maximized: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isMaximized = maximized
  if maximized:
    model.windows.mEntity(winId).isMinimized = false
  true

proc setWindowKeyboardShortcutsInhibit*(model: var DodModel;
    winId: WindowId; inhibited: bool; bypass: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).keyboardShortcutsInhibit = inhibited
  model.windows.mEntity(winId).keyboardShortcutsInhibitBypass =
    inhibited and bypass
  true

proc toggleWindowKeyboardShortcutsInhibit*(
    model: var DodModel; winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  if winOpt.get().keyboardShortcutsInhibit:
    model.windows.mEntity(winId).keyboardShortcutsInhibitBypass =
      not winOpt.get().keyboardShortcutsInhibitBypass
  else:
    model.windows.mEntity(winId).keyboardShortcutsInhibit = true
    model.windows.mEntity(winId).keyboardShortcutsInhibitBypass = false
  true
