import algorithm, options, tables
import ../core/model_utils
import ../core/restore_state
import ../entities/dod_ops
import entity_manager
import dod_iterators
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

proc sortedGroupIds(model: legacy.Model): seq[uint32] =
  for groupId in model.groups.keys:
    result.add(groupId)
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
  result.layerFocusExclusive = source.layerFocusExclusive
  result.sessionLocked = source.sessionLocked
  result.activeModifiers = source.activeModifiers
  result.screenWidth = source.screenWidth
  result.screenHeight = source.screenHeight
  result.outerGaps = source.outerGaps
  result.innerGaps = source.innerGaps
  result.previousOuterGaps = source.previousOuterGaps
  result.previousInnerGaps = source.previousInnerGaps
  result.smartGaps = source.smartGaps
  result.borderWidth = source.borderWidth
  result.focusedBorderColor = source.focusedBorderColor
  result.unfocusedBorderColor = source.unfocusedBorderColor
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
  result.enableAnimations = source.enableAnimations
  result.animationSpeed = source.animationSpeed
  result.floatingXRatio = source.floating.xRatio
  result.floatingYRatio = source.floating.yRatio
  result.floatingWidthRatio = source.floating.widthRatio
  result.floatingHeightRatio = source.floating.heightRatio
  result.floatingMinWidth = source.floating.minWidth
  result.floatingMinHeight = source.floating.minHeight
  result.scratchpadWidthRatio = source.scratchpadWidthRatio
  result.scratchpadHeightRatio = source.scratchpadHeightRatio
  result.startupCommands = source.startupCommands
  result.quickshell = source.quickshell
  result.terminal = source.terminal
  result.screenshot = source.screenshot
  result.cursor = source.cursor
  result.presentationMode = source.presentationMode
  result.protocolSurfaces = source.protocolSurfaces
  result.keyBindings = source.keyBindings
  result.pointerBindings = source.pointerBindings
  result.screenLockCommand = source.screenLock.command
  result.windowMenuCommand = source.windowMenu.command
  result.allowExitSession = source.allowExitSession
  result.nextGroupId = source.nextGroupId
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

  for externalWinId in source.scratchpadWindows:
    let winId =
      result.windowForExternal(ExternalWindowId(uint32(externalWinId)))
    if winId != NullWindowId:
      result.scratchpadWindows.add(winId)

  for name, externalWinId in source.namedScratchpads.pairs:
    let winId =
      result.windowForExternal(ExternalWindowId(uint32(externalWinId)))
    if winId != NullWindowId:
      result.namedScratchpads[name] = winId

  result.visibleScratchpad =
    result.windowForExternal(ExternalWindowId(uint32(source.visibleScratchpad)))
  result.isScratchpadVisible =
    source.isScratchpadVisible and
    (result.visibleScratchpad != NullWindowId or
      result.scratchpadWindows.len > 0)

  result.pointerOp = DodPointerOpData(
    kind: source.pointerOp.kind,
    windowId: result.windowForExternal(
      ExternalWindowId(uint32(source.pointerOp.windowId))),
    initialGeom: source.pointerOp.initialGeom,
    edges: source.pointerOp.edges
  )

  for groupId in source.sortedGroupIds():
    let group = source.groups[groupId]
    var members: seq[core.WindowId]
    for externalWinId in group.windows:
      let winId =
        result.windowForExternal(ExternalWindowId(uint32(externalWinId)))
      if winId != NullWindowId:
        members.add(winId)
    let active =
      result.windowForExternal(ExternalWindowId(uint32(group.activeWindow)))
    discard result.addGroupWithId(core.GroupId(groupId), members, active)

  result.nextGroupId = max(result.nextGroupId, source.nextGroupId)
  result.counters.nextGroupId =
    max(result.counters.nextGroupId, result.nextGroupId)

proc legacyWindowId(model: DodModel; winId: core.WindowId): legacy.WindowId =
  if winId == core.NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacy.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc legacyOutputId(model: DodModel; outputId: core.OutputId): uint32 =
  if outputId == core.NullOutputId:
    return 0'u32
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    return uint32(outputOpt.get().externalId)
  0'u32

proc legacyRestoredWindow(source: RestoredWindowData):
    legacy.RestoredWindowState =
  legacy.RestoredWindowState(
    tagId: source.slot,
    appId: source.appId,
    title: source.title,
    identifier: source.identifier,
    widthProportion: source.widthProportion,
    heightProportion: source.heightProportion,
    isFloating: source.isFloating,
    isFullscreen: source.isFullscreen,
    isMaximized: source.isMaximized,
    isMinimized: source.isMinimized,
    fullscreenOutput: uint32(source.fullscreenOutput),
    floatingGeom: source.floatingGeom,
    actualW: source.actualW,
    actualH: source.actualH
  )

