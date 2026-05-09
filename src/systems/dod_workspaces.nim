import algorithm, options
import ../state/engine
from ../types/legacy_model import Scroller

proc activeWorkspaceSlot*(model: DodModel): uint32 =
  if model.activeSlot != 0:
    return model.activeSlot
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().slot
  0

proc ensureWorkspaceSlot*(
    model: var DodModel; slot: uint32; forcedLayout = 0): TagId =
  if slot == 0 or slot > MaxTagBits:
    return NullTagId
  result = model.tagForSlot(slot)
  if result != NullTagId:
    if forcedLayout != 0:
      discard model.setTagLayout(
        result, dodSafeLayoutMode(forcedLayout, model.tag(result).get().layoutMode))
    return result
  let tagRule = model.tagRuleForSlot(slot)
  let layoutMode =
    if forcedLayout != 0:
      dodSafeLayoutMode(forcedLayout)
    elif tagRule.found:
      tagRule.rule.defaultLayout
    else:
      Scroller
  let name =
    if tagRule.found: tagRule.rule.name
    else: ""
  result = model.addTag(
    slot = slot,
    name = name,
    layoutMode = layoutMode,
    masterCount = model.dodDefaultMasterCount(),
    masterSplitRatio = model.dodDefaultMasterRatio())

proc computedVisibleWorkspaceSlots*(model: DodModel): seq[uint32] =
  let defaultCount = model.dodDefaultWorkspaceCount()
  for slot in 1'u32 .. defaultCount:
    result.add(slot)

  let activeSlot = model.activeWorkspaceSlot()
  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    if slot > defaultCount and
        (slot == activeSlot or model.tagHasLiveWindows(tagId)):
      result.add(slot)

  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

proc trailingWorkspaceSlot*(model: DodModel): uint32 =
  let slots = model.computedVisibleWorkspaceSlots()
  if slots.len == 0:
    return 0
  let last = slots[^1]
  let tagId = model.tagForSlot(last)
  if last < MaxTagBits and tagId != NullTagId and
      model.tagHasLiveWindows(tagId):
    return last + 1
  0

proc visibleWorkspaceSlots(model: DodModel): seq[uint32] =
  result = model.computedVisibleWorkspaceSlots()
  let trailing = model.trailingWorkspaceSlot()
  if trailing != 0 and result.find(trailing) == -1:
    result.add(trailing)
    result.sort()

proc refreshVisibleWorkspaceSlots*(model: var DodModel) =
  model.visibleSlots = model.visibleWorkspaceSlots()

proc workspaceSlotForIndex*(model: DodModel; index: uint32): uint32 =
  if index == 0:
    return 0
  let slots = model.visibleWorkspaceSlots()
  let i = int(index) - 1
  if i >= 0 and i < slots.len:
    return slots[i]
  0

proc workspaceSlotForClampedIndex*(model: DodModel; index: uint32): uint32 =
  if index == 0:
    return 0
  let slots = model.visibleWorkspaceSlots()
  if slots.len == 0:
    return 0
  let i = min(int(index) - 1, slots.len - 1)
  slots[i]

proc nextDynamicWorkspaceSlot*(model: DodModel): uint32 =
  result = model.dodDefaultWorkspaceCount() + 1
  for slot in model.sortedSlots():
    if slot >= result:
      result = slot + 1
  if result > MaxTagBits:
    result = 0

proc tagHasFocusableWindow*(model: DodModel; tagId: TagId): bool =
  for winId in model.windowsForTag(tagId):
    let winOpt = model.windowData(winId)
    if winOpt.isSome and not winOpt.get().isMinimized:
      return true
  false

proc nearestWorkspaceSlot*(
    model: DodModel; direction: int; occupiedOnly: bool): uint32 =
  let active = model.activeWorkspaceSlot()
  let slots =
    if occupiedOnly: model.sortedSlots()
    else: model.visibleWorkspaceSlots()
  if slots.len == 0:
    return 0

  if direction < 0:
    for i in countdown(slots.len - 1, 0):
      let slot = slots[i]
      let tagId = model.tagForSlot(slot)
      if slot < active and
          (not occupiedOnly or model.tagHasFocusableWindow(tagId)):
        return slot
  elif direction > 0:
    for slot in slots:
      let tagId = model.tagForSlot(slot)
      if slot > active and
          (not occupiedOnly or model.tagHasFocusableWindow(tagId)):
        return slot
    if not occupiedOnly and active <= model.dodDefaultWorkspaceCount() and
        active == slots[^1]:
      return model.nextDynamicWorkspaceSlot()
  0

proc lowerWorkspaceFallback*(model: DodModel; fromSlot: uint32): uint32 =
  let slots = model.visibleWorkspaceSlots()
  for i in countdown(slots.len - 1, 0):
    let slot = slots[i]
    if slot < fromSlot and slot != fromSlot:
      return slot
  if model.dodDefaultWorkspaceCount() > 0:
    let below = if fromSlot > 1: fromSlot - 1 else: 1'u32
    return min(model.dodDefaultWorkspaceCount(), max(1'u32, below))
  1'u32

proc pruneDynamicWorkspaces*(model: var DodModel): bool =
  let defaultCount = model.dodDefaultWorkspaceCount()
  let activeSlot = model.activeWorkspaceSlot()
  let trailing = model.trailingWorkspaceSlot()
  let slots = model.sortedSlots()
  for slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId or slot <= defaultCount or slot == activeSlot or
        slot == trailing:
      continue
    if model.tagHasLiveWindows(tagId):
      continue
    if model.destroyTag(tagId):
      result = true
  if result:
    model.refreshVisibleWorkspaceSlots()
