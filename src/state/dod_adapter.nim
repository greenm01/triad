import algorithm, tables
import ../core/model_utils
import ../core/restore_state
import ../entities/dod_ops
import entity_manager
import dod_queries
import ../types/core
import ../types/dod_model
import ../types/legacy_model as legacy

proc sortedTagSlots(model: legacy.Model): seq[uint32] =
  for slot in model.tags.keys:
    result.add(slot)
  for slot in model.visibleWorkspaceIds():
    result.add(slot)
  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

proc sortedWindowIds(model: legacy.Model): seq[legacy.WindowId] =
  for winId in model.windows.keys:
    result.add(winId)
  result.sort()

proc sortedOutputIds(model: legacy.Model): seq[uint32] =
  for outputId in model.outputs.keys:
    result.add(outputId)
  result.sort()

proc dodRestoredWindow*(source: legacy.RestoredWindowState):
    RestoredWindowData =
  RestoredWindowData(
    slot: source.tagId,
    appId: source.appId,
    title: source.title,
    identifier: source.identifier,
    widthProportion: source.widthProportion,
    heightProportion: source.heightProportion,
    isFloating: source.isFloating,
    isFullscreen: source.isFullscreen,
    isMaximized: source.isMaximized,
    isMinimized: source.isMinimized,
    fullscreenOutput: ExternalOutputId(source.fullscreenOutput),
    floatingGeom: source.floatingGeom,
    actualW: source.actualW,
    actualH: source.actualH
  )

proc dodRestoredTag*(source: legacy.RestoredTagState): RestoredTagData =
  result = RestoredTagData(
    slot: source.tagId,
    name: source.name,
    layoutMode: source.layoutMode,
    focusedWindow: ExternalWindowId(uint32(source.focusedWindow)),
    targetViewportXOffset: source.targetViewportXOffset,
    currentViewportXOffset: source.currentViewportXOffset,
    targetViewportYOffset: source.targetViewportYOffset,
    currentViewportYOffset: source.currentViewportYOffset,
    masterCount: source.masterCount,
    masterSplitRatio: source.masterSplitRatio
  )
  for col in source.columns:
    var restoredCol = RestoredColumnData(widthProportion: col.widthProportion)
    for winId in col.windows:
      restoredCol.windows.add(ExternalWindowId(uint32(winId)))
    result.columns.add(restoredCol)

proc dodFromLiveRestore*(source: LiveRestoreState): DodLiveRestoreState =
  result.activeSlot = source.activeTag
  result.focusedWindow = ExternalWindowId(uint32(source.focusedWindow))
  for winId, slot in source.tagByWindow.pairs:
    result.tagByWindow[ExternalWindowId(uint32(winId))] = slot
  for winId, win in source.windows.pairs:
    result.windows[ExternalWindowId(uint32(winId))] = win.dodRestoredWindow()
  for slot, tag in source.tags.pairs:
    result.tags[slot] = tag.dodRestoredTag()
  for outputId, slot in source.outputTags.pairs:
    result.outputTags[ExternalOutputId(outputId)] = slot
  for winId in source.scratchpadWindows:
    result.scratchpadWindows.add(ExternalWindowId(uint32(winId)))
  for name, winId in source.namedScratchpads.pairs:
    result.namedScratchpads[name] = ExternalWindowId(uint32(winId))
  result.visibleScratchpad = ExternalWindowId(uint32(source.visibleScratchpad))
  result.isScratchpadVisible = source.isScratchpadVisible
  for winId in source.focusHistory:
    result.focusHistory.add(ExternalWindowId(uint32(winId)))
  for slot in source.workspaceHistory:
    result.workspaceHistory.add(slot)

proc setPendingRestore*(model: var DodModel; state: DodLiveRestoreState) =
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

proc ensureDodTag(
    target: var DodModel; source: legacy.Model; slot: uint32): TagId =
  if target.tagBySlot.hasKey(slot):
    return target.tagBySlot[slot]

  let tag =
    if source.tags.hasKey(slot):
      source.tags[slot]
    else:
      source.initTagStateForModel(slot)

  target.addTag(
    slot = slot,
    name = tag.name,
    layoutMode = tag.layoutMode,
    focusedWindow = NullWindowId,
    targetViewportXOffset = tag.targetViewportXOffset,
    currentViewportXOffset = tag.currentViewportXOffset,
    targetViewportYOffset = tag.targetViewportYOffset,
    currentViewportYOffset = tag.currentViewportYOffset,
    masterCount = tag.masterCount,
    masterSplitRatio = tag.masterSplitRatio
  )

