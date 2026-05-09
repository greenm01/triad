import algorithm, options, sequtils, strutils, tables
import dod_scratchpad
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

proc restoredWindowId(model: DodModel; externalId: ExternalWindowId):
    WindowId =
  model.windowForExternal(externalId)

proc resolveRestoreHistories(model: var DodModel) =
  if model.restoreFocusHistory.len > 0:
    model.focusHistory.setLen(0)
    for externalId in model.restoreFocusHistory:
      let winId = model.restoredWindowId(externalId)
      if winId != NullWindowId:
        model.focusHistory.add(winId)

  if model.restoreWorkspaceHistory.len > 0:
    model.workspaceHistory.setLen(0)
    for slot in model.restoreWorkspaceHistory:
      let tagId = model.tagForSlot(slot)
      if tagId != NullTagId:
        model.workspaceHistory.add(tagId)

proc syncRestoreOutputTags(model: var DodModel) =
  for outputExt, slot in model.restoreOutputTags.pairs:
    let outputId = model.outputForExternal(outputExt)
    let tagId = model.tagForSlot(slot)
    if outputId != NullOutputId and tagId != NullTagId:
      discard model.setOutputTag(outputId, tagId)

proc isRestoredScratchpad(
    model: DodModel; externalId: ExternalWindowId): bool =
  if model.restoreScratchpadWindows.find(externalId) != -1:
    return true
  for scratchpadWin in model.restoreNamedScratchpads.values:
    if scratchpadWin == externalId:
      return true
  false

proc findRestoredWindowByIdentity(model: DodModel; appId, title,
    identifier: string): ExternalWindowId =
  if identifier.len > 0:
    for externalId, restored in model.restoreWindows.pairs:
      if restored.identifier.len > 0 and restored.identifier == identifier:
        return externalId

  var matched = NullExternalWindowId
  var matches = 0
  for externalId, restored in model.restoreWindows.pairs:
    if restored.identifier.len == 0 and restored.appId.len > 0 and
        restored.title.len > 0 and restored.appId == appId and
        restored.title == title:
      matched = externalId
      inc matches
  if matches == 1:
    return matched
  NullExternalWindowId

proc materializeRestoredTarget(model: var DodModel; slot: uint32): TagId =
  if slot == 0:
    return NullTagId

  let existing = model.tagForSlot(slot)
  if existing != NullTagId:
    result = existing
  elif model.restoreTags.hasKey(slot):
    let restored = model.restoreTags[slot]
    let focused = model.restoredWindowId(restored.focusedWindow)
    result = model.addTag(
      slot = slot,
      name = restored.name,
      layoutMode = restored.layoutMode,
      focusedWindow = focused,
      targetViewportXOffset = restored.targetViewportXOffset,
      currentViewportXOffset = restored.currentViewportXOffset,
      targetViewportYOffset = restored.targetViewportYOffset,
      currentViewportYOffset = restored.currentViewportYOffset,
      masterCount = restored.masterCount,
      masterSplitRatio = restored.masterSplitRatio
    )
    for col in restored.columns:
      discard model.addColumn(result, col.widthProportion)
  else:
    result = model.ensureWorkspaceSlot(slot)

  if result != NullTagId and model.restoreTags.hasKey(slot):
    let restored = model.restoreTags[slot]
    discard model.setTagRestoredState(
      result,
      restored.name,
      restored.layoutMode,
      restored.targetViewportXOffset,
      restored.currentViewportXOffset,
      restored.targetViewportYOffset,
      restored.currentViewportYOffset,
      restored.masterCount,
      restored.masterSplitRatio
    )

