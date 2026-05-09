import options, tables
import dod_focus
import dod_placement
import dod_scratchpad
import dod_workspaces
import ../state/engine

proc restoredWindowId(model: DodModel; externalId: ExternalWindowId):
    WindowId =
  model.windowForExternal(externalId)

proc resolveRestoreHistories(model: var DodModel) =
  if model.restoreFocusHistory.len > 0:
    var history: seq[WindowId] = @[]
    for externalId in model.restoreFocusHistory:
      let winId = model.restoredWindowId(externalId)
      if winId != NullWindowId:
        history.add(winId)
    discard model.replaceFocusHistory(history)

  if model.restoreWorkspaceHistory.len > 0:
    var history: seq[TagId] = @[]
    for slot in model.restoreWorkspaceHistory:
      let tagId = model.tagForSlot(slot)
      if tagId != NullTagId:
        history.add(tagId)
    discard model.replaceWorkspaceHistory(history)

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
        model.dodDefaultColumnWidth()
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
      discard model.addPlacedWindowColumn(tagId, winId)
    if restoredTag.focusedWindow == restoredExternalId:
      discard model.setTagFocus(tagId, winId)
    else:
      let tagOpt = model.tag(tagId)
      if tagOpt.isSome and tagOpt.get().focusedWindow == NullWindowId and
          restoredTag.focusedWindow == NullExternalWindowId:
        discard model.setTagFocus(tagId, winId)
  else:
    discard model.addPlacedWindowColumn(tagId, winId)
  true

proc applyRestoredWindowState(model: var DodModel; winId: WindowId;
    restored: RestoredWindowData) =
  discard model.setWindowRestoredState(winId, restored)

proc applyPendingRestore(model: var DodModel; externalId,
    restoredExternalId: ExternalWindowId; restored: RestoredWindowData): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or restoredExternalId == NullExternalWindowId:
    return false

  var targetSlot = restored.slot
  let externalSlot = model.consumeRestoreTagSlot(externalId)
  if externalSlot.found:
    targetSlot = externalSlot.slot
  let restoredSlot = model.consumeRestoreTagSlot(restoredExternalId)
  if restoredSlot.found:
    targetSlot = restoredSlot.slot

  discard model.consumeRestoreWindow(restoredExternalId)
  model.applyRestoredWindowState(winId, restored)
  discard model.rewriteRestoreFocusRefs(restoredExternalId, externalId)
  model.recordRestoredScratchpad(restoredExternalId, winId)

  let restoresFocusedWindow =
    model.restoreFocusedWindow != NullExternalWindowId and
    restoredExternalId == model.restoreFocusedWindow
  let restoredScratchpad =
    restored.slot == 0 and model.isRestoredScratchpad(restoredExternalId)
  if not restoredScratchpad and targetSlot != 0:
    discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
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
      discard model.recordFocus(winId)
      discard model.clearRestoreFocusedWindow(restoredExternalId)

  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  true

proc applyLiveRestore*(model: var DodModel; state: DodLiveRestoreState) =
  discard model.loadRestoreState(state)
  var targetSlot = state.activeSlot
  if targetSlot != 0:
    var activeHasRestoredWindow = false
    for _, slot in state.tagByWindow.pairs:
      if slot == targetSlot:
        activeHasRestoredWindow = true
        break
    if not activeHasRestoredWindow and
        targetSlot > model.dodDefaultWorkspaceCount():
      let fallback = model.lowerWorkspaceFallback(targetSlot)
      if fallback != 0 and fallback != targetSlot:
        targetSlot = fallback
    let tagId = model.ensureWorkspaceSlot(targetSlot)
    if tagId != NullTagId:
      discard model.setActiveWorkspace(tagId)
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

  let directRestore = model.consumeRestoreWindow(externalId)
  if directRestore.isSome:
    restored = directRestore.get()
    hasRestoredWindow = true
    if restored.slot != 0:
      targetSlot = restored.slot
      hasRestoredTag = true
  elif model.restoreWindows.len > 0:
    let matched = model.findRestoredWindowByIdentity(
      appId, title, identifier)
    if matched != NullExternalWindowId:
      let matchedRestore = model.consumeRestoreWindow(matched)
      if matchedRestore.isNone:
        return NullWindowId
      restored = matchedRestore.get()
      restoredExternalId = matched
      hasRestoredWindow = true
      if restored.slot != 0:
        targetSlot = restored.slot
        hasRestoredTag = true

  let externalSlot = model.consumeRestoreTagSlot(externalId)
  if externalSlot.found:
    targetSlot = externalSlot.slot
    hasRestoredTag = targetSlot != 0
    restoredExternalId = externalId
  elif restoredExternalId != externalId:
    let restoredSlot = model.consumeRestoreTagSlot(restoredExternalId)
    if restoredSlot.found:
      targetSlot = restoredSlot.slot
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
    discard model.removeWindowFromAllTagsAndRefreshFocus(result)

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
          targetTag, dodSafeLayoutMode(
            forcedLayout, model.tag(targetTag).get().layoutMode))
      discard model.addPlacedWindowColumn(targetTag, result)
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
    discard model.rewriteRestoreFocusRefs(restoredExternalId, externalId)
    if restoresFocusedWindow and targetSlot == model.activeWorkspaceSlot():
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId and model.tag(targetTag).isSome and
          model.tag(targetTag).get().focusedWindow == result:
        discard model.recordFocus(result)
        discard model.clearRestoreFocusedWindow(restoredExternalId)

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
