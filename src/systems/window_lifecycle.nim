import std/[options, tables]
import
  focus, outputs, placement, popup_tree, sticky_windows, window_policy, scratchpad,
  window_rules, window_state, workspaces
import ../state/engine
from ../types/runtime_values import LayoutMode, ParentedRole, WindowRuleIdleInhibitMode

proc supportsOpenColumnMaximize(model: Model, tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  tagOpt.isSome and
    tagOpt.get().layoutMode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc applyOpenColumnMaximize(model: var Model, tagId: TagId, columnId: ColumnId): bool =
  if columnId == NullColumnId or not model.supportsOpenColumnMaximize(tagId):
    return false
  result = model.setColumnFullWidth(columnId, true)
  if result and tagId == model.activeTag:
    discard model.requestTagViewportRetarget(tagId)

proc placeSecondaryRuleTarget(
    model: var Model,
    slot: uint32,
    winId: WindowId,
    forcedLayout: int,
    columnWidthProportion, columnScrollerSingleProportion: float32,
    openColumnMaximized, pendingAdmission: bool,
): bool =
  let targetTag = model.ensureWorkspaceSlot(slot, forcedLayout)
  if targetTag == NullTagId or model.placementForWindowOnTag(targetTag, winId).isSome:
    return false
  if forcedLayout != 0:
    discard model.setTagLayout(
      targetTag, safeLayoutMode(forcedLayout, model.tag(targetTag).get().layoutMode)
    )
  let placedColumn = model.addPlacedWindowColumn(
    targetTag,
    winId,
    widthProportion = columnWidthProportion,
    scrollerSingleProportion = columnScrollerSingleProportion,
  )
  if openColumnMaximized:
    discard model.applyOpenColumnMaximize(targetTag, placedColumn)
  if not pendingAdmission and targetTag != model.activeTag:
    discard model.setTagFocus(targetTag, winId)
  true

proc visibleSlotForOutputRule(model: Model, name: string): uint32 =
  let outputId = model.outputForTarget(name)
  if outputId == NullOutputId:
    return 0
  for mappedOutputId, tagId in model.outputTagsWithId():
    if mappedOutputId == outputId:
      let tagOpt = model.tagData(tagId)
      if tagOpt.isSome:
        return tagOpt.get().slot
  0

proc remapWindowRuleOutput(
    model: var Model,
    targetTag: TagId,
    outputName: string,
    parentKnown, hasRestoredTag, hasRestoredWindow: bool,
): bool =
  if outputName.len == 0 or targetTag == NullTagId or targetTag == model.activeTag:
    return false
  if parentKnown or hasRestoredTag or hasRestoredWindow:
    return false

  let outputId = model.outputForTarget(outputName)
  if outputId == NullOutputId or outputId == model.primaryOutput:
    return false

  var duplicateOutputs: seq[OutputId] = @[]
  for mappedOutputId, mappedTagId in model.outputTagsWithId():
    if mappedOutputId != outputId and mappedOutputId != model.primaryOutput and
        mappedTagId == targetTag:
      duplicateOutputs.add(mappedOutputId)
  for mappedOutputId in duplicateOutputs:
    discard model.clearOutputTag(mappedOutputId)

  model.setOutputTag(outputId, targetTag)

proc restoredWindowId(model: Model, externalId: ExternalWindowId): WindowId =
  result = model.restoredWindowRef(externalId)
  if result != NullWindowId:
    return
  if model.restoreWindow(externalId).isSome:
    return NullWindowId
  result = model.windowForExternal(externalId)

proc restoredIdentityConflicts(
    restored: RestoredWindowData, appId, title, identifier: string
): bool =
  if restored.identifier.len > 0 and identifier.len > 0 and
      restored.identifier != identifier:
    return true
  if restored.appId.len > 0 and appId.len > 0 and restored.appId != appId:
    return true
  if restored.title.len > 0 and title.len > 0 and restored.title != title:
    return true
  false

proc directRestoreCompatible(
    restored: RestoredWindowData, appId, title, identifier: string
): bool =
  not restored.restoredIdentityConflicts(appId, title, identifier)

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

proc materializeRestoredTarget(model: var Model, slot: uint32): TagId =
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
      masterSplitRatio = restored.masterSplitRatio,
    )
    for col in restored.columns:
      discard model.addColumn(
        result, col.widthProportion, col.isFullWidth, col.scrollerSingleProportion
      )
  else:
    result = model.ensureWorkspaceSlot(slot)

  if result != NullTagId and restoredTag.isSome:
    let restored = restoredTag.get()
    discard model.setTagRestoredState(
      result, restored.name, restored.layoutMode, restored.customLayoutId,
      restored.nativeLayoutId, restored.targetViewportXOffset,
      restored.currentViewportXOffset, restored.targetViewportYOffset,
      restored.currentViewportYOffset, restored.masterCount, restored.masterSplitRatio,
    )
    discard model.restoreTagFrames(result, restored)
    discard model.restoreTagBspNodes(result, restored)
  if result != NullTagId:
    discard model.syncStickyWindowsForWorkspace(result)