proc ensureRestoredColumn(model: var DodModel; tagId: TagId;
    restoredTag: RestoredTagData; colIdx: int): ColumnId =
  var columns = model.columnsForTag(tagId)
  while columns.len <= colIdx:
    let width =
      if columns.len < restoredTag.columns.len:
        restoredTag.columns[columns.len].widthProportion
      else:
        model.defaultColumnWidth()
    discard model.addColumn(tagId, width)
    columns = model.columnsForTag(tagId)
  result = columns[colIdx]
  if colIdx < restoredTag.columns.len:
    discard model.setColumnWidth(
      result, restoredTag.columns[colIdx].widthProportion)

proc placeRestoredWindow(model: var DodModel; targetSlot: uint32;
    restoredExternalId, externalId: ExternalWindowId; winId: WindowId): bool =
  let tagId = model.materializeRestoredTarget(targetSlot)
  if tagId == NullTagId:
    return false
  if model.placementForWindowOnTag(tagId, winId).isSome:
    return true

  if model.restoreTags.hasKey(targetSlot):
    let restoredTag = model.restoreTags[targetSlot]
    var inserted = false
    for colIdx, restoredCol in restoredTag.columns:
      if restoredCol.windows.find(restoredExternalId) != -1:
        let columnId = model.ensureRestoredColumn(
          tagId, restoredTag, colIdx)
        discard model.moveWindowToColumn(
          tagId, winId, columnId, model.windowsForColumn(columnId).len)
        inserted = true
        break
    if not inserted:
      discard model.addWindowColumn(tagId, winId)
    if restoredTag.focusedWindow == restoredExternalId:
      discard model.setTagFocus(tagId, winId)
    else:
      let tagOpt = model.tag(tagId)
      if tagOpt.isSome and tagOpt.get().focusedWindow == NullWindowId and
          restoredTag.focusedWindow == NullExternalWindowId:
        discard model.setTagFocus(tagId, winId)
  else:
    discard model.addWindowColumn(tagId, winId)
  true

proc rewriteRestoredWindowReferences(model: var DodModel;
    restoredExternalId, externalId: ExternalWindowId) =
  if restoredExternalId == externalId:
    return
  for item in model.restoreFocusHistory.mitems:
    if item == restoredExternalId:
      item = externalId

proc applyRestoredWindowState(model: var DodModel; winId: WindowId;
    restored: RestoredWindowData) =
  discard model.setWindowRestoredState(winId, restored)

proc applyPendingRestore(model: var DodModel; externalId,
    restoredExternalId: ExternalWindowId; restored: RestoredWindowData): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or restoredExternalId == NullExternalWindowId:
    return false

  var targetSlot = restored.slot
  if model.restoreTagByWindow.hasKey(externalId):
    targetSlot = model.restoreTagByWindow[externalId]
    model.restoreTagByWindow.del(externalId)
  if model.restoreTagByWindow.hasKey(restoredExternalId):
    targetSlot = model.restoreTagByWindow[restoredExternalId]
    model.restoreTagByWindow.del(restoredExternalId)

  model.restoreWindows.del(restoredExternalId)
  model.applyRestoredWindowState(winId, restored)
  model.rewriteRestoredWindowReferences(restoredExternalId, externalId)
  model.recordRestoredScratchpad(restoredExternalId, winId)

  let restoresFocusedWindow =
    model.restoreFocusedWindow != NullExternalWindowId and
    restoredExternalId == model.restoreFocusedWindow
  let restoredScratchpad =
    restored.slot == 0 and model.isRestoredScratchpad(restoredExternalId)
  if not restoredScratchpad and targetSlot != 0:
    discard model.removeWindowFromAllTags(winId)
    discard model.placeRestoredWindow(
      targetSlot, restoredExternalId, externalId, winId)
    if restoresFocusedWindow:
      let tagId = model.tagForSlot(targetSlot)
      if tagId != NullTagId:
        discard model.setTagFocus(tagId, winId)

  if restoresFocusedWindow and targetSlot == model.activeWorkspaceSlot():
    let tagId = model.tagForSlot(targetSlot)
    if tagId != NullTagId and model.tag(tagId).isSome and
        model.tag(tagId).get().focusedWindow == winId:
      model.recordFocus(winId)
      model.restoreFocusedWindow = NullExternalWindowId

  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  true

