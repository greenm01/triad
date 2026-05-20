import std/[options, tables]
import ../state/entity_manager
import ../types/[core, model]

proc syncPrimaryOutputTag*(model: var Model): bool =
  let outputId =
    if model.activeOutput != NullOutputId: model.activeOutput else: model.primaryOutput
  if outputId == NullOutputId or model.activeTag == NullTagId:
    return false
  if model.outputs.entity(outputId).isNone or model.tags.entity(model.activeTag).isNone:
    return false
  var staleOutputs: seq[OutputId] = @[]
  for mappedOutputId, mappedTagId in model.outputTags.pairs:
    if mappedOutputId != outputId and mappedTagId == model.activeTag:
      staleOutputs.add(mappedOutputId)
  for mappedOutputId in staleOutputs:
    model.outputTags.del(mappedOutputId)
  model.outputTags[outputId] = model.activeTag
  model.tagOutputs[model.activeTag] = outputId
  true

proc setActiveWorkspace*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let mappedOutput = model.tagOutputs.getOrDefault(tagId, NullOutputId)
  if mappedOutput != NullOutputId and model.outputs.entity(mappedOutput).isSome:
    model.activeOutput = mappedOutput
  elif model.activeOutput == NullOutputId and model.primaryOutput != NullOutputId and
      model.outputs.entity(model.primaryOutput).isSome:
    model.activeOutput = model.primaryOutput
  model.activeTag = tagId
  model.activeSlot = tagOpt.get().slot
  discard model.syncPrimaryOutputTag()
  true

proc clearActiveWorkspaceIfTag*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId or model.activeTag != tagId:
    return false
  model.activeTag = NullTagId
  model.activeSlot = 0
  true

proc replaceVisibleWorkspaceSlots*(model: var Model, slots: seq[uint32]): bool =
  model.visibleSlots = slots
  true
