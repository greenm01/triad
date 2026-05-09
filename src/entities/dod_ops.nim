import options, sequtils, tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core except Rect
import ../types/dod_model
from ../types/legacy_model import LayoutMode, Rect, Scroller

proc addTag*(
    model: var DodModel; slot: uint32; name = ""; layoutMode = Scroller;
    focusedWindow = NullWindowId; targetViewportXOffset = 0.0'f32;
    currentViewportXOffset = 0.0'f32; targetViewportYOffset = 0.0'f32;
    currentViewportYOffset = 0.0'f32; masterCount = 1;
    masterSplitRatio = 0.55'f32): TagId =
  if model.tagBySlot.hasKey(slot):
    return model.tagBySlot[slot]

  let id = model.counters.generateTagId()
  let tag = TagData(
    id: id,
    slot: slot,
    bit: tagBit(slot),
    name: name,
    layoutMode: layoutMode,
    focusedWindow: focusedWindow,
    targetViewportXOffset: targetViewportXOffset,
    currentViewportXOffset: currentViewportXOffset,
    targetViewportYOffset: targetViewportYOffset,
    currentViewportYOffset: currentViewportYOffset,
    masterCount: max(1, masterCount),
    masterSplitRatio: max(0.05'f32, min(0.95'f32, masterSplitRatio))
  )
  model.tags.insert(tag)
  model.tagBySlot[slot] = id
  model.columnsByTag[id] = @[]
  model.windowsByTag[id] = @[]
  id

proc addColumn*(
    model: var DodModel; tagId: TagId; widthProportion = 1.0'f32): ColumnId =
  if model.tags.entity(tagId).isNone:
    raise newException(ValueError, "column tag does not exist: " & $tagId)

  let id = model.counters.generateColumnId()
  model.columns.insert(ColumnData(
    id: id,
    tagId: tagId,
    widthProportion: max(0.05'f32, min(1.0'f32, widthProportion))
  ))
  model.columnsByTag.mgetOrPut(tagId, @[]).add(id)
  model.windowsByColumn[id] = @[]
  id

proc addOutput*(
    model: var DodModel; externalId: ExternalOutputId; wlName = 0'u32;
    name = ""; x = 0'i32; y = 0'i32; w = 0'i32; h = 0'i32;
    usableX = 0'i32; usableY = 0'i32; usableW = 0'i32; usableH = 0'i32;
    hasUsable = false): OutputId =
  if externalId != NullExternalOutputId and
      model.externalOutputIds.hasKey(externalId):
    return model.externalOutputIds[externalId]

  let id = model.counters.generateOutputId()
  model.outputs.insert(OutputData(
    id: id,
    externalId: externalId,
    wlName: wlName,
    name: name,
    x: x,
    y: y,
    w: w,
    h: h,
    usableX: usableX,
    usableY: usableY,
    usableW: usableW,
    usableH: usableH,
    hasUsable: hasUsable
  ))
  if externalId != NullExternalOutputId:
    model.externalOutputIds[externalId] = id
  id

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

proc refreshWindowIndexes(
    model: var DodModel; tagId: TagId; columnId: ColumnId) =
  if model.windowsByColumn.hasKey(columnId):
    for idx, winId in model.windowsByColumn[columnId]:
      if model.placementByTagWindow.hasKey((tagId, winId)):
        model.placementByTagWindow[(tagId, winId)].windowIdx = uint32(idx + 1)

proc placeWindow*(
    model: var DodModel; tagId: TagId; columnId: ColumnId;
    winId: WindowId) =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    raise newException(ValueError, "placement tag does not exist: " & $tagId)
  let columnOpt = model.columns.entity(columnId)
  if columnOpt.isNone:
    raise newException(
      ValueError, "placement column does not exist: " & $columnId)
  if model.windows.entity(winId).isNone:
    raise newException(ValueError, "placement window does not exist: " & $winId)
  if columnOpt.get().tagId != tagId:
    raise newException(
      ValueError, "placement column belongs to a different tag")

  let key = (tagId, winId)
  if model.placementByTagWindow.hasKey(key):
    let oldColumn = model.placementByTagWindow[key].columnId
    if model.windowsByColumn.hasKey(oldColumn):
      let oldIdx = model.windowsByColumn[oldColumn].find(winId)
      if oldIdx != -1:
        model.windowsByColumn[oldColumn].delete(oldIdx)
        model.refreshWindowIndexes(tagId, oldColumn)
  elif model.windowsByTag.mgetOrPut(tagId, @[]).find(winId) == -1:
    model.windowsByTag[tagId].add(winId)

  if model.windowsByColumn.mgetOrPut(columnId, @[]).find(winId) == -1:
    model.windowsByColumn[columnId].add(winId)
  let winIdx = uint32(model.windowsByColumn[columnId].find(winId) + 1)
  model.placementByTagWindow[key] = WindowPlacement(
    tagId: tagId,
    windowId: winId,
    columnId: columnId,
    windowIdx: winIdx
  )

  var mask = model.windowTags.getOrDefault(winId, EmptyTagMask)
  mask.incl(tagOpt.get().bit)
  model.windowTags[winId] = mask

proc removeWindowFromTag*(
    model: var DodModel; tagId: TagId; winId: WindowId): bool =
  let key = (tagId, winId)
  if not model.placementByTagWindow.hasKey(key):
    return false

  let columnId = model.placementByTagWindow[key].columnId
  if model.windowsByColumn.hasKey(columnId):
    let idx = model.windowsByColumn[columnId].find(winId)
    if idx != -1:
      model.windowsByColumn[columnId].delete(idx)
      model.refreshWindowIndexes(tagId, columnId)

  if model.windowsByTag.hasKey(tagId):
    let idx = model.windowsByTag[tagId].find(winId)
    if idx != -1:
      model.windowsByTag[tagId].delete(idx)

  model.placementByTagWindow.del(key)
  let tagOpt = model.tags.entity(tagId)
  if model.windowTags.hasKey(winId) and tagOpt.isSome:
    var mask = model.windowTags[winId]
    mask.excl(tagOpt.get().bit)
    model.windowTags[winId] = mask
  true

proc destroyWindow*(model: var DodModel; winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false

  var tagIds: seq[TagId] = @[]
  for key in model.placementByTagWindow.keys:
    if key[1] == winId:
      tagIds.add(key[0])
  for tagId in tagIds:
    discard model.removeWindowFromTag(tagId, winId)

  let externalId = winOpt.get().externalId
  if externalId != NullExternalWindowId:
    model.externalWindowIds.del(externalId)
  model.windowTags.del(winId)
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  for tag in model.tags.entities:
    if tag.focusedWindow == winId:
      model.tags.mEntity(tag.id).focusedWindow = NullWindowId
  model.windows.delete(winId)
