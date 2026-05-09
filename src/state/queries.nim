import algorithm, options, tables
import iterators
import entity_manager
import ../types/core
import ../types/model

proc tagForSlot*(model: Model; slot: uint32): TagId =
  model.tagBySlot.getOrDefault(slot, NullTagId)

proc windowForExternal*(
    model: Model; externalId: ExternalWindowId): WindowId =
  model.externalWindowIds.getOrDefault(externalId, NullWindowId)

proc outputForExternal*(
    model: Model; externalId: ExternalOutputId): OutputId =
  model.externalOutputIds.getOrDefault(externalId, NullOutputId)

proc tagData*(model: Model; tagId: TagId): Option[TagData] =
  model.tags.entity(tagId)

proc windowData*(model: Model; winId: WindowId): Option[WindowData] =
  model.windows.entity(winId)

proc columnData*(model: Model; columnId: ColumnId): Option[ColumnData] =
  model.columns.entity(columnId)

proc outputData*(model: Model; outputId: OutputId): Option[OutputData] =
  model.outputs.entity(outputId)

proc groupData*(model: Model; groupId: GroupId): Option[GroupData] =
  model.groups.entity(groupId)

proc groupForWindow*(model: Model; winId: WindowId): GroupId =
  model.groupByWindow.getOrDefault(winId, NullGroupId)

proc windowHiddenByGroup*(model: Model; winId: WindowId): bool =
  let groupId = model.groupForWindow(winId)
  if groupId == NullGroupId:
    return false
  let groupOpt = model.groupData(groupId)
  groupOpt.isSome and groupOpt.get().activeWindow != winId

proc outputCount*(model: Model): int =
  for _ in model.outputsWithId():
    inc result

proc sortedSlots*(model: Model): seq[uint32] =
  for slot in model.tagSlots():
    result.add(slot)
  result.sort()

proc tagHasLiveWindows*(model: Model; tagId: TagId): bool =
  for _ in model.windowsOnTagWithId(tagId):
    return true
  false

proc visibleWorkspaceSlots*(model: Model): seq[uint32] =
  if model.visibleSlots.len > 0:
    return model.visibleSlots

  for slot in 1'u32 .. model.defaultWorkspaceCount:
    result.add(slot)

  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    if slot > model.defaultWorkspaceCount and
        (slot == model.activeSlot or model.tagHasLiveWindows(tagId)):
      result.add(slot)

  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

  if result.len > 0:
    let last = result[^1]
    let lastTag = model.tagForSlot(last)
    if last < MaxTagBits and lastTag != NullTagId and
        model.tagHasLiveWindows(lastTag):
      result.add(last + 1)

proc workspaceIndexForSlot*(model: Model; slot: uint32): uint32 =
  for idx, candidate in model.visibleWorkspaceSlots():
    if candidate == slot:
      return uint32(idx + 1)
  0

proc columnsForTag*(model: Model; tagId: TagId): seq[ColumnId] =
  for columnId, _ in model.columnsOnTagWithId(tagId):
    result.add(columnId)

proc windowsForColumn*(model: Model; columnId: ColumnId): seq[WindowId] =
  for winId, _ in model.windowsOnColumnWithId(columnId):
    result.add(winId)

proc windowsForTag*(model: Model; tagId: TagId): seq[WindowId] =
  for winId, _ in model.windowsOnTagWithId(tagId):
    result.add(winId)

proc columnIndexForTag*(
    model: Model; tagId: TagId; columnId: ColumnId): uint32 =
  for idx, candidate in model.columnsForTag(tagId):
    if candidate == columnId:
      return uint32(idx + 1)
  0

proc placementForWindowOnTag*(
    model: Model; tagId: TagId; winId: WindowId): Option[WindowPlacement] =
  let key = (tagId, winId)
  if not model.placementByTagWindow.hasKey(key):
    return none(WindowPlacement)
  some(model.placementByTagWindow[key])

proc sortedWindowIdsByExternal*(model: Model): seq[WindowId] =
  var externalByWindow: Table[WindowId, ExternalWindowId]
  for winId, win in model.windowsWithId():
    result.add(winId)
    externalByWindow[winId] = win.externalId
  result.sort(proc(a, b: WindowId): int =
    cmp(uint32(externalByWindow[a]), uint32(externalByWindow[b])))

proc sortedOutputIdsByExternal*(model: Model): seq[OutputId] =
  var externalByOutput: Table[OutputId, ExternalOutputId]
  for outputId, output in model.outputsWithId():
    result.add(outputId)
    externalByOutput[outputId] = output.externalId
  result.sort(proc(a, b: OutputId): int =
    cmp(uint32(externalByOutput[a]), uint32(externalByOutput[b])))

proc shellOutputName*(model: Model; outputId: OutputId): string =
  if outputId != NullOutputId:
    let outputOpt = model.outputData(outputId)
    if outputOpt.isNone:
      return "triad-0"
    let output = outputOpt.get()
    if output.name.len > 0:
      return output.name
    if output.externalId != NullExternalOutputId:
      return "river-" & $uint32(output.externalId)
  "triad-0"

proc workspaceOutput*(model: Model; tagId: TagId): OutputId =
  result = model.primaryOutput
  for outputId, outputTag in model.outputTagsWithId():
    if outputTag == tagId:
      return outputId

proc shellWorkspaceOutputName*(model: Model; tagId: TagId): string =
  model.shellOutputName(model.workspaceOutput(tagId))

proc firstWindowPosition*(model: Model; winId: WindowId):
    tuple[found: bool, tagId: TagId, slot, colIdx, winIdx: uint32] =
  for slot in model.visibleWorkspaceSlots():
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    let placementOpt = model.placementForWindowOnTag(tagId, winId)
    if placementOpt.isNone:
      continue
    let placement = placementOpt.get()
    if placement.columnId == NullColumnId:
      continue
    return (
      true,
      tagId,
      slot,
      model.columnIndexForTag(tagId, placement.columnId),
      placement.windowIdx
    )
  (false, NullTagId, 0'u32, 0'u32, 0'u32)