proc ensureRestoredColumn(
    model: var Model, tagId: TagId, restoredTag: RestoredTagData, colIdx: int
): ColumnId =
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
    let scrollerSingle =
      if columnCount < restoredTag.columns.len:
        restoredTag.columns[columnCount].scrollerSingleProportion
      else:
        0.0'f32
    discard model.addColumn(tagId, width, fullWidth, scrollerSingle)
  result = model.columnAt(tagId, colIdx)
  if colIdx < restoredTag.columns.len:
    discard model.setColumnWidth(result, restoredTag.columns[colIdx].widthProportion)
    discard model.setColumnFullWidth(result, restoredTag.columns[colIdx].isFullWidth)
    discard model.setColumnScrollerSingleProportion(
      result, restoredTag.columns[colIdx].scrollerSingleProportion
    )

proc placeRestoredWindow(
    model: var Model,
    targetSlot: uint32,
    restoredExternalId, externalId: ExternalWindowId,
    winId: WindowId,
): bool =
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
        let columnId = model.ensureRestoredColumn(tagId, restoredTag, colIdx)
        discard model.moveWindowToColumn(
          tagId, winId, columnId, model.windowCountForColumn(columnId)
        )
        inserted = true
        break
    if not inserted:
      discard model.addPlacedWindowColumn(tagId, winId)
    discard
      model.restoreWindowFramePlacement(tagId, restoredTag, restoredExternalId, winId)
    discard
      model.restoreWindowBspPlacement(tagId, restoredTag, restoredExternalId, winId)
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

proc applyRestoredWindowState(
    model: var Model, winId: WindowId, restored: RestoredWindowData
) =
  discard model.setWindowRestoredState(winId, restored)

proc syncRestoredSwallowRelations(model: var Model)

