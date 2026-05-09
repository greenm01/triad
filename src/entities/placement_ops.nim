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

proc moveWindowToColumn*(
    model: var DodModel; tagId: TagId; winId: WindowId;
    targetColumnId: ColumnId; targetIdx: int): bool =
  if model.columns.entity(targetColumnId).isNone:
    return false
  if model.columns.entity(targetColumnId).get().tagId != tagId:
    return false
  if model.windows.entity(winId).isNone:
    return false

  let key = (tagId, winId)
  let oldColumn =
    if model.placementByTagWindow.hasKey(key):
      model.placementByTagWindow[key].columnId
    else:
      NullColumnId
  var oldIdx = -1
  if oldColumn != NullColumnId and model.windowsByColumn.hasKey(oldColumn):
    oldIdx = model.windowsByColumn[oldColumn].find(winId)
    if oldIdx != -1:
      model.windowsByColumn[oldColumn].delete(oldIdx)
      model.refreshWindowIndexes(tagId, oldColumn)

  var insertIdx = max(0, targetIdx)
  let targetLen = model.windowsByColumn.mgetOrPut(targetColumnId, @[]).len
  insertIdx = min(insertIdx, targetLen)
  model.windowsByColumn[targetColumnId].insert(winId, insertIdx)

  if model.windowsByTag.mgetOrPut(tagId, @[]).find(winId) == -1:
    model.windowsByTag[tagId].add(winId)
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isSome:
    var mask = model.windowTags.getOrDefault(winId, EmptyTagMask)
    mask.incl(tagOpt.get().bit)
    model.windowTags[winId] = mask

  model.placementByTagWindow[key] = WindowPlacement(
    tagId: tagId,
    windowId: winId,
    columnId: targetColumnId,
    windowIdx: uint32(insertIdx + 1)
  )
  model.refreshWindowIndexes(tagId, targetColumnId)
  if oldColumn != NullColumnId and oldColumn != targetColumnId:
    model.deleteColumnIfEmpty(tagId, oldColumn)
  true

proc swapPlacedWindows*(
    model: var DodModel; firstTagId: TagId; firstWinId: WindowId;
    secondTagId: TagId; secondWinId: WindowId): bool =
  let firstKey = (firstTagId, firstWinId)
  let secondKey = (secondTagId, secondWinId)
  if not model.placementByTagWindow.hasKey(firstKey) or
      not model.placementByTagWindow.hasKey(secondKey):
    return false

  let first = model.placementByTagWindow[firstKey]
  let second = model.placementByTagWindow[secondKey]
  let firstIdx = int(first.windowIdx) - 1
  let secondIdx = int(second.windowIdx) - 1
  if firstIdx < 0 or secondIdx < 0:
    return false
  if not model.windowsByColumn.hasKey(first.columnId) or
      not model.windowsByColumn.hasKey(second.columnId):
    return false

  model.windowsByColumn[first.columnId][firstIdx] = secondWinId
  model.windowsByColumn[second.columnId][secondIdx] = firstWinId

  if firstTagId != secondTagId:
    if model.windowsByTag.hasKey(firstTagId):
      let idx = model.windowsByTag[firstTagId].find(firstWinId)
      if idx != -1:
        model.windowsByTag[firstTagId][idx] = secondWinId
    if model.windowsByTag.hasKey(secondTagId):
      let idx = model.windowsByTag[secondTagId].find(secondWinId)
      if idx != -1:
        model.windowsByTag[secondTagId][idx] = firstWinId

    let firstTag = model.tags.entity(firstTagId)
    let secondTag = model.tags.entity(secondTagId)
    if firstTag.isSome and secondTag.isSome:
      var firstMask = model.windowTags.getOrDefault(firstWinId, EmptyTagMask)
      firstMask.excl(firstTag.get().bit)
      firstMask.incl(secondTag.get().bit)
      model.windowTags[firstWinId] = firstMask

      var secondMask = model.windowTags.getOrDefault(secondWinId, EmptyTagMask)
      secondMask.excl(secondTag.get().bit)
      secondMask.incl(firstTag.get().bit)
      model.windowTags[secondWinId] = secondMask

  model.placementByTagWindow.del((firstTagId, firstWinId))
  model.placementByTagWindow.del((secondTagId, secondWinId))
  model.placementByTagWindow[(firstTagId, secondWinId)] = WindowPlacement(
    tagId: firstTagId,
    windowId: secondWinId,
    columnId: first.columnId,
    windowIdx: uint32(firstIdx + 1)
  )
  model.placementByTagWindow[(secondTagId, firstWinId)] = WindowPlacement(
    tagId: secondTagId,
    windowId: firstWinId,
    columnId: second.columnId,
    windowIdx: uint32(secondIdx + 1)
  )
  true
