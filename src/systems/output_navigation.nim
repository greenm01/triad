import std/[options, sets]
import focus, outputs, placement, workspaces
import ../core/msg
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

proc setWorkspaceOutput(model: var Model, tagId: TagId, outputId: OutputId): bool =
  let output = model.outputData(outputId)
  if output.isNone:
    return false
  let target = model.outputStableTarget(outputId, output.get())
  result = model.setTagOutput(tagId, outputId)
  result = model.setManualWorkspaceOutputTarget(tagId, target) or result
  result =
    model.setTagHomeOutput(
      tagId, target, pinned = model.tagHomeOutputPinned.contains(tagId)
    ) or result

proc focusVisibleWorkspace(model: var Model, tagId: TagId) =
  discard model.setActiveWorkspace(tagId)
  discard model.recordWorkspace(tagId)
  let focused = model.recomputeVisibleFocus(tagId)
  if focused != NullWindowId:
    discard model.recordFocus(focused)

proc moveWorkspaceToOutput(
    model: var Model, tagId: TagId, outputId: OutputId, follow: bool
): bool =
  if model.tagData(tagId).isNone or model.outputData(outputId).isNone:
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
  if follow:
    result = model.setOutputTag(outputId, tagId)
  elif sourceNeedsReplacement and sourceReplacement == NullTagId:
    return false
  result = model.setWorkspaceOutput(tagId, outputId) or result
  if sourceNeedsReplacement and sourceReplacement != NullTagId:
    result = model.assignOutputReplacement(sourceOutput, sourceReplacement) or result
    if not follow and model.activeTag == tagId:
      model.focusVisibleWorkspace(sourceReplacement)
  if follow:
    result = model.setActiveOutput(outputId) or result
    discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()

proc moveActiveWorkspaceToOutputTarget*(model: var Model, target: string): bool =
  let outputId = model.resolveOutputTarget(target)
  if outputId == NullOutputId:
    return false
  model.moveWorkspaceToOutput(model.ensureActiveWorkspace(), outputId, follow = true)

proc createWorkspaceOnOutput(model: var Model, outputId: OutputId, name: string): bool =
  if model.outputData(outputId).isNone:
    return false
  let tagId = model.ensureWorkspaceSlot(model.nextDynamicWorkspaceSlot())
  if tagId == NullTagId:
    return false
  discard model.setTagName(tagId, name)
  model.markWorkspaceCreated(tagId)
  discard model.setWorkspaceOutput(tagId, outputId)
  true

proc deactivateWorkspace(model: var Model, tagId: TagId): bool =
  let outputId = model.workspaceOutput(tagId)
  if outputId == NullOutputId or model.outputActiveTag(outputId) != tagId:
    return false
  for slot in model.sortedSlots():
    let candidate = model.tagForSlot(slot)
    if candidate == tagId or model.workspaceOutput(candidate) != outputId or
        not model.shellWorkspaceSlotVisible(slot):
      continue
    result = model.assignOutputReplacement(outputId, candidate)
    if model.activeTag == tagId:
      model.focusVisibleWorkspace(candidate)
    return

proc applyWorkspaceActions*(model: var Model, actions: openArray[WorkspaceAction]): bool =
  for action in actions:
    let tagId = TagId(action.workspaceId)
    let outputId = OutputId(action.outputId)
    case action.kind
    of WorkspaceActionKind.Create:
      result = model.createWorkspaceOnOutput(outputId, action.name) or result
    of WorkspaceActionKind.Activate:
      let tag = model.tagData(tagId)
      if tag.isSome:
        result = model.focusWorkspaceSlot(tag.get().slot) or result
      elif tagId == NullTagId and model.workspaceSlotConfigured(action.slot) and
          model.tagForSlot(action.slot) == NullTagId:
        result = model.focusWorkspaceSlot(action.slot) or result
    of WorkspaceActionKind.Assign:
      result = model.moveWorkspaceToOutput(tagId, outputId, follow = false) or result
    of WorkspaceActionKind.Deactivate:
      if model.tagData(tagId).isSome:
        result = model.deactivateWorkspace(tagId) or result
    of WorkspaceActionKind.Remove:
      if model.workspaceCanRemove(tagId):
        result = model.destroyTag(tagId) or result

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