proc applyLiveRestore*(model: var DodModel; state: DodLiveRestoreState) =
  model.restoreActiveSlot = state.activeSlot
  model.restoreFocusedWindow = state.focusedWindow
  model.restoreTagByWindow = state.tagByWindow
  model.restoreWindows = state.windows
  model.restoreTags = state.tags
  model.restoreOutputTags = state.outputTags
  model.restoreScratchpadWindows = state.scratchpadWindows
  model.restoreNamedScratchpads = state.namedScratchpads
  model.restoreVisibleScratchpad = state.visibleScratchpad
  model.restoreIsScratchpadVisible = state.isScratchpadVisible
  model.restoreFocusHistory = state.focusHistory
  model.restoreWorkspaceHistory = state.workspaceHistory

  var targetSlot = state.activeSlot
  if targetSlot != 0:
    var activeHasRestoredWindow = false
    for _, slot in state.tagByWindow.pairs:
      if slot == targetSlot:
        activeHasRestoredWindow = true
        break
    if not activeHasRestoredWindow and
        targetSlot > model.defaultWorkspaceCount():
      let fallback = model.lowerWorkspaceFallback(targetSlot)
      if fallback != 0 and fallback != targetSlot:
        targetSlot = fallback
    let tagId = model.ensureWorkspaceSlot(targetSlot)
    if tagId != NullTagId:
      model.activeTag = tagId
      model.activeSlot = targetSlot
      if model.primaryOutput != NullOutputId:
        discard model.setOutputTag(model.primaryOutput, tagId)
  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  discard model.pruneDynamicWorkspaces()

