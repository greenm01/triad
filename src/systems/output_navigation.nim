import std/[options, sets]
import focus, outputs, placement, workspaces
import ../state/engine

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

  result = model.setActiveOutput(outputId)
  result = model.setOutputTag(outputId, tagId) or result
  result =
    model.setTagHomeOutput(
      tagId,
      model.outputStableTarget(outputId, outputOpt.get()),
      pinned = model.tagHomeOutputPinned.contains(tagId),
    ) or result
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