proc applyPendingRestore(
    model: var Model,
    externalId, restoredExternalId: ExternalWindowId,
    restored: RestoredWindowData,
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or restoredExternalId == NullExternalWindowId:
    return false

  var targetSlot = restored.slot
  if restoredExternalId == externalId:
    let externalSlot = model.consumeRestoreTagSlot(externalId)
    if externalSlot.found:
      targetSlot = externalSlot.slot
  else:
    let restoredSlot = model.consumeRestoreTagSlot(restoredExternalId)
    if restoredSlot.found:
      targetSlot = restoredSlot.slot

  discard model.consumeRestoreWindow(restoredExternalId)
  model.applyRestoredWindowState(winId, restored)
  discard model.recordRestoreWindowRef(restoredExternalId, winId)
  model.recordRestoredScratchpad(restoredExternalId, winId)

  let restoresFocusedWindow =
    model.restoreFocusedWindowPending() and
    restoredExternalId == model.restoreFocusedWindowId()
  let restoredScratchpad =
    restored.slot == 0 and model.restoredScratchpadContains(restoredExternalId)
  if restored.isUnmanagedGlobal:
    discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
  elif not restoredScratchpad and targetSlot != 0:
    discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
    discard model.placeRestoredWindow(targetSlot, restoredExternalId, externalId, winId)
    if restored.isSticky:
      discard model.syncStickyWindow(winId, model.tagForSlot(targetSlot))
    if restoresFocusedWindow:
      let tagId = model.tagForSlot(targetSlot)
      if tagId != NullTagId:
        discard model.setTagFocus(tagId, winId)
  elif restoredScratchpad:
    discard model.setWindowSticky(winId, false)

  if restoresFocusedWindow and targetSlot == model.activeWorkspaceSlot():
    let tagId = model.tagForSlot(targetSlot)
    if tagId != NullTagId and model.tag(tagId).isSome and
        model.tag(tagId).get().focusedWindow == winId:
      discard model.recordFocus(winId)
      discard model.clearRestoreFocusedWindow(restoredExternalId)

  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  model.syncRestoredSwallowRelations()
  true

proc applyRestoredFallbackScreen(model: var Model, state: PendingRestoreState) =
  if model.outputsCount() > 0 or model.screenWidth > 0 or model.screenHeight > 0:
    return

  var fallbackW = 0'i32
  var fallbackH = 0'i32
  for _, win in state.windows.pairs:
    if win.actualW > fallbackW:
      fallbackW = win.actualW
    if win.actualH > fallbackH:
      fallbackH = win.actualH

  if fallbackW > 0 and fallbackH > 0:
    discard model.setScreenSize(fallbackW, fallbackH)

proc applyLiveRestore*(model: var Model, state: PendingRestoreState) =
  discard model.loadRestoreState(state)
  model.applyRestoredFallbackScreen(state)
  for slot, _ in state.tags.pairs:
    discard model.materializeRestoredTarget(slot)
  var targetSlot = state.activeSlot
  if targetSlot != 0:
    var activeHasRestoredWindow = false
    for _, slot in state.tagByWindow.pairs:
      if slot == targetSlot:
        activeHasRestoredWindow = true
        break
    if not activeHasRestoredWindow and not state.tags.hasKey(targetSlot) and
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
  model.syncRestoredSwallowRelations()
  discard model.syncPrimaryOutputTag()
  model.refreshVisibleWorkspaceSlots()

proc newWindowColumnIndex(model: Model, tagId: TagId, isFloating: bool): int =
  result = high(int)
  if isFloating or tagId == NullTagId or tagId != model.activeTag:
    return

  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone or tagOpt.get().layoutMode != LayoutMode.Scroller:
    return

  let focused = tagOpt.get().focusedWindow
  let focusedOpt = model.windowData(focused)
  if focused == NullWindowId or focusedOpt.isNone or focusedOpt.get().isFloating:
    return

  let placementOpt = model.placementForWindowOnTag(tagId, focused)
  if placementOpt.isNone:
    return

  let colIdx = model.columnIndexForTag(tagId, placementOpt.get().columnId)
  if colIdx == 0:
    return
  result = int(colIdx)

proc windowCanSwallow*(model: Model, host, child: WindowId): bool =
  if host == NullWindowId or child == NullWindowId or host == child:
    return false
  let hostOpt = model.windowData(host)
  let childOpt = model.windowData(child)
  if hostOpt.isNone or childOpt.isNone:
    return false
  let hostWin = hostOpt.get()
  let childWin = childOpt.get()
  if not hostWin.windowAdmitted() or not childWin.windowAdmitted():
    return false
  if not hostWin.isTerminal or hostWin.isFloating or hostWin.isSticky or
      hostWin.isMinimized or model.swallowingWindow(host) != NullWindowId:
    return false
  if childWin.pid <= 0 or hostWin.pid <= 0 or childWin.isTerminal or
      not childWin.allowSwallow or childWin.isFloating or childWin.isSticky or
      childWin.parentExternalId != NullExternalWindowId:
    return false
  model.firstWindowPosition(host).found

proc applySwallow*(model: var Model, host, child: WindowId): bool =
  if not model.windowCanSwallow(host, child):
    return false

  var hostTags: seq[TagId] = @[]
  for tagId, winId, _ in model.placementsWithId():
    if winId == host:
      hostTags.add(tagId)
  if hostTags.len == 0:
    return false

  for tagId in hostTags:
    discard model.replacePlacedWindow(tagId, host, child)
  discard model.setSwallowRelation(host, child)
  if model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, child).isSome:
    discard model.setTagFocus(model.activeTag, child)
    discard model.recordFocus(child)
  true

