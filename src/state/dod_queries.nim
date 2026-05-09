import algorithm, tables
import entity_manager
import ../types/core
import ../types/dod_model

proc tagForSlot*(model: DodModel; slot: uint32): TagId =
  model.tagBySlot.getOrDefault(slot, NullTagId)

proc windowForExternal*(model: DodModel; externalId: ExternalWindowId): WindowId =
  model.externalWindowIds.getOrDefault(externalId, NullWindowId)

proc outputForExternal*(model: DodModel; externalId: ExternalOutputId): OutputId =
  model.externalOutputIds.getOrDefault(externalId, NullOutputId)

proc sortedSlots*(model: DodModel): seq[uint32] =
  for slot in model.tagBySlot.keys:
    result.add(slot)
  result.sort()

proc tagHasLiveWindows*(model: DodModel; tagId: TagId): bool =
  if not model.windowsByTag.hasKey(tagId):
    return false
  for winId in model.windowsByTag[tagId]:
    if model.windows.hasEntity(winId):
      return true
  false

proc visibleWorkspaceSlots*(model: DodModel): seq[uint32] =
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
    if last < MaxTagBits and lastTag != NullTagId and model.tagHasLiveWindows(lastTag):
      result.add(last + 1)

proc workspaceIndexForSlot*(model: DodModel; slot: uint32): uint32 =
  for idx, candidate in model.visibleWorkspaceSlots():
    if candidate == slot:
      return uint32(idx + 1)
  0

proc columnsForTag*(model: DodModel; tagId: TagId): seq[ColumnId] =
  model.columnsByTag.getOrDefault(tagId, @[])

proc windowsForColumn*(model: DodModel; columnId: ColumnId): seq[WindowId] =
  model.windowsByColumn.getOrDefault(columnId, @[])

proc windowsForTag*(model: DodModel; tagId: TagId): seq[WindowId] =
  model.windowsByTag.getOrDefault(tagId, @[])

proc columnIndexForTag*(model: DodModel; tagId: TagId; columnId: ColumnId): uint32 =
  let columns = model.columnsForTag(tagId)
  for idx, candidate in columns:
    if candidate == columnId:
      return uint32(idx + 1)
  0

proc shellOutputName*(model: DodModel; outputId: OutputId): string =
  if outputId != NullOutputId and model.outputs.hasEntity(outputId):
    let output = model.outputs.getEntity(outputId)
    if output.name.len > 0:
      return output.name
    if output.externalId != NullExternalOutputId:
      return "river-" & $uint32(output.externalId)
  "triad-0"

proc workspaceOutput*(model: DodModel; tagId: TagId): OutputId =
  result = model.primaryOutput
  for outputId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      return outputId

proc shellWorkspaceOutputName*(model: DodModel; tagId: TagId): string =
  model.shellOutputName(model.workspaceOutput(tagId))
