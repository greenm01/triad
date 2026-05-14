import std/[options, tables]
import ../state/[entity_manager, id_gen]
import ../types/[core, model]

proc addColumn*(
    model: var Model,
    tagId: TagId,
    widthProportion = 1.0'f32,
    isFullWidth = false,
    scrollerSingleProportion = 0.0'f32,
): ColumnId =
  if model.tags.entity(tagId).isNone:
    raise newException(ValueError, "column tag does not exist: " & $tagId)

  let id = model.counters.generateColumnId()
  model.columns.insert(
    ColumnData(
      id: id,
      tagId: tagId,
      widthProportion: max(0.05'f32, min(1.0'f32, widthProportion)),
      scrollerSingleProportion: clamp(scrollerSingleProportion, 0.0'f32, 1.0'f32),
      isFullWidth: isFullWidth,
      focusedWindow: NullWindowId,
    )
  )
  model.columnsByTag.mgetOrPut(tagId, @[]).add(id)
  model.windowsByColumn[id] = @[]
  id

proc insertColumn*(
    model: var Model,
    tagId: TagId,
    index: int,
    widthProportion = 1.0'f32,
    isFullWidth = false,
    scrollerSingleProportion = 0.0'f32,
): ColumnId =
  result =
    model.addColumn(tagId, widthProportion, isFullWidth, scrollerSingleProportion)
  let lastIdx = model.columnsByTag[tagId].len - 1
  let targetIdx = clamp(index, 0, lastIdx)
  if targetIdx != lastIdx:
    model.columnsByTag[tagId].delete(lastIdx)
    model.columnsByTag[tagId].insert(result, targetIdx)

proc setColumnWidth*(
    model: var Model, columnId: ColumnId, widthProportion: float32
): bool =
  if model.columns.entity(columnId).isNone:
    return false
  model.columns.mEntity(columnId).widthProportion =
    clamp(widthProportion, 0.05'f32, 1.0'f32)
  model.columns.mEntity(columnId).isFullWidth = false
  true

proc setColumnFullWidth*(model: var Model, columnId: ColumnId, fullWidth: bool): bool =
  if model.columns.entity(columnId).isNone:
    return false
  if model.columns.mEntity(columnId).isFullWidth == fullWidth:
    return false
  model.columns.mEntity(columnId).isFullWidth = fullWidth
  true

proc setColumnScrollerSingleProportion*(
    model: var Model, columnId: ColumnId, proportion: float32
): bool =
  if model.columns.entity(columnId).isNone:
    return false
  let normalized =
    if proportion > 0.0'f32:
      clamp(proportion, 0.05'f32, 1.0'f32)
    else:
      0.0'f32
  if model.columns.mEntity(columnId).scrollerSingleProportion == normalized:
    return false
  model.columns.mEntity(columnId).scrollerSingleProportion = normalized
  true

proc setColumnFocus*(model: var Model, columnId: ColumnId, winId: WindowId): bool =
  if model.columns.entity(columnId).isNone:
    return false
  if winId != NullWindowId and model.windows.entity(winId).isNone:
    return false
  model.columns.mEntity(columnId).focusedWindow = winId
  true

proc toggleColumnFullWidth*(model: var Model, columnId: ColumnId): bool =
  if model.columns.entity(columnId).isNone:
    return false
  model.columns.mEntity(columnId).isFullWidth =
    not model.columns.mEntity(columnId).isFullWidth
  true

proc moveColumn*(model: var Model, tagId: TagId, fromIdx, toIdx: int): bool =
  if not model.columnsByTag.hasKey(tagId):
    return false
  let count = model.columnsByTag[tagId].len
  if fromIdx < 0 or fromIdx >= count or toIdx < 0 or toIdx >= count:
    return false
  if fromIdx == toIdx:
    return true
  let columnId = model.columnsByTag[tagId][fromIdx]
  model.columnsByTag[tagId].delete(fromIdx)
  model.columnsByTag[tagId].insert(columnId, toIdx)
  true
