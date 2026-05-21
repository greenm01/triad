import std/[options, tables]
import ../state/entity_manager
import ../types/[core, model]
import output_ops

proc syncPrimaryOutputTag*(model: var Model): bool =
  let outputId =
    if model.activeOutput != NullOutputId: model.activeOutput else: model.primaryOutput
  if outputId == NullOutputId or model.activeTag == NullTagId:
    return false
  if model.outputs.entity(outputId).isNone or model.tags.entity(model.activeTag).isNone:
    return false
  model.setOutputTag(outputId, model.activeTag)

proc setActiveWorkspace*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  var mappedOutput = NullOutputId
  for outputId, outputTag in model.outputTags.pairs:
    if outputTag == tagId and model.outputs.entity(outputId).isSome:
      mappedOutput = outputId
      break
  if mappedOutput == NullOutputId:
    mappedOutput =
      if model.activeOutput != NullOutputId and
          model.outputs.entity(model.activeOutput).isSome:
        model.activeOutput
      else:
        model.tagOutputs.getOrDefault(tagId, NullOutputId)
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
