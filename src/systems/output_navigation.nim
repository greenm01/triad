import std/[options, sets]
import focus, outputs, placement, workspaces
import ../state/engine

proc assignOutputReplacement(model: var Model, outputId: OutputId, tagId: TagId): bool =
  if outputId == NullOutputId or tagId == NullTagId:
    return false
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return false
  result = model.setOutputTag(outputId, tagId)
  result = model.setTagOutput(tagId, outputId) or result
  if not model.tagHomeOutputPinned.contains(tagId):
    result =
      model.setTagHomeOutput(
        tagId, model.outputStableTarget(outputId, outputOpt.get()), pinned = false
      ) or result

proc focusOutputTarget*(model: var Model, target: string): bool =
  let outputId = model.resolveOutputTarget(target)
  if outputId == NullOutputId:
    return false

  result = model.setActiveOutput(outputId)
  let tagId = model.outputActiveTag(outputId)
  if tagId != NullTagId:
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome:
      return model.focusWorkspaceSlot(tagOpt.get().slot) or result

  let activeTag = model.ensureActiveWorkspace()
  if activeTag != NullTagId:
    result = model.setOutputTag(outputId, activeTag) or result
    discard model.setActiveWorkspace(activeTag)

proc moveActiveWorkspaceToOutputTarget*(model: var Model, target: string): bool =
  let outputId = model.resolveOutputTarget(target)
  if outputId == NullOutputId:
    return false
  let tagId = model.ensureActiveWorkspace()
  if tagId == NullTagId:
    return false
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return false

  let sourceOutput = model.workspaceOutput(tagId)
  if sourceOutput == outputId:
    return false
  let sourceNeedsReplacement =
    sourceOutput != NullOutputId and model.outputActiveTag(sourceOutput) == tagId
  let sourceReplacement =
    if sourceNeedsReplacement:
      model.availableTagForOutput(sourceOutput, excludeTag = tagId)
    else:
      NullTagId
  let stableTarget = model.outputStableTarget(outputId, outputOpt.get())

  result = model.setOutputTag(outputId, tagId) or result
  result = model.setTagOutput(tagId, outputId) or result
  result = model.setManualWorkspaceOutputTarget(tagId, stableTarget) or result
  result =
    model.setTagHomeOutput(
      tagId, stableTarget, pinned = model.tagHomeOutputPinned.contains(tagId)
    ) or result
  if sourceNeedsReplacement and sourceReplacement != NullTagId:
    result = model.assignOutputReplacement(sourceOutput, sourceReplacement) or result
  result = model.setActiveOutput(outputId) or result
  discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()

proc moveFocusedWindowToOutputTarget*(model: var Model, target: string): bool =
  let outputId = model.resolveOutputTarget(target)
  if outputId == NullOutputId:
    return false

  var tagId = model.outputActiveTag(outputId)
  if tagId == NullTagId:
    tagId = model.ensureActiveWorkspace()
    if tagId == NullTagId:
      return false
    discard model.setOutputTag(outputId, tagId)

  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false

  discard model.setActiveOutput(outputId)
  result = model.moveFocusedWindowToSlotAndFocus(tagOpt.get().slot)
  if result:
    discard model.setOutputTag(outputId, tagId)
    discard model.learnTagOutputFromActive(tagId)
