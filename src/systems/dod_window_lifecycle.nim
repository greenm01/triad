import algorithm, options, sequtils, strutils
import ../state/engine
from ../types/legacy_model import Grid, LayoutMode, MasterStack, Monocle,
  Scroller, VerticalScroller

proc defaultWorkspaceCount(model: DodModel): uint32 =
  if model.defaultWorkspaceCount == 0:
    DefaultWorkspaceCount
  else:
    min(model.defaultWorkspaceCount, MaxTagBits)

proc defaultColumnWidth(model: DodModel): float32 =
  if model.defaultColumnWidth > 0:
    clamp(model.defaultColumnWidth, 0.05'f32, 1.0'f32)
  else:
    DefaultColumnWidth

proc safeLayoutMode(stored: int; fallback = Scroller): LayoutMode =
  if stored >= ord(low(LayoutMode)) + 1 and
      stored <= ord(high(LayoutMode)) + 1:
    LayoutMode(stored - 1)
  else:
    fallback

proc tagRuleForSlot(model: DodModel; slot: uint32):
    tuple[found: bool, rule: TagRuleData] =
  for rule in model.tagRules:
    if rule.slot == slot:
      return (true, rule)
  (false, TagRuleData())

proc matches(rule: WindowRuleData; appId, title: string): bool =
  let appIdMatches = rule.appIdMatch == "" or appId.contains(rule.appIdMatch)
  let titleMatches = rule.titleMatch == "" or title.contains(rule.titleMatch)
  appIdMatches and titleMatches

proc windowRuleFor(model: DodModel; appId, title: string):
    tuple[found: bool, rule: WindowRuleData] =
  for rule in model.windowRules:
    if rule.matches(appId, title):
      return (true, rule)
  (false, WindowRuleData())

proc activeWorkspaceSlot(model: DodModel): uint32 =
  if model.activeSlot != 0:
    return model.activeSlot
  let tagOpt = model.tag(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().slot
  0

proc ensureWorkspaceSlot(
    model: var DodModel; slot: uint32; forcedLayout = 0): TagId =
  if slot == 0 or slot > MaxTagBits:
    return NullTagId
  result = model.tagForSlot(slot)
  if result != NullTagId:
    if forcedLayout != 0:
      discard model.setTagLayout(
        result, safeLayoutMode(forcedLayout, model.tag(result).get().layoutMode))
    return

  let tagRule = model.tagRuleForSlot(slot)
  let layoutMode =
    if forcedLayout != 0:
      safeLayoutMode(forcedLayout)
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
    masterSplitRatio = model.dodDefaultMasterRatio()
  )

proc addWindowColumn(
    model: var DodModel; tagId: TagId; winId: WindowId): ColumnId =
  result = model.addColumn(tagId, model.defaultColumnWidth())
  discard model.moveWindowToColumn(tagId, winId, result, 0)

proc firstFocusableWindow(model: DodModel; tagId: TagId): WindowId =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isMinimized:
      return winId
  NullWindowId

proc recomputeVisibleFocus(model: var DodModel; tagId: TagId): WindowId =
  let tagOpt = model.tag(tagId)
  if tagOpt.isNone:
    return NullWindowId
  let focused = tagOpt.get().focusedWindow
  let winOpt = model.window(focused)
  if focused != NullWindowId and winOpt.isSome and
      not winOpt.get().isMinimized and
      model.placementForWindowOnTag(tagId, focused).isSome:
    return focused
  result = model.firstFocusableWindow(tagId)
  discard model.setTagFocus(tagId, result)

proc removeWindowFromAllTags(model: var DodModel; winId: WindowId): bool =
  let slots = model.sortedSlots()
  for slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId != NullTagId and model.removeWindowFromTag(tagId, winId):
      discard model.recomputeVisibleFocus(tagId)
      result = true

proc recordFocus(model: var DodModel; winId: WindowId) =
  if winId == NullWindowId or model.window(winId).isNone:
    return
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  model.focusHistory.add(winId)
  while model.focusHistory.len > 32:
    model.focusHistory.delete(0)

