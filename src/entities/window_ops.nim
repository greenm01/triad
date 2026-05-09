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
