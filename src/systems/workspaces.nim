import std/[options, tables]
import outputs
import sticky_windows
import ../core/native_layout_codec
import ../state/engine
from ../types/runtime_values import LayoutSelectionKind

proc activeWorkspaceSlot*(model: Model): uint32 =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().slot
  if model.activeSlot != 0:
    return model.activeSlot
  0

proc ensureWorkspaceSlot*(model: var Model, slot: uint32, forcedLayout = 0): TagId =
  if slot == 0 or slot > MaxTagBits:
    return NullTagId
  result = model.tagForSlot(slot)
  if result != NullTagId:
    if forcedLayout != 0:
      discard model.setTagLayout(
        result, safeLayoutMode(forcedLayout, model.tag(result).get().layoutMode)
      )
    return result
  let tagRule = model.tagRuleForSlot(slot)
  let layoutMode =
    if forcedLayout != 0:
      safeLayoutMode(forcedLayout)
    elif tagRule.found and tagRule.rule.defaultLayoutSet:
      tagRule.rule.defaultLayout
    else:
      model.defaultWorkspaceLayout
  let name = if tagRule.found: tagRule.rule.name else: ""
  result = model.addTag(
    slot = slot,
    name = name,
    layoutMode = layoutMode,
    masterCount = model.defaultMasterCount(),
    masterSplitRatio = model.defaultMasterRatio(),
  )
  if forcedLayout == 0:
    let selection =
      if tagRule.found and tagRule.rule.defaultLayoutSet:
        tagRule.rule.defaultLayoutSelection
      else:
        model.defaultWorkspaceLayoutSelection
    case selection.kind
    of LayoutSelectionKind.Custom:
      discard model.setTagCustomLayout(result, selection.customId, selection)
      if selection.nativeId.nativeLayoutIdString() == FrameTreeLayoutId:
        discard model.syncTagFramesFromPlacement(result)
      elif selection.nativeId.nativeLayoutIdString() == BspTreeLayoutId:
        discard model.syncTagBspFromPlacement(result)
      elif selection.nativeId.nativeLayoutIdString() == SplitTreeLayoutId:
        discard model.syncTagSplitTreeFromPlacement(result)
    of LayoutSelectionKind.Native:
      discard model.setTagNativeLayout(result, selection.nativeId, selection.builtin)
      if selection.nativeId.nativeLayoutIdString() == FrameTreeLayoutId:
        discard model.syncTagFramesFromPlacement(result)
      elif selection.nativeId.nativeLayoutIdString() == BspTreeLayoutId:
        discard model.syncTagBspFromPlacement(result)
      elif selection.nativeId.nativeLayoutIdString() == SplitTreeLayoutId:
        discard model.syncTagSplitTreeFromPlacement(result)
    of LayoutSelectionKind.Builtin:
      discard
  if tagRule.found and tagRule.rule.openOnOutput.len > 0:
    discard model.setTagHomeOutput(result, tagRule.rule.openOnOutput, pinned = true)
    let outputId = model.outputForTarget(tagRule.rule.openOnOutput)
    if outputId != NullOutputId:
      discard model.setTagOutput(result, outputId)
  else:
    discard model.learnTagOutputFromActive(result)
  discard model.syncStickyWindowsForWorkspace(result)

proc preserveVisibleWorkspaceOrder(model: Model, slots: seq[uint32]): seq[uint32] =
  for slot in model.visibleSlots:
    if slots.find(slot) != -1 and result.find(slot) == -1:
      result.add(slot)
  for slot in slots:
    if result.find(slot) == -1:
      result.add(slot)

proc refreshVisibleWorkspaceSlots*(model: var Model) =
  let slots = model.projectedVisibleWorkspaceSlots()
  let ordered =
    if model.visibleSlots.len > 0:
      model.preserveVisibleWorkspaceOrder(slots)
    else:
      slots
  discard model.replaceVisibleWorkspaceSlots(ordered)

proc reorderWorkspaceIndex*(model: var Model, sourceIndex, targetIndex: uint32): bool =
  if sourceIndex == 0 or targetIndex == 0:
    return false
  var slots =
    if model.visibleSlots.len > 0:
      model.visibleSlots
    else:
      model.visibleWorkspaceSlots()
  let source = int(sourceIndex) - 1
  let target = int(targetIndex) - 1
  if source < 0 or source >= slots.len or target < 0 or target >= slots.len or
      source == target:
    return false
  let slot = slots[source]
  slots.delete(source)
  slots.insert(slot, target)
  discard model.replaceVisibleWorkspaceSlots(slots)
  true