proc legacyRestoredTag(source: RestoredTagData):
    legacy.RestoredTagState =
  result = legacy.RestoredTagState(
    tagId: source.slot,
    name: source.name,
    layoutMode: source.layoutMode,
    focusedWindow: legacy.WindowId(uint32(source.focusedWindow)),
    targetViewportXOffset: source.targetViewportXOffset,
    currentViewportXOffset: source.currentViewportXOffset,
    targetViewportYOffset: source.targetViewportYOffset,
    currentViewportYOffset: source.currentViewportYOffset,
    masterCount: source.masterCount,
    masterSplitRatio: source.masterSplitRatio
  )
  for column in source.columns:
    var legacyColumn = legacy.RestoredColumnState(
      widthProportion: column.widthProportion)
    for externalWinId in column.windows:
      legacyColumn.windows.add(legacy.WindowId(uint32(externalWinId)))
    result.columns.add(legacyColumn)

proc legacyViewFromDod*(source: DodModel;
    fallback: legacy.Model): legacy.Model =
  result = legacy.Model(
    workspaces: legacy.WorkspaceConfig(
      defaultCount: source.defaultWorkspaceCount),
    tagRules: @[],
    windowRules: @[],
    startupCommands: source.startupCommands,
    quickshell: source.quickshell,
    terminal: source.terminal,
    screenshot: source.screenshot,
    overview: legacy.OverviewConfig(
      outerGap: source.overviewOuterGap,
      innerGapMultiplier: source.overviewInnerGapMultiplier),
    floating: legacy.FloatingConfig(
      xRatio: source.floatingXRatio,
      yRatio: source.floatingYRatio,
      widthRatio: source.floatingWidthRatio,
      heightRatio: source.floatingHeightRatio,
      minWidth: source.floatingMinWidth,
      minHeight: source.floatingMinHeight),
    screenLock: legacy.ScreenLockConfig(
      command: source.screenLockCommand),
    windowMenu: legacy.WindowMenuConfig(
      command: source.windowMenuCommand),
    scratchpad: legacy.ScratchpadConfig(
      widthRatio: source.scratchpadWidthRatio,
      heightRatio: source.scratchpadHeightRatio),
    cursor: source.cursor,
    presentationMode: source.presentationMode,
    allowExitSession: source.allowExitSession,
    protocolSurfaces: source.protocolSurfaces,
    keyBindings: source.keyBindings,
    pointerBindings: source.pointerBindings,
    activeTag: source.activeSlot,
    overviewActive: source.overviewActive,
    layerFocusExclusive: source.layerFocusExclusive,
    sessionLocked: source.sessionLocked,
    activeModifiers: source.activeModifiers,
    screenWidth: source.screenWidth,
    screenHeight: source.screenHeight,
    outerGaps: source.outerGaps,
    innerGaps: source.innerGaps,
    previousOuterGaps: source.previousOuterGaps,
    previousInnerGaps: source.previousInnerGaps,
    smartGaps: source.smartGaps,
    borderWidth: source.borderWidth,
    focusedBorderColor: source.focusedBorderColor,
    unfocusedBorderColor: source.unfocusedBorderColor,
    scrollerFocusCenter: source.scrollerFocusCenter,
    scrollerPreferCenter: source.scrollerPreferCenter,
    centerFocusedColumn: source.centerFocusedColumn,
    defaultColumnWidth: source.defaultColumnWidth,
    defaultWindowWidth: source.defaultWindowWidth,
    defaultWindowHeight: source.defaultWindowHeight,
    defaultMasterCount: source.defaultMasterCount,
    defaultMasterRatio: source.defaultMasterRatio,
    enableAnimations: source.enableAnimations,
    animationSpeed: source.animationSpeed,
    layoutCycle: source.layoutCycle,
    scratchpadWidthRatio: source.scratchpadWidthRatio,
    scratchpadHeightRatio: source.scratchpadHeightRatio,
    restoreActiveTag: source.restoreActiveSlot,
    restoreFocusedWindow: legacy.WindowId(uint32(source.restoreFocusedWindow)),
    nextGroupId: source.nextGroupId
  )

  for rule in source.tagRules:
    result.tagRules.add(legacy.TagRule(
      tagId: rule.slot,
      name: rule.name,
      defaultLayout: rule.defaultLayout))

  for rule in source.windowRules:
    result.windowRules.add(legacy.WindowRule(
      appIdMatch: rule.appIdMatch,
      titleMatch: rule.titleMatch,
      defaultTag: rule.defaultSlot,
      openFloating: rule.openFloating,
      keyboardShortcutsInhibit: rule.keyboardShortcutsInhibit,
      forcedLayout: rule.forcedLayout))

  for outputId in source.sortedOutputIdsByExternal():
    let output = source.outputData(outputId).get()
    let externalId = uint32(output.externalId)
    result.outputs[externalId] = legacy.OutputData(
      id: externalId,
      wlName: output.wlName,
      name: output.name,
      x: output.x,
      y: output.y,
      w: output.w,
      h: output.h,
      usableX: output.usableX,
      usableY: output.usableY,
      usableW: output.usableW,
      usableH: output.usableH,
      hasUsable: output.hasUsable)

  result.primaryOutput = source.legacyOutputId(source.primaryOutput)
  for outputId, tagId in source.outputTagsWithId():
    let outputExternal = source.legacyOutputId(outputId)
    let tagOpt = source.tagData(tagId)
    if outputExternal != 0 and tagOpt.isSome:
      result.outputTags[outputExternal] = tagOpt.get().slot

  for winId in source.sortedWindowIdsByExternal():
    let win = source.windowData(winId).get()
    let externalId = legacy.WindowId(uint32(win.externalId))
    result.windows[externalId] = legacy.WindowData(
      id: externalId,
      title: win.title,
      appId: win.appId,
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      fullscreenOutput: uint32(win.fullscreenOutput),
      parentId: legacy.WindowId(uint32(win.parentExternalId)),
      identifier: win.identifier,
      actualW: win.actualW,
      actualH: win.actualH,
      minWidth: win.minWidth,
      minHeight: win.minHeight,
      maxWidth: win.maxWidth,
      maxHeight: win.maxHeight,
      hasDecorationHint: win.hasDecorationHint,
      decorationHint: win.decorationHint,
      hasPresentationHint: win.hasPresentationHint,
      presentationHint: win.presentationHint,
      floatingGeom: win.floatingGeom,
      keyboardShortcutsInhibit: win.keyboardShortcutsInhibit,
      keyboardShortcutsInhibitBypass: win.keyboardShortcutsInhibitBypass)

  for groupId, group in source.groupsWithId():
    var legacyGroup = legacy.GroupState(
      id: uint32(groupId),
      activeWindow: source.legacyWindowId(group.activeWindow))
    for winId in group.windows:
      let externalId = source.legacyWindowId(winId)
      if externalId != 0:
        legacyGroup.windows.add(externalId)
    if legacyGroup.windows.len > 0:
      if legacyGroup.activeWindow == 0 or
          legacyGroup.windows.find(legacyGroup.activeWindow) == -1:
        legacyGroup.activeWindow = legacyGroup.windows[0]
      result.groups[uint32(groupId)] = legacyGroup

  for slot in source.sortedSlots():
    let tagId = source.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    let tag = source.tagData(tagId).get()
    var legacyTag = legacy.TagState(
      tagId: slot,
      name: tag.name,
      layoutMode: tag.layoutMode,
      focusedWindow: source.legacyWindowId(tag.focusedWindow),
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset,
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio)
    for columnId, column in source.columnsOnTagWithId(tagId):
      var legacyColumn = legacy.Column(
        widthProportion: column.widthProportion)
      for colWinId, _ in source.windowsOnColumnWithId(columnId):
        let externalId = source.legacyWindowId(colWinId)
        if externalId != 0:
          legacyColumn.windows.add(externalId)
      legacyTag.columns.add(legacyColumn)
    result.tags[slot] = legacyTag

  if result.activeTag == 0 and source.activeTag != NullTagId:
    let tagOpt = source.tagData(source.activeTag)
    if tagOpt.isSome:
      result.activeTag = tagOpt.get().slot

  for winId in source.scratchpadWindows:
    let externalId = source.legacyWindowId(winId)
    if externalId != 0:
      result.scratchpadWindows.add(externalId)
  for name, winId in source.namedScratchpads.pairs:
    let externalId = source.legacyWindowId(winId)
    if externalId != 0:
      result.namedScratchpads[name] = externalId
  result.visibleScratchpad = source.legacyWindowId(source.visibleScratchpad)
  result.isScratchpadVisible = source.isScratchpadVisible

  result.pointerOp = legacy.PointerOpState(
    kind: source.pointerOp.kind,
    windowId: source.legacyWindowId(source.pointerOp.windowId),
    initialGeom: source.pointerOp.initialGeom,
    edges: source.pointerOp.edges)

  for winId in source.focusHistory:
    let externalId = source.legacyWindowId(winId)
    if externalId != 0:
      result.focusHistory.add(externalId)
  for tagId in source.workspaceHistory:
    let tagOpt = source.tagData(tagId)
    if tagOpt.isSome:
      result.workspaceHistory.add(tagOpt.get().slot)

  for externalWinId, slot in source.restoreTagByWindow.pairs:
    result.restoreTagByWindow[legacy.WindowId(uint32(externalWinId))] = slot
  for externalWinId, restored in source.restoreWindows.pairs:
    result.restoreWindows[legacy.WindowId(uint32(externalWinId))] =
      restored.legacyRestoredWindow()
  for slot, restored in source.restoreTags.pairs:
    result.restoreTags[slot] = restored.legacyRestoredTag()