proc recordWorkspace(model: var DodModel; tagId: TagId) =
  if tagId == NullTagId or model.tag(tagId).isNone:
    return
  model.workspaceHistory.keepIf(proc(id: TagId): bool = id != tagId)
  model.workspaceHistory.add(tagId)
  while model.workspaceHistory.len > 32:
    model.workspaceHistory.delete(0)

proc focusedOnActiveTag(model: DodModel): WindowId =
  let tagOpt = model.tag(model.activeTag)
  if tagOpt.isNone:
    return NullWindowId
  let focused = tagOpt.get().focusedWindow
  let winOpt = model.window(focused)
  if focused != NullWindowId and winOpt.isSome and
      not winOpt.get().isMinimized and
      model.placementForWindowOnTag(model.activeTag, focused).isSome:
    return focused
  NullWindowId

proc tagForWindow(model: DodModel; winId: WindowId): TagId =
  if model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, winId).isSome:
    return model.activeTag
  let position = model.firstWindowPosition(winId)
  if position.found:
    return position.tagId
  NullTagId

proc isFocusableWindow(model: DodModel; winId: WindowId): bool =
  let winOpt = model.window(winId)
  winOpt.isSome and not winOpt.get().isMinimized

proc focusWindow(model: var DodModel; winId: WindowId): bool =
  if model.window(winId).isNone:
    return false
  let tagId = model.tagForWindow(winId)
  if tagId == NullTagId:
    return false
  let tagOpt = model.tag(tagId)
  if tagOpt.isNone:
    return false
  discard model.setWindowMinimized(winId, false)
  model.activeTag = tagId
  model.activeSlot = tagOpt.get().slot
  model.recordWorkspace(tagId)
  discard model.setTagFocus(tagId, winId)
  model.recordFocus(winId)
  if model.primaryOutput != NullOutputId:
    discard model.setOutputTag(model.primaryOutput, tagId)
  true

proc tagHasFocusableWindow(model: DodModel; tagId: TagId): bool =
  for winId in model.windowsForTag(tagId):
    if model.isFocusableWindow(winId):
      return true
  false

proc focusMostRecentWindow(model: var DodModel): bool =
  var candidates: seq[WindowId] = @[]
  for candidate in model.focusHistory:
    if model.isFocusableWindow(candidate) and
        model.tagForWindow(candidate) != NullTagId:
      candidates.add(candidate)
  model.focusHistory = candidates
  if candidates.len == 0:
    return false
  model.focusWindow(candidates[^1])

proc isRestorableWorkspace(model: DodModel; tagId: TagId): bool =
  let tagOpt = model.tag(tagId)
  if tagOpt.isNone:
    return false
  tagOpt.get().slot <= model.defaultWorkspaceCount() or
    model.tagHasFocusableWindow(tagId)

proc focusWorkspaceSlot(model: var DodModel; slot: uint32): bool =
  let tagId = model.ensureWorkspaceSlot(slot)
  if tagId == NullTagId:
    return false
  model.activeTag = tagId
  model.activeSlot = slot
  model.recordWorkspace(tagId)
  let focused = model.recomputeVisibleFocus(tagId)
  if focused != NullWindowId:
    model.recordFocus(focused)
  if model.primaryOutput != NullOutputId:
    discard model.setOutputTag(model.primaryOutput, tagId)
  true

proc focusMostRecentWorkspace(model: var DodModel): bool =
  var candidates: seq[TagId] = @[]
  for candidate in model.workspaceHistory:
    if model.isRestorableWorkspace(candidate):
      candidates.add(candidate)
  model.workspaceHistory = candidates
  if candidates.len == 0:
    return false

  for i in countdown(candidates.len - 1, 0):
    if candidates[i] != model.activeTag:
      let tagOpt = model.tag(candidates[i])
      if tagOpt.isSome:
        return model.focusWorkspaceSlot(tagOpt.get().slot)
  false

proc computedVisibleWorkspaceSlots(model: DodModel): seq[uint32] =
  let defaultCount = model.defaultWorkspaceCount()
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