proc ensureActiveWorkspace*(model: var Model): TagId =
  let activeOpt = model.tagData(model.activeTag)
  if activeOpt.isSome:
    let slot = activeOpt.get().slot
    if model.activeSlot != slot:
      discard model.setActiveWorkspace(model.activeTag)
      model.refreshVisibleWorkspaceSlots()
    return model.activeTag

  if model.activeSlot == 0:
    return NullTagId

  result = model.ensureWorkspaceSlot(model.activeSlot)
  if result != NullTagId:
    discard model.setActiveWorkspace(result)
    model.refreshVisibleWorkspaceSlots()

proc workspaceSlotForIndex*(model: Model, index: uint32): uint32 =
  if index == 0:
    return 0
  let slots = model.visibleWorkspaceSlots()
  let i = int(index) - 1
  if i >= 0 and i < slots.len:
    return slots[i]
  0

proc workspaceSlotForClampedIndex*(model: Model, index: uint32): uint32 =
  if index == 0:
    return 0
  let slots = model.visibleWorkspaceSlots()
  if slots.len == 0:
    return 0
  let i = min(int(index) - 1, slots.len - 1)
  slots[i]

proc nextDynamicWorkspaceSlot*(model: Model): uint32 =
  result = model.defaultWorkspaceCount() + 1
  for slot in model.sortedSlots():
    if slot >= result:
      result = slot + 1
  if result > MaxTagBits:
    result = 0

