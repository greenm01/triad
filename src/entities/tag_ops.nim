import options, tables
import active_workspace_ops
import history_ops
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/model
from ../types/runtime_values import LayoutMode, Scroller

proc addTag*(
    model: var Model; slot: uint32; name = ""; layoutMode = Scroller;
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

proc setTagFocus*(
    model: var Model; tagId: TagId; winId: WindowId): bool =
  if model.tags.entity(tagId).isNone:
    return false
  if winId != NullWindowId and model.windows.entity(winId).isNone:
    return false
  model.tags.mEntity(tagId).focusedWindow = winId
  true

proc setTagLayout*(model: var Model; tagId: TagId; mode: LayoutMode): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).layoutMode = mode
  true

proc setTagName*(model: var Model; tagId: TagId; name: string): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).name = name
  true

proc setTagMasterCount*(
    model: var Model; tagId: TagId; count: int): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).masterCount = max(1, count)
  true

proc setTagMasterRatio*(
    model: var Model; tagId: TagId; ratio: float32): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).masterSplitRatio =
    clamp(ratio, 0.05'f32, 0.95'f32)
  true

proc setTagViewportTarget*(
    model: var Model; tagId: TagId; xOffset, yOffset: float32): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).targetViewportXOffset = xOffset
  model.tags.mEntity(tagId).targetViewportYOffset = yOffset
  true

proc setTagViewportCurrent*(
    model: var Model; tagId: TagId; xOffset, yOffset: float32): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).currentViewportXOffset = xOffset
  model.tags.mEntity(tagId).currentViewportYOffset = yOffset
  true

proc setTagRestoredState*(model: var Model; tagId: TagId;
    name: string; layoutMode: LayoutMode;
    targetViewportXOffset, currentViewportXOffset, targetViewportYOffset,
    currentViewportYOffset: float32; masterCount: int;
    masterSplitRatio: float32): bool =
  if model.tags.entity(tagId).isNone:
    return false
  if name.len > 0 and model.tags.mEntity(tagId).name.len == 0:
    model.tags.mEntity(tagId).name = name
  model.tags.mEntity(tagId).layoutMode = layoutMode
  model.tags.mEntity(tagId).targetViewportXOffset = targetViewportXOffset
  model.tags.mEntity(tagId).currentViewportXOffset = currentViewportXOffset
  model.tags.mEntity(tagId).targetViewportYOffset = targetViewportYOffset
  model.tags.mEntity(tagId).currentViewportYOffset = currentViewportYOffset
  model.tags.mEntity(tagId).masterCount = max(1, masterCount)
  model.tags.mEntity(tagId).masterSplitRatio =
    clamp(masterSplitRatio, 0.05'f32, 0.95'f32)
  true

proc destroyTag*(model: var Model; tagId: TagId): bool =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false

  let tag = tagOpt.get()
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    if model.windowTags.hasKey(winId):
      var mask = model.windowTags[winId]
      mask.excl(tag.bit)
      model.windowTags[winId] = mask
    model.placementByTagWindow.del((tagId, winId))

  for columnId in model.columnsByTag.getOrDefault(tagId, @[]):
    model.windowsByColumn.del(columnId)
    discard model.columns.delete(columnId)

  model.columnsByTag.del(tagId)
  model.windowsByTag.del(tagId)
  model.tagBySlot.del(tag.slot)

  var outputIds: seq[OutputId] = @[]
  for outputId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      outputIds.add(outputId)
  for outputId in outputIds:
    model.outputTags.del(outputId)

  discard model.removeWorkspaceHistoryRef(tagId)
  discard model.clearActiveWorkspaceIfTag(tagId)
  model.tags.delete(tagId)
