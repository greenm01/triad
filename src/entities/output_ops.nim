import std/[options, sets, strutils, tables]
import ../state/[entity_manager, id_gen]
import ../types/[core, model]

proc addOutput*(
    model: var Model,
    externalId: ExternalOutputId,
    wlName = 0'u32,
    name = "",
    make = "",
    modelName = "",
    description = "",
    x = 0'i32,
    y = 0'i32,
    w = 0'i32,
    h = 0'i32,
    usableX = 0'i32,
    usableY = 0'i32,
    usableW = 0'i32,
    usableH = 0'i32,
    hasUsable = false,
): OutputId =
  if externalId != NullExternalOutputId and model.externalOutputIds.hasKey(externalId):
    return model.externalOutputIds[externalId]

  let id = model.counters.generateOutputId()
  model.outputs.insert(
    OutputData(
      id: id,
      externalId: externalId,
      wlName: wlName,
      name: name,
      make: make,
      model: modelName,
      description: description,
      x: x,
      y: y,
      w: w,
      h: h,
      usableX: usableX,
      usableY: usableY,
      usableW: usableW,
      usableH: usableH,
      hasUsable: hasUsable,
    )
  )
  if externalId != NullExternalOutputId:
    model.externalOutputIds[externalId] = id
  id

proc setOutputDimensions*(model: var Model, outputId: OutputId, w, h: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).w = max(0'i32, w)
  model.outputs.mEntity(outputId).h = max(0'i32, h)
  true

proc setOutputName*(model: var Model, outputId: OutputId, name: string): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).name = name
  true

proc setOutputIdentity*(
    model: var Model, outputId: OutputId, make, modelName: string
): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).make = make
  model.outputs.mEntity(outputId).model = modelName
  true

proc setOutputDescription*(
    model: var Model, outputId: OutputId, description: string
): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).description = description
  true

proc setOutputPosition*(model: var Model, outputId: OutputId, x, y: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).x = x
  model.outputs.mEntity(outputId).y = y
  true

proc setOutputUsable*(model: var Model, outputId: OutputId, x, y, w, h: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).usableX = x
  model.outputs.mEntity(outputId).usableY = y
  model.outputs.mEntity(outputId).usableW = max(0'i32, w)
  model.outputs.mEntity(outputId).usableH = max(0'i32, h)
  model.outputs.mEntity(outputId).hasUsable = true
  true

proc setOutputTag*(model: var Model, outputId: OutputId, tagId: TagId): bool =
  if model.outputs.entity(outputId).isNone or model.tags.entity(tagId).isNone:
    return false
  var duplicateOutputs: seq[OutputId] = @[]
  for mappedOutputId, mappedTagId in model.outputTags.pairs:
    if mappedOutputId != outputId and mappedTagId == tagId:
      duplicateOutputs.add(mappedOutputId)
  for mappedOutputId in duplicateOutputs:
    model.outputTags.del(mappedOutputId)
  model.outputTags[outputId] = tagId
  model.tagOutputs[tagId] = outputId
  if model.activeTag == tagId:
    model.activeOutput = outputId
  true

proc clearOutputTag*(model: var Model, outputId: OutputId): bool =
  if not model.outputTags.hasKey(outputId):
    return false
  model.outputTags.del(outputId)
  true

proc setActiveOutput*(model: var Model, outputId: OutputId): bool =
  if outputId == NullOutputId or model.outputs.entity(outputId).isNone:
    return false
  if model.activeOutput == outputId:
    return false
  model.activeOutput = outputId
  true

proc setTagOutput*(model: var Model, tagId: TagId, outputId: OutputId): bool =
  if model.tags.entity(tagId).isNone or model.outputs.entity(outputId).isNone:
    return false
  if model.tagOutputs.getOrDefault(tagId, NullOutputId) == outputId:
    return false
  model.tagOutputs[tagId] = outputId
  true

proc clearTagOutput*(model: var Model, tagId: TagId): bool =
  if not model.tagOutputs.hasKey(tagId):
    return false
  let outputId = model.tagOutputs[tagId]
  if model.outputTags.getOrDefault(outputId, NullTagId) == tagId:
    model.outputTags.del(outputId)
  model.tagOutputs.del(tagId)
  true

proc setTagHomeOutput*(
    model: var Model, tagId: TagId, target: string, pinned: bool
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  let normalized = target.strip()
  if normalized.len == 0:
    return false
  let oldTarget = model.tagHomeOutputTargets.getOrDefault(tagId, "")
  let oldPinned = model.tagHomeOutputPinned.contains(tagId)
  model.tagHomeOutputTargets[tagId] = normalized
  if pinned:
    model.tagHomeOutputPinned.incl(tagId)
  else:
    model.tagHomeOutputPinned.excl(tagId)
  oldTarget != normalized or oldPinned != pinned

proc clearTagHomeOutput*(model: var Model, tagId: TagId): bool =
  result =
    model.tagHomeOutputTargets.hasKey(tagId) or model.tagHomeOutputPinned.contains(
      tagId
    )
  model.tagHomeOutputTargets.del(tagId)
  model.tagHomeOutputPinned.excl(tagId)

proc rememberOutputSlot*(model: var Model, target: string, slot: uint32): bool =
  let normalized = target.strip()
  if normalized.len == 0 or slot == 0:
    return false
  if model.outputLastActiveSlots.getOrDefault(normalized, 0'u32) == slot:
    return false
  model.outputLastActiveSlots[normalized] = slot
  true

proc destroyOutput*(model: var Model, outputId: OutputId): bool =
  let outputOpt = model.outputs.entity(outputId)
  if outputOpt.isNone:
    return false
  let externalId = outputOpt.get().externalId
  if externalId != NullExternalOutputId:
    model.externalOutputIds.del(externalId)
  model.outputTags.del(outputId)
  var mappedTags: seq[TagId] = @[]
  for tagId, mappedOutputId in model.tagOutputs.pairs:
    if mappedOutputId == outputId:
      mappedTags.add(tagId)
  for tagId in mappedTags:
    model.tagOutputs.del(tagId)
  if model.activeOutput == outputId:
    model.activeOutput = NullOutputId
  if model.primaryOutput == outputId:
    model.primaryOutput = NullOutputId
  model.outputs.delete(outputId)