proc dodFromLegacy*(source: legacy.Model): DodModel =
  result.defaultWorkspaceCount = source.defaultWorkspaceCount()
  result.visibleSlots = source.visibleWorkspaceIds()
  result.activeSlot = source.activeTag
  result.overviewActive = source.overviewActive
  result.screenWidth = source.screenWidth
  result.screenHeight = source.screenHeight
  result.outerGaps = source.outerGaps
  result.innerGaps = source.innerGaps
  result.smartGaps = source.smartGaps
  result.overviewOuterGap = source.overview.outerGap
  result.overviewInnerGapMultiplier = source.overview.innerGapMultiplier
  result.scrollerFocusCenter = source.scrollerFocusCenter
  result.scrollerPreferCenter = source.scrollerPreferCenter
  result.centerFocusedColumn = source.centerFocusedColumn
  result.defaultColumnWidth = source.defaultColumnWidth()
  result.defaultWindowWidth = source.defaultWindowWidth
  result.defaultWindowHeight = source.defaultWindowHeight
  result.defaultMasterCount = source.defaultMasterCount
  result.defaultMasterRatio = source.defaultMasterRatio
  result.floatingXRatio = source.floating.xRatio
  result.floatingYRatio = source.floating.yRatio
  result.floatingWidthRatio = source.floating.widthRatio
  result.floatingHeightRatio = source.floating.heightRatio
  result.floatingMinWidth = source.floating.minWidth
  result.floatingMinHeight = source.floating.minHeight
  for rule in source.windowRules:
    result.windowRules.add(WindowRuleData(
      appIdMatch: rule.appIdMatch,
      titleMatch: rule.titleMatch,
      defaultSlot: rule.defaultTag,
      openFloating: rule.openFloating,
      keyboardShortcutsInhibit: rule.keyboardShortcutsInhibit,
      forcedLayout: rule.forcedLayout
    ))
  for rule in source.tagRules:
    result.tagRules.add(TagRuleData(
      slot: rule.tagId,
      name: rule.name,
      defaultLayout: rule.defaultLayout
    ))
  result.layoutCycle = source.layoutCycle

  for slot in source.sortedTagSlots():
    discard result.ensureDodTag(source, slot)

  for outputExt in source.sortedOutputIds():
    let output = source.outputs[outputExt]
    discard result.addOutput(
      externalId = ExternalOutputId(outputExt),
      wlName = output.wlName,
      name = output.name,
      x = output.x,
      y = output.y,
      w = output.w,
      h = output.h,
      usableX = output.usableX,
      usableY = output.usableY,
      usableW = output.usableW,
      usableH = output.usableH,
      hasUsable = output.hasUsable
    )

  if source.primaryOutput != 0:
    result.primaryOutput =
      result.outputForExternal(ExternalOutputId(source.primaryOutput))

  for outputExt, slot in source.outputTags.pairs:
    let outputId = result.outputForExternal(ExternalOutputId(outputExt))
    let tagId = result.ensureDodTag(source, slot)
    if outputId != NullOutputId and tagId != NullTagId:
      result.outputTags[outputId] = tagId

  for externalWinId in source.sortedWindowIds():
    let win = source.windows[externalWinId]
    discard result.addWindow(
      externalId = ExternalWindowId(uint32(externalWinId)),
      title = win.title,
      appId = win.appId,
      widthProportion = win.widthProportion,
      heightProportion = win.heightProportion,
      isFloating = win.isFloating,
      isFullscreen = win.isFullscreen,
      isMaximized = win.isMaximized,
      isMinimized = win.isMinimized,
      fullscreenOutput = ExternalOutputId(win.fullscreenOutput),
      parentExternalId = ExternalWindowId(uint32(win.parentId)),
      identifier = win.identifier,
      actualW = win.actualW,
      actualH = win.actualH,
      minWidth = win.minWidth,
      minHeight = win.minHeight,
      maxWidth = win.maxWidth,
      maxHeight = win.maxHeight,
      hasDecorationHint = win.hasDecorationHint,
      decorationHint = win.decorationHint,
      hasPresentationHint = win.hasPresentationHint,
      presentationHint = win.presentationHint,
      floatingGeom = win.floatingGeom,
      keyboardShortcutsInhibit = win.keyboardShortcutsInhibit,
      keyboardShortcutsInhibitBypass = win.keyboardShortcutsInhibitBypass
    )

  for slot in source.sortedTagSlots():
    if not source.tags.hasKey(slot):
      continue
    let tagId = result.ensureDodTag(source, slot)
    let tag = source.tags[slot]
    for col in tag.columns:
      let columnId = result.addColumn(tagId, col.widthProportion)
      for externalWinId in col.windows:
        let winId =
          result.windowForExternal(ExternalWindowId(uint32(externalWinId)))
        if winId != NullWindowId:
          result.placeWindow(tagId, columnId, winId)

  for slot in source.sortedTagSlots():
    if not source.tags.hasKey(slot):
      continue
    let tagId = result.ensureDodTag(source, slot)
    let focused = source.tags[slot].focusedWindow
    let focusedId = result.windowForExternal(ExternalWindowId(uint32(focused)))
    if focusedId != NullWindowId:
      result.tags.mEntity(tagId).focusedWindow = focusedId

  result.activeTag = result.tagForSlot(source.activeTag)

  for externalWinId in source.focusHistory:
    let winId =
      result.windowForExternal(ExternalWindowId(uint32(externalWinId)))
    if winId != NullWindowId:
      result.focusHistory.add(winId)

  for slot in source.workspaceHistory:
    let tagId = result.tagForSlot(slot)
    if tagId != NullTagId:
      result.workspaceHistory.add(tagId)
