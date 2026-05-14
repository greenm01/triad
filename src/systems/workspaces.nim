import std/[algorithm, options]
import outputs
import sticky_windows
import ../state/engine

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
  if tagRule.found and tagRule.rule.openOnOutput.len > 0:
    discard model.setTagHomeOutput(result, tagRule.rule.openOnOutput, pinned = true)
    let outputId = model.outputForTarget(tagRule.rule.openOnOutput)
    if outputId != NullOutputId:
      discard model.setTagOutput(result, outputId)
  else:
    discard model.learnTagOutputFromActive(result)
  discard model.syncStickyWindowsForWorkspace(result)

proc computedVisibleWorkspaceSlots*(model: Model): seq[uint32] =
  let defaultCount = model.defaultWorkspaceCount()
  for slot in 1'u32 .. defaultCount:
    result.add(slot)

  let activeSlot = model.activeWorkspaceSlot()
  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    if slot > defaultCount and
        (slot == activeSlot or model.tagHasNonStickyLiveWindows(tagId)):
      result.add(slot)

  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

proc trailingWorkspaceSlot*(model: Model): uint32 =
  let slots = model.computedVisibleWorkspaceSlots()
  if slots.len == 0:
    return 0
  let last = slots[^1]
  let tagId = model.tagForSlot(last)
  if last < MaxTagBits and tagId != NullTagId and model.tagHasNonStickyLiveWindows(
    tagId
  ):
    return last + 1
  0

proc visibleWorkspaceSlots(model: Model): seq[uint32] =
  result = model.computedVisibleWorkspaceSlots()
  let trailing = model.trailingWorkspaceSlot()
  if trailing != 0 and result.find(trailing) == -1:
    result.add(trailing)
    result.sort()

proc refreshVisibleWorkspaceSlots*(model: var Model) =
  discard model.replaceVisibleWorkspaceSlots(model.visibleWorkspaceSlots())

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
    if model.tagHasNonStickyLiveWindows(tagId):
      continue
    if model.destroyTag(tagId):
      result = true
  if result:
    model.refreshVisibleWorkspaceSlots()