proc restoreSwallowedHost*(model: var Model, child: WindowId): bool =
  let host = model.swallowedByWindow(child)
  if host == NullWindowId:
    return false
  if model.windowData(host).isNone or model.windowData(child).isNone:
    discard model.clearSwallowRelationForChild(child)
    return false

  var childTags: seq[TagId] = @[]
  for tagId, winId, _ in model.placementsWithId():
    if winId == child:
      childTags.add(tagId)
  for tagId in childTags:
    discard model.replacePlacedWindow(tagId, child, host)

  discard model.clearSwallowRelationForChild(child)
  if model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, host).isSome:
    discard model.setTagFocus(model.activeTag, host)
    discard model.recordFocus(host)
  true

proc syncRestoredSwallowRelations(model: var Model) =
  for hostExternalId, childExternalId in model.restoreSwallowingWithId():
    let host = model.windowForExternal(hostExternalId)
    let child = model.windowForExternal(childExternalId)
    if host == NullWindowId or child == NullWindowId:
      continue
    if model.windowData(host).isNone or model.windowData(child).isNone:
      continue
    if model.swallowedByWindow(child) == host:
      continue
    let currentChild = model.swallowingWindow(host)
    if currentChild != NullWindowId and currentChild != child:
      continue

    var hostTags: seq[TagId] = @[]
    for tagId, winId, _ in model.placementsWithId():
      if winId == host:
        hostTags.add(tagId)
    for tagId in hostTags:
      if model.placementForWindowOnTag(tagId, child).isSome:
        discard model.removeWindowFromTag(tagId, host)
      else:
        discard model.replacePlacedWindow(tagId, host, child)
    if hostTags.len > 0 or model.firstWindowPosition(child).found:
      discard model.setSwallowRelation(host, child)
      if model.activeTag != NullTagId and
          model.placementForWindowOnTag(model.activeTag, child).isSome:
        discard model.setTagFocus(model.activeTag, child)
        discard model.recordFocus(child)

