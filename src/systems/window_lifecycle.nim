import std/[options, tables]
import floating_policy, focus, placement, popup_tree, scratchpad, workspaces
import ../state/engine
from ../types/runtime_values import LayoutMode

proc restoredWindowId(model: Model; externalId: ExternalWindowId):
    WindowId =
  model.windowForExternal(externalId)

proc resolveRestoreHistories(model: var Model) =
  var focusHistory: seq[WindowId] = @[]
  for externalId in model.restoreFocusHistoryIds():
    let winId = model.restoredWindowId(externalId)
    if winId != NullWindowId:
      focusHistory.add(winId)
  if focusHistory.len > 0:
    discard model.replaceFocusHistory(focusHistory)

  var workspaceHistory: seq[TagId] = @[]
  for slot in model.restoreWorkspaceHistorySlots():
    let tagId = model.tagForSlot(slot)
    if tagId != NullTagId:
      workspaceHistory.add(tagId)
  if workspaceHistory.len > 0:
    discard model.replaceWorkspaceHistory(workspaceHistory)

proc syncRestoreOutputTags(model: var Model) =
  for outputExt, slot in model.restoreOutputTagsWithId():
    let outputId = model.outputForExternal(outputExt)
    let tagId = model.tagForSlot(slot)
    if outputId != NullOutputId and tagId != NullTagId:
      if outputId == model.primaryOutput and model.activeTag != NullTagId:
        discard model.syncPrimaryOutputTag()
      else:
        discard model.setOutputTag(outputId, tagId)

proc materializeRestoredTarget(model: var Model; slot: uint32): TagId =
  if slot == 0:
    return NullTagId

  let existing = model.tagForSlot(slot)
  let restoredTag = model.restoreTag(slot)
  if existing != NullTagId:
    result = existing
  elif restoredTag.isSome:
    let restored = restoredTag.get()
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
      discard model.addColumn(
        result, col.widthProportion, col.isFullWidth)
  else:
    result = model.ensureWorkspaceSlot(slot)

  if result != NullTagId and restoredTag.isSome:
    let restored = restoredTag.get()
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

proc ensureRestoredColumn(model: var Model; tagId: TagId;
    restoredTag: RestoredTagData; colIdx: int): ColumnId =
  while model.columnCountForTag(tagId) <= colIdx:
    let columnCount = model.columnCountForTag(tagId)
    let width =
      if columnCount < restoredTag.columns.len:
        restoredTag.columns[columnCount].widthProportion
      else:
        model.defaultColumnWidth()
    let fullWidth =
      columnCount < restoredTag.columns.len and
        restoredTag.columns[columnCount].isFullWidth
    discard model.addColumn(tagId, width, fullWidth)
  result = model.columnAt(tagId, colIdx)
  if colIdx < restoredTag.columns.len:
    discard model.setColumnWidth(
      result, restoredTag.columns[colIdx].widthProportion)
    discard model.setColumnFullWidth(
      result, restoredTag.columns[colIdx].isFullWidth)

proc placeRestoredWindow(model: var Model; targetSlot: uint32;
    restoredExternalId, externalId: ExternalWindowId; winId: WindowId): bool =
  let tagId = model.materializeRestoredTarget(targetSlot)
  if tagId == NullTagId:
    return false
  if model.placementForWindowOnTag(tagId, winId).isSome:
    return true

  let restoredTagOpt = model.restoreTag(targetSlot)
  if restoredTagOpt.isSome:
    let restoredTag = restoredTagOpt.get()
    var inserted = false
    for colIdx, restoredCol in restoredTag.columns:
      if restoredCol.windows.find(restoredExternalId) != -1:
        let columnId = model.ensureRestoredColumn(
          tagId, restoredTag, colIdx)
        discard model.moveWindowToColumn(
          tagId, winId, columnId, model.windowCountForColumn(columnId))
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

proc applyRestoredWindowState(model: var Model; winId: WindowId;
    restored: RestoredWindowData) =
  discard model.setWindowRestoredState(winId, restored)