proc createWindowForExternal*(model: var DodModel;
    externalId: ExternalWindowId; appId, title: string; identifier = ""):
    WindowId =
  if externalId == NullExternalWindowId:
    return NullWindowId

  var hasRestoredTag = false
  var hasRestoredWindow = false
  var restoredExternalId = externalId
  var restored = RestoredWindowData()
  let restoreFocusPending =
    model.restoreFocusedWindow != NullExternalWindowId
  var targetSlot =
    if model.activeWorkspaceSlot() == 0: 1'u32
    else: model.activeWorkspaceSlot()

  if model.restoreWindows.hasKey(externalId):
    restored = model.restoreWindows[externalId]
    model.restoreWindows.del(externalId)
    hasRestoredWindow = true
    if restored.slot != 0:
      targetSlot = restored.slot
      hasRestoredTag = true
  elif model.restoreWindows.len > 0:
    let matched = model.findRestoredWindowByIdentity(
      appId, title, identifier)
    if matched != NullExternalWindowId:
      restored = model.restoreWindows[matched]
      model.restoreWindows.del(matched)
      restoredExternalId = matched
      hasRestoredWindow = true
      if restored.slot != 0:
        targetSlot = restored.slot
        hasRestoredTag = true

  if model.restoreTagByWindow.hasKey(externalId):
    targetSlot = model.restoreTagByWindow[externalId]
    model.restoreTagByWindow.del(externalId)
    hasRestoredTag = targetSlot != 0
    restoredExternalId = externalId
  elif restoredExternalId != externalId and
      model.restoreTagByWindow.hasKey(restoredExternalId):
    targetSlot = model.restoreTagByWindow[restoredExternalId]
    model.restoreTagByWindow.del(restoredExternalId)
    hasRestoredTag = targetSlot != 0

  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found and ruleMatch.rule.defaultSlot != 0 and
      not hasRestoredTag:
    targetSlot =
      ruleMatch.rule.defaultSlot
  let forcedLayout =
    if ruleMatch.found: ruleMatch.rule.forcedLayout
    else: 0

  var isFloating = false
  var floatingGeom = LegacyRect()
  var shortcutInhibit = false
  if ruleMatch.found:
    isFloating = ruleMatch.rule.openFloating
    if isFloating:
      floatingGeom = model.dodDefaultFloatingGeom()
    shortcutInhibit = ruleMatch.rule.keyboardShortcutsInhibit
  if hasRestoredWindow:
    isFloating = restored.isFloating
    floatingGeom = restored.floatingGeom

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

  if hasRestoredWindow:
    model.applyRestoredWindowState(result, restored)
    model.recordRestoredScratchpad(restoredExternalId, result)

  let restoresFocusedWindow =
    model.restoreFocusedWindow != NullExternalWindowId and
    restoredExternalId == model.restoreFocusedWindow
  let restoredScratchpad =
    hasRestoredWindow and restored.slot == 0 and
    model.isRestoredScratchpad(restoredExternalId)

  if not restoredScratchpad:
    if hasRestoredTag:
      discard model.placeRestoredWindow(
        targetSlot, restoredExternalId, externalId, result)
    else:
      let targetTag = model.ensureWorkspaceSlot(targetSlot, forcedLayout)
      if targetTag == NullTagId:
        return NullWindowId
      if forcedLayout != 0:
        discard model.setTagLayout(
          targetTag, safeLayoutMode(
            forcedLayout, model.tag(targetTag).get().layoutMode))
      discard model.addWindowColumn(targetTag, result)
      if not model.sessionLocked and not restoreFocusPending:
        discard model.setTagFocus(targetTag, result)

    if restoresFocusedWindow:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.setTagFocus(targetTag, result)
    elif hasRestoredTag and not restoreFocusPending:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.recomputeVisibleFocus(targetTag)
    if not model.sessionLocked and not hasRestoredTag and
        not restoreFocusPending:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.setTagFocus(targetTag, result)

  if hasRestoredWindow:
    model.rewriteRestoredWindowReferences(restoredExternalId, externalId)
    if restoresFocusedWindow and targetSlot == model.activeWorkspaceSlot():
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId and model.tag(targetTag).isSome and
          model.tag(targetTag).get().focusedWindow == result:
        model.recordFocus(result)
        model.restoreFocusedWindow = NullExternalWindowId

  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  discard model.pruneDynamicWorkspaces()

proc updateWindowIdentifierAndRestoreForExternal*(model: var DodModel;
    externalId: ExternalWindowId; identifier: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowIdentifier(winId, identifier)
  if identifier.len == 0 or model.restoreWindows.len == 0:
    return true

  var matchedExternalId = NullExternalWindowId
  var matchedRestore = RestoredWindowData()
  for restoredExternalId, restored in model.restoreWindows.pairs:
    if restored.identifier.len > 0 and restored.identifier == identifier:
      matchedExternalId = restoredExternalId
      matchedRestore = restored
      break
  if matchedExternalId != NullExternalWindowId:
    return model.applyPendingRestore(externalId, matchedExternalId, matchedRestore)
  true

proc destroyWindowForExternal*(
    model: var DodModel; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false

  let closedWasFocused =
    model.focusedOnActiveTag() == winId or
    (model.tag(model.activeTag).isSome and
      model.tag(model.activeTag).get().focusedWindow == winId)
  var affectedTags: seq[TagId] = @[]
  for tagId, placementWinId, _ in model.placementsWithId():
    if placementWinId == winId and affectedTags.find(tagId) == -1:
      affectedTags.add(tagId)
  if not model.destroyWindow(winId):
    return false
  model.pruneScratchpads()
  for tagId in affectedTags:
    if not closedWasFocused or tagId != model.activeTag:
      discard model.recomputeVisibleFocus(tagId)

  if closedWasFocused:
    if not model.focusMostRecentWindow():
      discard model.focusMostRecentWorkspace()
  discard model.collapseEmptyActiveDynamicWorkspace()
  discard model.pruneDynamicWorkspaces()
  true