proc createWindowForExternal*(
    model: var Model,
    externalId: ExternalWindowId,
    appId, title: string,
    identifier = "",
    pid = 0'i32,
    parentExternalId = NullExternalWindowId,
    swallowHostExternalId = NullExternalWindowId,
    deferAdmission = false,
): WindowId =
  if externalId == NullExternalWindowId:
    return NullWindowId

  var hasRestoredTag = false
  var hasRestoredWindow = false
  var restoredExternalId = externalId
  var restored = RestoredWindowData()
  discard model.clearSettledRestoreFocus()
  let restoreFocusPending = model.restoreFocusedWindowPending()
  var targetSlot =
    if model.activeWorkspaceSlot() == 0:
      1'u32
    else:
      model.activeWorkspaceSlot()

  if model.restoreWindowCount() > 0:
    let matched = model.findRestoredWindowByIdentity(appId, title, identifier)
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
    else:
      let directRestore = model.restoreWindow(externalId)
      if directRestore.isSome and
          directRestore.get().directRestoreCompatible(appId, title, identifier):
        let consumed = model.consumeRestoreWindow(externalId)
        if consumed.isNone:
          return NullWindowId
        restored = consumed.get()
        hasRestoredWindow = true
        if restored.slot != 0:
          targetSlot = restored.slot
          hasRestoredTag = true

  if hasRestoredWindow and restoredExternalId == externalId:
    let externalSlot = model.consumeRestoreTagSlot(externalId)
    if externalSlot.found:
      targetSlot = externalSlot.slot
      hasRestoredTag = targetSlot != 0
      restoredExternalId = externalId
  elif hasRestoredWindow and restoredExternalId != externalId:
    let restoredSlot = model.consumeRestoreTagSlot(restoredExternalId)
    if restoredSlot.found:
      targetSlot = restoredSlot.slot
      hasRestoredTag = targetSlot != 0

  let ruleMatch = model.windowRuleFor(appId, title)
  let parentedRole =
    if ruleMatch.found: ruleMatch.rule.parentedRole else: ParentedRole.Dialog
  let ruleOpensUnmanagedGlobal =
    ruleMatch.found and not hasRestoredWindow and ruleMatch.rule.openUnmanagedGlobalSet and
    ruleMatch.rule.openUnmanagedGlobal
  let ruleTargetSlots =
    if ruleMatch.found and ruleMatch.rule.defaultSlots.len > 0:
      ruleMatch.rule.defaultSlots
    elif ruleMatch.found and ruleMatch.rule.defaultSlot != 0:
      @[ruleMatch.rule.defaultSlot]
    else:
      @[]
  let ruleForcesSlot = ruleTargetSlots.len > 0
  let opensNamedScratchpad =
    ruleMatch.found and not hasRestoredWindow and not hasRestoredTag and
    not ruleOpensUnmanagedGlobal and ruleMatch.rule.openNamedScratchpad.len > 0
  if ruleForcesSlot and not hasRestoredTag:
    targetSlot = ruleTargetSlots[0]
  elif ruleMatch.found and not hasRestoredTag:
    let outputSlot = model.visibleSlotForOutputRule(ruleMatch.rule.openOnOutput)
    if outputSlot != 0:
      targetSlot = outputSlot
  let forcedLayout = if ruleMatch.found: ruleMatch.rule.forcedLayout else: 0
  let parentKnown =
    parentExternalId != NullExternalWindowId and
    model.windowForExternal(parentExternalId) != NullWindowId
  let parentOpensFloating =
    if ruleMatch.found and ruleMatch.rule.openFloatingSet:
      ruleMatch.rule.openFloating
    else:
      true
  let parentSlot = model.parentWorkspaceSlot(parentExternalId)
  if parentSlot != 0 and not hasRestoredTag and not ruleForcesSlot and
      parentedRole != ParentedRole.Plain:
    targetSlot = parentSlot
  let openSticky =
    ruleMatch.found and ruleMatch.rule.openOnAllWorkspacesSet and
    ruleMatch.rule.openOnAllWorkspaces and not opensNamedScratchpad and
    not ruleOpensUnmanagedGlobal and
    (not parentKnown or parentedRole == ParentedRole.Plain)

  var isFullscreen = false
  var isMaximized = false
  var fullscreenOutput = NullExternalOutputId
  var openColumnMaximized = false
  if ruleMatch.found and not hasRestoredWindow:
    if ruleMatch.rule.openFullscreenSet:
      isFullscreen = ruleMatch.rule.openFullscreen
    if ruleMatch.rule.openMaximizedToEdgesSet:
      isMaximized = ruleMatch.rule.openMaximizedToEdges
    if ruleMatch.rule.openMaximizedSet:
      openColumnMaximized = ruleMatch.rule.openMaximized
  if isFullscreen:
    isMaximized = false
    openColumnMaximized = false
    fullscreenOutput = model.chooseFullscreenOutput(NullExternalOutputId)
  elif isMaximized:
    openColumnMaximized = false

  var isFloating = false
  var isSticky = false
  var isOverlay = false
  var isUnmanagedGlobal = false
  var floatingGeom = GeometryRect()
  var shortcutInhibit = false
  var idleInhibitMode = WindowRuleIdleInhibitMode.IdleInhibitNone
  var isTerminal = false
  var allowSwallow = true
  var widthProportion = model.defaultWindowWidth()
  var heightProportion = model.defaultWindowHeight()
  var columnWidthProportion = 0.0'f32
  var columnScrollerSingleProportion = 0.0'f32
  if ruleMatch.found:
    if ruleMatch.rule.openFloatingSet:
      isFloating = ruleMatch.rule.openFloating
    if isFloating:
      floatingGeom = model.defaultFloatingGeom()
    shortcutInhibit = ruleMatch.rule.keyboardShortcutsInhibit
    idleInhibitMode = ruleMatch.rule.idleInhibitMode
    isTerminal = ruleMatch.rule.terminal
    allowSwallow = ruleMatch.rule.allowSwallow
    if ruleMatch.rule.openOverlaySet:
      isOverlay = ruleMatch.rule.openOverlay
    if ruleMatch.rule.openUnmanagedGlobalSet:
      isUnmanagedGlobal = ruleMatch.rule.openUnmanagedGlobal
    if not hasRestoredWindow:
      if ruleMatch.rule.defaultWindowWidthSet:
        widthProportion = ruleMatch.rule.defaultWindowWidth
      if ruleMatch.rule.defaultWindowHeightSet:
        heightProportion = ruleMatch.rule.defaultWindowHeight
      if ruleMatch.rule.defaultColumnWidthSet:
        columnWidthProportion = ruleMatch.rule.defaultColumnWidth
      if ruleMatch.rule.scrollerProportionSet:
        columnWidthProportion = ruleMatch.rule.scrollerProportion
      if ruleMatch.rule.scrollerSingleProportionSet:
        columnScrollerSingleProportion = ruleMatch.rule.scrollerSingleProportion
  if hasRestoredWindow:
    isFloating = restored.isFloating
    isSticky = restored.isSticky
    isUnmanagedGlobal = restored.isUnmanagedGlobal
    floatingGeom = restored.floatingGeom
  elif openSticky:
    isSticky = true
  elif ruleOpensUnmanagedGlobal:
    isFloating = true
    isSticky = false
    isOverlay = false
    floatingGeom = model.defaultFloatingGeom()
  elif parentKnown and parentOpensFloating:
    isFloating = true
  if isFullscreen or isMaximized or openColumnMaximized:
    isFloating = false
    floatingGeom = GeometryRect()
  if isUnmanagedGlobal:
    isFloating = true
    isFullscreen = false
    isMaximized = false
    isSticky = false
    isOverlay = false
    openColumnMaximized = false
    if floatingGeom.w == 0 or floatingGeom.h == 0:
      floatingGeom = model.defaultFloatingGeom()
  let parentAutoFloating =
    parentKnown and isFloating and parentedRole == ParentedRole.Dialog and
    not hasRestoredWindow and not (ruleMatch.found and ruleMatch.rule.openFloatingSet)
  let pendingAdmission = deferAdmission and not parentKnown and not hasRestoredWindow
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
    pid = pid,
    widthProportion = widthProportion,
    heightProportion = heightProportion,
    isFloating = isFloating,
    isFullscreen = isFullscreen,
    isMaximized = isMaximized,
    isSticky = isSticky,
    isOverlay = isOverlay,
    isUnmanagedGlobal = isUnmanagedGlobal,
    fullscreenOutput = fullscreenOutput,
    floatingGeom = floatingGeom,
    parentAutoFloating = parentAutoFloating,
    admissionState =
      if pendingAdmission:
        WindowAdmissionState.PendingAdmission
      else:
        WindowAdmissionState.Admitted,
    focusAfterAdmission = false,
    parentExternalId = parentExternalId,
    keyboardShortcutsInhibit = shortcutInhibit,
    idleInhibitMode = idleInhibitMode,
    isTerminal = isTerminal,
    allowSwallow = allowSwallow,
    preserveRuntimeState = existingWindow and not hasRestoredWindow,
  )
  discard model.applyWindowRuleBounds(result)
  if not existingWindow:
    discard model.recordRecentWindowOpen(result)

  let swallowHost = model.windowForExternal(swallowHostExternalId)
  let canSwallow =
    not existingWindow and not hasRestoredWindow and not hasRestoredTag and
    not opensNamedScratchpad and parentExternalId == NullExternalWindowId and
    swallowHost != NullWindowId and model.windowCanSwallow(swallowHost, result)
  if canSwallow:
    discard model.applySwallow(swallowHost, result)
    model.resolveRestoreHistories()
    model.syncRestoreOutputTags()
    model.syncRestoredSwallowRelations()
    discard model.clearSettledRestoreFocus()
    discard model.pruneDynamicWorkspaces()
    return

  if existingWindow and not hasRestoredTag and not hasRestoredWindow:
    if pendingAdmission and focusAfterAdmission:
      discard model.setWindowAdmission(
        result, WindowAdmissionState.PendingAdmission, focusAfterAdmission = true
      )
    model.resolveRestoreHistories()
    model.syncRestoreOutputTags()
    model.syncRestoredSwallowRelations()
    discard model.clearSettledRestoreFocus()
    discard model.pruneDynamicWorkspaces()
    return

  if isFloating and not hasRestoredWindow:
    discard model.ensureFloatingAt(
      result,
      model.floatingGeomForWindow(result, parentExternalId),
      parentAutoFloating = parentAutoFloating,
    )

  if hasRestoredWindow:
    model.applyRestoredWindowState(result, restored)
    model.recordRestoredScratchpad(restoredExternalId, result)

  let restoresFocusedWindow =
    model.restoreFocusedWindowPending() and
    restoredExternalId == model.restoreFocusedWindowId()
  let restoredScratchpad =
    hasRestoredWindow and restored.slot == 0 and
    model.restoredScratchpadContains(restoredExternalId)

  if isUnmanagedGlobal:
    discard model.removeWindowFromAllTagsAndRefreshFocus(result)
  elif opensNamedScratchpad:
    discard model.addScratchpadRef(result)
    discard model.setNamedScratchpadRef(ruleMatch.rule.openNamedScratchpad, result)
    discard model.hideScratchpadRef()
  elif not restoredScratchpad:
    if hasRestoredTag:
      discard
        model.placeRestoredWindow(targetSlot, restoredExternalId, externalId, result)
      if isSticky:
        discard model.syncStickyWindow(result, model.tagForSlot(targetSlot))
    else:
      let targetTag = model.ensureWorkspaceSlot(targetSlot, forcedLayout)
      if targetTag == NullTagId:
        return NullWindowId
      if ruleForcesSlot and ruleMatch.rule.openOnOutput.len > 0:
        discard model.remapWindowRuleOutput(
          targetTag, ruleMatch.rule.openOnOutput, parentKnown, hasRestoredTag,
          hasRestoredWindow,
        )
      else:
        discard model.learnTagOutputFromActive(targetTag)
      if forcedLayout != 0:
        discard model.setTagLayout(
          targetTag, safeLayoutMode(forcedLayout, model.tag(targetTag).get().layoutMode)
        )
      var placedColumn = NullColumnId
      let leadAnchor = model.leadFloatingAnchorFor(
        targetTag, result, appId, isFloating, parentExternalId, pendingAdmission
      )
      if leadAnchor.found:
        placedColumn = leadAnchor.columnId
        discard model.moveWindowToColumn(
          targetTag,
          result,
          leadAnchor.columnId,
          model.windowCountForColumn(leadAnchor.columnId),
        )
        discard model.recenterLeadFloatingAnchor(leadAnchor, result)
      else:
        placedColumn = model.addPlacedWindowColumn(
          targetTag,
          result,
          model.newWindowColumnIndex(targetTag, isFloating),
          columnWidthProportion,
          scrollerSingleProportion = columnScrollerSingleProportion,
        )
      if openColumnMaximized:
        discard model.applyOpenColumnMaximize(targetTag, placedColumn)
      if not model.sessionLocked and not restoreFocusPending:
        if parentKnown:
          let parentOpensFocused =
            if ruleMatch.found and ruleMatch.rule.openFocusedSet:
              ruleMatch.rule.openFocused
            else:
              targetSlot == model.activeWorkspaceSlot()
          if parentOpensFocused:
            discard model.applyParentFocusPolicy(result, parentExternalId)
        elif targetSlot == model.activeWorkspaceSlot():
          if leadAnchor.found:
            discard model.recordFocus(result)
            discard model.focusWindow(leadAnchor.winId, retargetViewport = false)
          elif pendingAdmission:
            focusAfterAdmission = true
          else:
            discard model.focusWindow(result)
        else:
          if not pendingAdmission:
            discard model.setTagFocus(targetTag, result)
      if ruleTargetSlots.len > 1:
        for i in 1 ..< ruleTargetSlots.len:
          discard model.placeSecondaryRuleTarget(
            ruleTargetSlots[i],
            result,
            forcedLayout,
            columnWidthProportion,
            columnScrollerSingleProportion,
            openColumnMaximized,
            pendingAdmission,
          )
      if isSticky:
        discard model.syncStickyWindow(result, targetTag)

    if restoresFocusedWindow:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.setTagFocus(targetTag, result)
    elif hasRestoredTag and not restoreFocusPending:
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId:
        discard model.recomputeVisibleFocus(targetTag)
  elif restoredScratchpad:
    discard model.setWindowSticky(result, false)
  if hasRestoredWindow:
    discard model.recordRestoreWindowRef(restoredExternalId, result)
    if restoresFocusedWindow and targetSlot == model.activeWorkspaceSlot():
      let targetTag = model.tagForSlot(targetSlot)
      if targetTag != NullTagId and model.tag(targetTag).isSome and
          model.tag(targetTag).get().focusedWindow == result:
        discard model.recordFocus(result)
        discard model.clearRestoreFocusedWindow(restoredExternalId)

  model.resolveRestoreHistories()
  model.syncRestoreOutputTags()
  model.syncRestoredSwallowRelations()
  discard model.clearSettledRestoreFocus()
  discard model.pruneDynamicWorkspaces()
  if pendingAdmission and focusAfterAdmission:
    discard model.setWindowAdmission(
      result, WindowAdmissionState.PendingAdmission, focusAfterAdmission = true
    )