proc trailingWorkspaceSlot(model: DodModel): uint32 =
  let slots = model.computedVisibleWorkspaceSlots()
  if slots.len == 0:
    return 0
  let last = slots[^1]
  let tagId = model.tagForSlot(last)
  if last < MaxTagBits and tagId != NullTagId and
      model.tagHasLiveWindows(tagId):
    return last + 1
  0

proc lowerWorkspaceFallback(model: DodModel; fromSlot: uint32): uint32 =
  let slots = model.computedVisibleWorkspaceSlots()
  for i in countdown(slots.len - 1, 0):
    let slot = slots[i]
    if slot < fromSlot and slot != fromSlot:
      return slot
  if model.defaultWorkspaceCount() > 0:
    let below = if fromSlot > 1: fromSlot - 1 else: 1'u32
    return min(model.defaultWorkspaceCount(), max(1'u32, below))
  1'u32

proc collapseEmptyActiveDynamicWorkspace(model: var DodModel): bool =
  let oldTag = model.activeTag
  let oldSlot = model.activeWorkspaceSlot()
  if oldTag == NullTagId or oldSlot == 0 or
      oldSlot <= model.defaultWorkspaceCount() or model.tag(oldTag).isNone:
    return false
  if model.tagHasLiveWindows(oldTag):
    return false

  let fallback = model.lowerWorkspaceFallback(oldSlot)
  if fallback == 0 or fallback == oldSlot:
    return false
  model.focusWorkspaceSlot(fallback)

proc pruneDynamicWorkspaces(model: var DodModel): bool =
  let defaultCount = model.defaultWorkspaceCount()
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

proc createWindowForExternal*(model: var DodModel;
    externalId: ExternalWindowId; appId, title: string; identifier = ""):
    WindowId =
  if externalId == NullExternalWindowId:
    return NullWindowId

  let ruleMatch = model.windowRuleFor(appId, title)
  let targetSlot =
    if ruleMatch.found and ruleMatch.rule.defaultSlot != 0:
      ruleMatch.rule.defaultSlot
    elif model.activeWorkspaceSlot() != 0:
      model.activeWorkspaceSlot()
    else:
      1'u32
  let forcedLayout =
    if ruleMatch.found: ruleMatch.rule.forcedLayout
    else: 0
  let targetTag = model.ensureWorkspaceSlot(targetSlot, forcedLayout)
  if targetTag == NullTagId:
    return NullWindowId

  var isFloating = false
  var floatingGeom = LegacyRect()
  var shortcutInhibit = false
  if ruleMatch.found:
    isFloating = ruleMatch.rule.openFloating
    if isFloating:
      floatingGeom = model.dodDefaultFloatingGeom()
    shortcutInhibit = ruleMatch.rule.keyboardShortcutsInhibit

  result = model.windowForExternal(externalId)
  if result == NullWindowId:
    result = model.addWindow(externalId)
  else:
    discard model.removeWindowFromAllTags(result)

  discard model.setWindowCreatedState(
    result,
    title = title,
    appId = appId,
    identifier = identifier,
    widthProportion = model.dodDefaultWindowWidth(),
    heightProportion = model.dodDefaultWindowHeight(),
    isFloating = isFloating,
    floatingGeom = floatingGeom,
    keyboardShortcutsInhibit = shortcutInhibit
  )
  discard model.addWindowColumn(targetTag, result)
  discard model.setTagFocus(targetTag, result)
  discard model.pruneDynamicWorkspaces()

proc destroyWindowForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false

  let closedWasFocused =
    model.focusedOnActiveTag() == winId or
    (model.tag(model.activeTag).isSome and
      model.tag(model.activeTag).get().focusedWindow == winId)
  if not model.destroyWindow(winId):
    return false

  if closedWasFocused:
    if not model.focusMostRecentWindow():
      discard model.focusMostRecentWorkspace()
  discard model.collapseEmptyActiveDynamicWorkspace()
  discard model.pruneDynamicWorkspaces()
  true
