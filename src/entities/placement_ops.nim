import options, tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/dod_model

proc refreshWindowIndexes(
    model: var DodModel; tagId: TagId; columnId: ColumnId) =
  if model.windowsByColumn.hasKey(columnId):
    for idx, winId in model.windowsByColumn[columnId]:
      if model.placementByTagWindow.hasKey((tagId, winId)):
        model.placementByTagWindow[(tagId, winId)].windowIdx = uint32(idx + 1)

proc deleteColumnIfEmpty(
    model: var DodModel; tagId: TagId; columnId: ColumnId) =
  if model.windowsByColumn.getOrDefault(columnId, @[]).len > 0:
    return
  if model.columnsByTag.hasKey(tagId):
    let idx = model.columnsByTag[tagId].find(columnId)
    if idx != -1:
      model.columnsByTag[tagId].delete(idx)
  model.windowsByColumn.del(columnId)
  discard model.columns.delete(columnId)

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
        if oldColumn != columnId:
          model.deleteColumnIfEmpty(tagId, oldColumn)
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
      model.deleteColumnIfEmpty(tagId, columnId)

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