proc tagVisibleOnAnyOutput(model: Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  for _, visibleTagId in model.outputTagsWithId():
    if visibleTagId == tagId:
      return true
  false

proc validOutputVisibleTag(model: Model, outputId: OutputId): bool =
  let tagId = model.outputActiveTag(outputId)
  tagId != NullTagId and model.tagData(tagId).isSome

proc candidateTagForOutputSlot(
    model: var Model, slot: uint32, targetOutput: OutputId, excludeTag = NullTagId
): TagId =
  if slot == 0:
    return NullTagId
  let existingTagId = model.tagForSlot(slot)
  result = model.ensureWorkspaceSlot(slot)
  if result == NullTagId:
    return
  if result == excludeTag:
    return NullTagId
  let homeOutput = model.tagOutputs.getOrDefault(result, NullOutputId)
  if existingTagId != NullTagId and homeOutput != NullOutputId and
      homeOutput != targetOutput and model.outputData(homeOutput).isSome:
    return NullTagId
  if model.tagVisibleOnAnyOutput(result):
    return NullTagId
  if result == model.activeTag and targetOutput != model.activeOutput:
    return NullTagId

proc availableTagForOutput*(
    model: var Model, outputId: OutputId, excludeTag = NullTagId
): TagId =
  if outputId == NullOutputId or model.outputData(outputId).isNone:
    return NullTagId

  let output = model.outputData(outputId).get()
  let stableTarget = model.outputStableTarget(outputId, output)
  let rememberedSlot = model.outputLastActiveSlots.getOrDefault(stableTarget, 0'u32)
  result = model.candidateTagForOutputSlot(rememberedSlot, outputId, excludeTag)
  if result != NullTagId:
    return

  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    if model.tagOutputs.getOrDefault(tagId, NullOutputId) == outputId:
      result = model.candidateTagForOutputSlot(slot, outputId, excludeTag)
      if result != NullTagId:
        return

  for slot in model.visibleWorkspaceSlots():
    result = model.candidateTagForOutputSlot(slot, outputId, excludeTag)
    if result != NullTagId:
      return

  for slot in 1'u32 .. model.defaultWorkspaceCount():
    result = model.candidateTagForOutputSlot(slot, outputId, excludeTag)
    if result != NullTagId:
      return

  result = model.candidateTagForOutputSlot(
    model.nextDynamicWorkspaceSlot(), outputId, excludeTag
  )

proc ensureOutputWorkspaceCoverage*(model: var Model): bool =
  for outputId in model.sortedOutputsByGeometry():
    if model.validOutputVisibleTag(outputId):
      continue
    let tagId = model.availableTagForOutput(outputId)
    if tagId != NullTagId:
      result = model.setOutputTag(outputId, tagId) or result

proc tagHasFocusableWindow*(model: Model, tagId: TagId): bool =
  for _, win in model.windowsOnTagWithId(tagId):
    if not win.isUnmanagedGlobal and not win.isMinimized and win.windowAdmitted():
      return true
  false

proc tagHasNonStickyFocusableWindow*(model: Model, tagId: TagId): bool =
  for _, win in model.windowsOnTagWithId(tagId):
    if not win.isSticky and not win.isUnmanagedGlobal and not win.isMinimized and
        win.windowAdmitted():
      return true
  false

proc overviewWorkspaceStepSlot*(model: Model, direction: int): uint32 =
  if direction == 0:
    return 0

  let slots = model.visibleWorkspaceSlots()
  if slots.len == 0:
    return 0

  let active = model.activeWorkspaceSlot()
  var startIdx = slots.find(active)
  if startIdx == -1:
    startIdx =
      if direction > 0:
        slots.len - 1
      else:
        0
  let step = if direction > 0: 1 else: -1

  for offset in 1 .. slots.len:
    let idx = (startIdx + step * offset + slots.len * 2) mod slots.len
    let slot = slots[idx]
    if slot == active:
      continue
    return slot
  0

proc nearestWorkspaceSlot*(model: Model, direction: int, occupiedOnly: bool): uint32 =
  let active = model.activeWorkspaceSlot()
  let slots =
    if occupiedOnly:
      model.sortedSlots()
    else:
      model.visibleWorkspaceSlots()
  if slots.len == 0:
    return 0

  if direction < 0:
    for i in countdown(slots.len - 1, 0):
      let slot = slots[i]
      let tagId = model.tagForSlot(slot)
      if slot < active and
          (not occupiedOnly or model.tagHasNonStickyFocusableWindow(tagId)):
        return slot
  elif direction > 0:
    for slot in slots:
      let tagId = model.tagForSlot(slot)
      if slot > active and
          (not occupiedOnly or model.tagHasNonStickyFocusableWindow(tagId)):
        return slot
    if not occupiedOnly and active <= model.defaultWorkspaceCount() and
        active == slots[^1]:
      return model.nextDynamicWorkspaceSlot()
  0

proc lowerWorkspaceFallback*(model: Model, fromSlot: uint32): uint32 =
  let slots = model.visibleWorkspaceSlots()
  for i in countdown(slots.len - 1, 0):
    let slot = slots[i]
    if slot < fromSlot and slot != fromSlot:
      return slot
  if model.defaultWorkspaceCount() > 0:
    let below =
      if fromSlot > 1:
        fromSlot - 1
      else:
        1'u32
    return min(model.defaultWorkspaceCount(), max(1'u32, below))
  1'u32

proc outputsShowingTag(model: Model, tagId: TagId): seq[OutputId] =
  for outputId, outputTag in model.outputTagsWithId():
    if outputTag == tagId:
      result.add(outputId)

proc replaceVisibleDynamicWorkspace(model: var Model, tagId: TagId): bool =
  let outputs = model.outputsShowingTag(tagId)
  if outputs.len == 0:
    return true

  var replacements: seq[tuple[outputId: OutputId, tagId: TagId]]
  for outputId in outputs:
    let replacement = model.availableTagForOutput(outputId, excludeTag = tagId)
    if replacement == NullTagId:
      return false
    replacements.add((outputId: outputId, tagId: replacement))

  for replacement in replacements:
    result = model.setOutputTag(replacement.outputId, replacement.tagId) or result
  result = true

proc workspaceWasFocused(model: Model, tagId: TagId): bool =
  for historyTag in model.workspaceHistoryIds():
    if historyTag == tagId:
      return true
  false

proc pruneDynamicWorkspaces*(model: var Model): bool =
  let defaultCount = model.defaultWorkspaceCount()
  let activeSlot = model.activeWorkspaceSlot()
  let trailing = model.trailingWorkspaceSlot()
  let slots = model.sortedSlots()
  for slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId or slot <= defaultCount or slot == activeSlot or
        slot == trailing:
      continue
    let tagOpt = model.tagData(tagId)
    if model.restoreTag(slot).isSome or
        (tagOpt.isSome and model.hasDurableTagState(tagOpt.get())):
      continue
    if model.tagHasNonStickyLiveWindows(tagId):
      continue
    if model.tagVisibleOnOutput(tagId):
      if not model.workspaceWasFocused(tagId):
        continue
      if not model.replaceVisibleDynamicWorkspace(tagId):
        continue
    if model.destroyTag(tagId):
      result = true
  if result:
    discard model.compactDynamicWorkspaceSlots(defaultCount)
    model.refreshVisibleWorkspaceSlots()