proc applyPendingRestore(model: var Model; externalId,
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
    model.restoreFocusedWindowPending() and
    restoredExternalId == model.restoreFocusedWindowId()
  let restoredScratchpad =
    restored.slot == 0 and model.restoredScratchpadContains(restoredExternalId)
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

proc applyLiveRestore*(model: var Model; state: PendingRestoreState) =
  discard model.loadRestoreState(state)
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
    let tagId = model.materializeRestoredTarget(targetSlot)
    if tagId != NullTagId:
      discard model.setActiveWorkspace(tagId)
      if model.primaryOutput != NullOutputId:
        discard model.syncPrimaryOutputTag()
  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  discard model.syncPrimaryOutputTag()
  discard model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()

proc newWindowColumnIndex(model: Model; tagId: TagId;
    isFloating: bool): int =
  result = high(int)
  if isFloating or tagId == NullTagId or tagId != model.activeTag:
    return

  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone or tagOpt.get().layoutMode != LayoutMode.Scroller:
    return

  let focused = tagOpt.get().focusedWindow
  let focusedOpt = model.windowData(focused)
  if focused == NullWindowId or focusedOpt.isNone or
      focusedOpt.get().isFloating:
    return

  let placementOpt = model.placementForWindowOnTag(tagId, focused)
  if placementOpt.isNone:
    return

  let colIdx = model.columnIndexForTag(tagId, placementOpt.get().columnId)
  if colIdx == 0:
    return
  result = int(colIdx)

proc createWindowForExternal*(model: var Model;
    externalId: ExternalWindowId; appId, title: string; identifier = "";
    parentExternalId = NullExternalWindowId; deferAdmission = false):
    WindowId =
  if externalId == NullExternalWindowId:
    return NullWindowId

  var hasRestoredTag = false
  var hasRestoredWindow = false
  var restoredExternalId = externalId
  var restored = RestoredWindowData()
  discard model.clearSettledRestoreFocus()
  let restoreFocusPending = model.restoreFocusedWindowPending()
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
  elif model.restoreWindowCount() > 0:
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
  let ruleForcesSlot = ruleMatch.found and ruleMatch.rule.defaultSlot != 0
  if ruleMatch.found and ruleMatch.rule.defaultSlot != 0 and
      not hasRestoredTag:
    targetSlot =
      ruleMatch.rule.defaultSlot
  let forcedLayout =
    if ruleMatch.found: ruleMatch.rule.forcedLayout
    else: 0
  let parentKnown = parentExternalId != NullExternalWindowId and
    model.windowForExternal(parentExternalId) != NullWindowId
  let parentOpensFloating =
    if ruleMatch.found and ruleMatch.rule.openFloatingSet:
      ruleMatch.rule.openFloating
    else:
      true
  let parentSlot = model.parentWorkspaceSlot(parentExternalId)
  if parentSlot != 0 and not hasRestoredTag and not ruleForcesSlot:
    targetSlot = parentSlot

  var isFloating = false
  var floatingGeom = GeometryRect()
  var shortcutInhibit = false
  if ruleMatch.found:
    if ruleMatch.rule.openFloatingSet:
      isFloating = ruleMatch.rule.openFloating
    if isFloating:
      floatingGeom = model.defaultFloatingGeom()
    shortcutInhibit = ruleMatch.rule.keyboardShortcutsInhibit
  if hasRestoredWindow:
    isFloating = restored.isFloating
    floatingGeom = restored.floatingGeom
  elif parentKnown and parentOpensFloating:
    isFloating = true
  let parentAutoFloating = parentKnown and isFloating and
    not hasRestoredWindow and
    not (ruleMatch.found and ruleMatch.rule.openFloatingSet)
  let pendingAdmission = deferAdmission and not parentKnown and
    not hasRestoredWindow
  var focusAfterAdmission = false

  result = model.windowForExternal(externalId)
  let existingWindow = result != NullWindowId
  if not existingWindow:
    result = model.addWindow(externalId)
  elif hasRestoredTag or hasRestoredWindow:
    discard model.removeWindowFromAllTagsAndRefreshFocus(result)

  discard model.setWindowCreatedState(
    result,
    title = title,
    appId = appId,
    identifier = identifier,
    widthProportion = model.defaultWindowWidth(),
    heightProportion = model.defaultWindowHeight(),
    isFloating = isFloating,
    floatingGeom = floatingGeom,
    parentAutoFloating = parentAutoFloating,
    admissionState =
      if pendingAdmission: WindowAdmissionState.PendingAdmission
      else: WindowAdmissionState.Admitted,
    focusAfterAdmission = false,
    parentExternalId = parentExternalId,
    keyboardShortcutsInhibit = shortcutInhibit,
    preserveRuntimeState = existingWindow and not hasRestoredWindow
  )

  if existingWindow and not hasRestoredTag and not hasRestoredWindow:
    if pendingAdmission and focusAfterAdmission:
      discard model.setWindowAdmission(
        result, WindowAdmissionState.PendingAdmission,
        focusAfterAdmission = true)
    model.resolveRestoreHistories()
    model.syncRestoreOutputTags()
    discard model.clearSettledRestoreFocus()
    discard model.pruneDynamicWorkspaces()
    return

  if isFloating and not hasRestoredWindow:
    discard model.ensureFloatingAt(
      result,
      model.floatingGeomForWindow(result, parentExternalId),
      parentAutoFloating = parentAutoFloating)

  if hasRestoredWindow:
    model.applyRestoredWindowState(result, restored)
    model.recordRestoredScratchpad(restoredExternalId, result)

  let restoresFocusedWindow =
    model.restoreFocusedWindowPending() and
    restoredExternalId == model.restoreFocusedWindowId()
  let restoredScratchpad =
    hasRestoredWindow and restored.slot == 0 and
    model.restoredScratchpadContains(restoredExternalId)

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
      discard model.addPlacedWindowColumn(
        targetTag,
        result,
        model.newWindowColumnIndex(targetTag, isFloating))
      if not model.sessionLocked and not restoreFocusPending:
        if parentKnown:
          let parentOpensFocused =
            if ruleMatch.found and ruleMatch.rule.openFocusedSet:
              ruleMatch.rule.openFocused
            else:
              targetSlot == model.activeWorkspaceSlot()
          if parentOpensFocused:
            discard model.focusWindow(
              result,
              retargetViewport = not model.parentVisibleInProjection(
                parentExternalId))
        elif targetSlot == model.activeWorkspaceSlot():
          if pendingAdmission:
            focusAfterAdmission = true
          else:
            discard model.focusWindow(result)
        else:
          if not pendingAdmission:
            discard model.setTagFocus(targetTag, result)

    if restoresFocusedWindow:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.setTagFocus(targetTag, result)
    elif hasRestoredTag and not restoreFocusPending:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.recomputeVisibleFocus(targetTag)
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
  discard model.clearSettledRestoreFocus()
  discard model.pruneDynamicWorkspaces()
  if pendingAdmission and focusAfterAdmission:
    discard model.setWindowAdmission(
      result, WindowAdmissionState.PendingAdmission,
      focusAfterAdmission = true)

proc settleWindowAdmissionForExternal*(model: var Model;
    externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isNone or
      winOpt.get().admissionState != WindowAdmissionState.PendingAdmission:
    return false
  let focusAfterAdmission = winOpt.get().focusAfterAdmission
  result = model.setWindowAdmission(winId, WindowAdmissionState.Admitted)
  if focusAfterAdmission and not model.sessionLocked:
    let tagId = model.tagForWindow(winId)
    if tagId != NullTagId and tagId == model.activeTag:
      discard model.focusWindow(winId)

proc updateWindowIdentifierAndRestoreForExternal*(model: var Model;
    externalId: ExternalWindowId; identifier: string): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  discard model.setWindowIdentifier(winId, identifier)
  if identifier.len == 0 or model.restoreWindowCount() == 0:
    return true

  let matchedExternalId = model.findRestoredWindowByIdentity("", "", identifier)
  if matchedExternalId != NullExternalWindowId:
    let matchedRestore = model.restoreWindow(matchedExternalId)
    if matchedRestore.isNone:
      return true
    return model.applyPendingRestore(
      externalId, matchedExternalId, matchedRestore.get())
  true

proc destroyWindowForExternal*(
    model: var Model; externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false

  let activeTag = model.activeTag
  let closedRoot = model.popupRoot(winId)
  let closedWasFocused =
    model.focusedOnActiveTag() == winId or
    (model.tag(activeTag).isSome and
      model.tag(activeTag).get().focusedWindow == winId)
  var affectedTags: seq[TagId] = @[]
  for tagId, placementWinId, _ in model.placementsWithId():
    if placementWinId == winId and affectedTags.find(tagId) == -1:
      affectedTags.add(tagId)
  if not model.destroyWindow(winId):
    return false
  model.pruneScratchpads()
  for tagId in affectedTags:
    if not closedWasFocused or tagId != activeTag:
      discard model.recomputeVisibleFocus(tagId)

  if closedWasFocused:
    var recoveredPopupFocus = false
    if closedRoot != NullWindowId and closedRoot != winId:
      let popupFocus = model.lastFocusedInPopupTree(closedRoot, activeTag)
      if popupFocus != NullWindowId:
        recoveredPopupFocus = model.focusWindow(
          popupFocus, restorePopupTree = false)
      elif model.windowData(closedRoot).isSome and
          model.placementForWindowOnTag(activeTag, closedRoot).isSome:
        recoveredPopupFocus = model.focusWindow(
          closedRoot, restorePopupTree = false)

    if recoveredPopupFocus:
      discard
    elif model.tagHasFocusableWindow(activeTag):
      if not model.focusMostRecentWindowOnTag(activeTag):
        let focused = model.recomputeVisibleFocus(activeTag)
        if focused != NullWindowId:
          discard model.focusWindow(focused)
    elif not model.collapseEmptyActiveDynamicWorkspace():
      discard model.focusMostRecentWorkspace()
  discard model.collapseEmptyActiveDynamicWorkspace()
  discard model.pruneDynamicWorkspaces()
  true