proc settleWindowAdmissionForExternal*(
    model: var Model, externalId: ExternalWindowId
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isNone or
      winOpt.get().admissionState != WindowAdmissionState.PendingAdmission:
    return false
  let focusAfterAdmission = winOpt.get().focusAfterAdmission
  result = model.setWindowAdmission(winId, WindowAdmissionState.Admitted)
  var affectedTags: seq[TagId] = @[]
  for tagId, placementWinId, _ in model.placementsWithId():
    if placementWinId == winId and affectedTags.find(tagId) == -1:
      affectedTags.add(tagId)
  for tagId in affectedTags:
    result = model.syncTagNativeSubstrateFromPlacement(tagId) or result
  if focusAfterAdmission and not model.sessionLocked:
    let tagId = model.tagForWindow(winId)
    if tagId != NullTagId and tagId == model.activeTag:
      discard model.focusWindow(winId)

proc updateWindowIdentifierAndRestoreForExternal*(
    model: var Model, externalId: ExternalWindowId, identifier: string
): bool =
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
    return
      model.applyPendingRestore(externalId, matchedExternalId, matchedRestore.get())
  true

proc updateWindowPidForExternal*(
    model: var Model, externalId: ExternalWindowId, pid: int32
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowPid(winId, pid)

proc destroyWindowForExternal*(model: var Model, externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false

  if model.swallowedByWindow(winId) != NullWindowId:
    discard model.restoreSwallowedHost(winId)
  elif model.swallowingWindow(winId) != NullWindowId:
    discard model.clearSwallowRelationForHost(winId)

  let activeTag = model.activeTag
  let closedRoot = model.popupRoot(winId)
  let closedWasFocused =
    model.focusedOnActiveTag() == winId or
    (model.tag(activeTag).isSome and model.tag(activeTag).get().focusedWindow == winId)
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
        recoveredPopupFocus = model.focusWindow(popupFocus, restorePopupTree = false)
      elif model.windowData(closedRoot).isSome and
          model.placementForWindowOnTag(activeTag, closedRoot).isSome:
        recoveredPopupFocus = model.focusWindow(closedRoot, restorePopupTree = false)

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
