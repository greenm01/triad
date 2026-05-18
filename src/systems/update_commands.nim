import std/[options, strutils]
import ../core/[effects, msg, shell_profiles]
import ../state/engine
from ../types/runtime_values import
  Direction, FrameSplitOrientation, JanetLayoutId, LayoutMode, RecentWindowDirection
import
  dialog_focus, focus, output_navigation, placement, recent_windows, runtime,
  scratchpad, update_effects, window_state, window_rules, workspaces

proc closeOverview(model: var Model): bool =
  model.closeOverviewMode()

proc openOverview(model: var Model): bool =
  if model.overviewActive:
    return false
  discard model.setOverviewTabModeActive(false, 0'u32)
  discard model.setOverviewWorkspacePreviewsActive(true)
  result = model.setOverviewActive(true)
  if result:
    discard model.clearOverviewSelection()

proc recomputeAllTagFocus(model: var Model) =
  for tagId, _ in model.tagsWithId():
    discard model.recomputeVisibleFocus(tagId)

proc configuredKeyboardLayoutCount(model: Model): uint32 =
  let xkb = model.input.keyboard.xkb
  if not xkb.layoutSet:
    return 0
  for name in xkb.layout.split(','):
    if name.strip().len > 0:
      inc result

proc switchKeyboardLayout(
    model: var Model, delta: int32, index: int32
): tuple[changed: bool, activeIndex: uint32] =
  let count = model.configuredKeyboardLayoutCount()
  if count == 0:
    return (false, 0'u32)
  let current = min(model.keyboardLayoutIndex, count - 1)
  let next =
    if index >= 0:
      min(uint32(index), count - 1)
    else:
      uint32((int32(current) + delta + int32(count)) mod int32(count))
  if next == model.keyboardLayoutIndex:
    return (false, next)
  model.keyboardLayoutIndex = next
  (true, next)

proc showLayoutSwitchToast(
    model: var Model, layout: LayoutMode, customLayout = JanetLayoutId("")
): bool =
  model.openLayoutSwitchToast(layout, customLayout)

proc applyCommand*(model: var Model, msg: Msg): UpdateStep =
  case msg.kind
  of MsgKind.CmdSetLayout:
    result.dirty = model.setLayoutForSlot(msg.layoutTargetTag, msg.newLayout)
    if result.dirty and msg.layoutTargetTag == 0:
      result.dirty = model.showLayoutSwitchToast(msg.newLayout) or result.dirty
  of MsgKind.CmdSetCustomLayout:
    result.dirty =
      model.setCustomLayoutForSlot(msg.customLayoutTargetTag, msg.customLayout)
    if result.dirty and msg.customLayoutTargetTag == 0:
      let custom = model.customLayoutConfig(msg.customLayout)
      if custom.isSome:
        result.dirty =
          model.showLayoutSwitchToast(custom.get().fallback.builtin, msg.customLayout) or
          result.dirty
  of MsgKind.CmdSetNativeLayout:
    result.dirty =
      model.setNativeLayoutForSlot(msg.nativeLayoutTargetTag, msg.nativeLayout)
    if result.dirty and msg.nativeLayoutTargetTag == 0:
      let native = model.nativeLayoutConfig(msg.nativeLayout)
      if native.isSome:
        result.dirty =
          model.showLayoutSwitchToast(native.get().fallback.builtin) or result.dirty
  of MsgKind.CmdFrameSplitHorizontal:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedFrame(FrameSplitOrientation.Horizontal)
  of MsgKind.CmdFrameSplitVertical:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedFrame(FrameSplitOrientation.Vertical)
  of MsgKind.CmdFrameUnsplit:
    result.dirty = not model.overviewActive and model.unsplitFocusedFrame()
  of MsgKind.CmdFrameTabNext:
    result.dirty = not model.overviewActive and model.focusFrameTab(1)
  of MsgKind.CmdFrameTabPrev:
    result.dirty = not model.overviewActive and model.focusFrameTab(-1)
  of MsgKind.CmdSwitchLayout:
    result.dirty = model.switchLayout()
    if result.dirty:
      let tagOpt = model.tagData(model.activeTag)
      if tagOpt.isSome:
        result.dirty =
          model.showLayoutSwitchToast(
            tagOpt.get().layoutMode, tagOpt.get().customLayoutId
          ) or result.dirty
  of MsgKind.CmdSetMasterCount:
    result.dirty = model.setMasterCount(msg.count)
  of MsgKind.CmdAdjustMasterCount:
    result.dirty = model.adjustMasterCount(msg.deltaMC)
  of MsgKind.CmdSetMasterRatio:
    result.dirty = model.setMasterRatio(msg.ratio)
  of MsgKind.CmdAdjustMasterRatio:
    result.dirty = model.adjustMasterRatio(msg.deltaMR)
  of MsgKind.CmdMaximizeColumn:
    result.dirty = model.toggleFocusedColumnFullWidth()
  of MsgKind.CmdResizeWidth:
    result.dirty = model.resizeWidth(msg.deltaW)
  of MsgKind.CmdResizeHeight:
    result.dirty = model.resizeHeight(msg.deltaH)
  of MsgKind.CmdSetColumnWidth:
    result.dirty = model.setFocusedColumnWidth(msg.targetWidth)
  of MsgKind.CmdSwitchProportionPreset:
    result.dirty = model.switchProportionPreset(msg.proportionPresetDelta)
  of MsgKind.CmdRenameTag:
    result.dirty = model.renameActiveWorkspace(msg.newName)
    if result.dirty:
      result.effects.add(broadcastWorkspaceActivated(shellSnapshot(model)))
  of MsgKind.CmdGroupWindows:
    result.dirty = model.groupFocusedWindow()
  of MsgKind.CmdUngroupWindow, MsgKind.CmdFocusNextInGroup:
    result.dirty = true
  of MsgKind.CmdFocusNext:
    result.dirty = model.focusCycle(1)
  of MsgKind.CmdFocusPrev:
    result.dirty = model.focusCycle(-1)
  of MsgKind.CmdFocusDirection:
    result.dirty = model.focusByDirection(msg.direction)
  of MsgKind.CmdFocusLast:
    result.dirty = model.focusLast()
  of MsgKind.CmdFocusTagLeft:
    result.dirty =
      if model.overviewActive:
        model.focusOverviewWorkspaceStep(-1)
      else:
        model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdFocusTagRight:
    result.dirty =
      if model.overviewActive:
        model.focusOverviewWorkspaceStep(1)
      else:
        model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdFocusOccupiedTagLeft:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, true))
  of MsgKind.CmdFocusOccupiedTagRight:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, true))
  of MsgKind.CmdFocusColumnFirst:
    result.dirty = model.focusColumnAtEdge(true)
  of MsgKind.CmdFocusColumnLast:
    result.dirty = model.focusColumnAtEdge(false)
  of MsgKind.CmdFocusWindowOrWorkspaceUp:
    result.dirty =
      if model.overviewActive:
        model.focusByDirection(Direction.DirUp)
      else:
        model.focusWindowOrWorkspace(-1)
  of MsgKind.CmdFocusWindowOrWorkspaceDown:
    result.dirty =
      if model.overviewActive:
        model.focusByDirection(Direction.DirDown)
      else:
        model.focusWindowOrWorkspace(1)
  of MsgKind.CmdFocusTag:
    result.dirty = model.focusWorkspaceSlot(msg.focusTag)
  of MsgKind.CmdFocusWorkspaceIndex:
    result.dirty = model.focusWorkspaceIndex(msg.workspaceIndex)
  of MsgKind.CmdReorderWorkspaceIndex:
    result.dirty =
      model.reorderWorkspaceIndex(msg.reorderWorkspaceIndex, msg.reorderTargetIndex)
  of MsgKind.CmdFocusOutput:
    result.dirty = model.focusOutputTarget(msg.outputTarget)
  of MsgKind.CmdMoveWorkspaceToOutput:
    result.dirty = model.moveActiveWorkspaceToOutputTarget(msg.outputTarget)
  of MsgKind.CmdMoveToOutput:
    result.dirty = model.moveFocusedWindowToOutputTarget(msg.outputTarget)
  of MsgKind.CmdFocusWindowById:
    result.dirty = model.focusExternalWindow(msg.focusWindowId.externalWindowId())
  of MsgKind.CmdMoveToTag:
    result.dirty = model.moveFocusedWindowToSlotAndFocus(msg.targetTag)
  of MsgKind.CmdMoveWindowToTag:
    let winId = model.windowForExternal(ExternalWindowId(msg.moveWindowId))
    if winId != NullWindowId and model.moveWindowToSlot(winId, msg.moveTargetTag):
      result.dirty = true
      if msg.moveFollowWindow:
        result.dirty = model.focusWindow(winId) or result.dirty
  of MsgKind.CmdSwapWindowToTag:
    result.dirty = model.swapFocusedWindowToSlot(msg.targetTagSwap)
  of MsgKind.CmdMoveToTagLeft:
    result.dirty =
      model.moveFocusedWindowToSlotAndFocus(model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdMoveToTagRight:
    result.dirty =
      model.moveFocusedWindowToSlotAndFocus(model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdMoveToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.workspaceIndex)
    result.dirty = slot != 0 and model.moveFocusedWindowToSlotAndFocus(slot)
  of MsgKind.CmdMoveWindowToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.moveWorkspaceIndex)
    let winId = model.windowForExternal(ExternalWindowId(msg.moveWorkspaceWindowId))
    if slot != 0 and winId != NullWindowId and model.moveWindowToSlot(winId, slot):
      result.dirty = true
      if msg.moveWorkspaceFollowWindow:
        result.dirty = model.focusWindow(winId) or result.dirty
  of MsgKind.CmdMoveWindowLeft:
    result.dirty = model.moveFocusedWindowLeft()
  of MsgKind.CmdMoveWindowRight:
    result.dirty = model.moveFocusedWindowRight()
  of MsgKind.CmdMoveWindowUp:
    result.dirty = model.moveFocusedWindowUp()
  of MsgKind.CmdMoveWindowDown:
    result.dirty = model.moveFocusedWindowDown()
  of MsgKind.CmdMoveWindowUpOrToWorkspaceUp:
    result.dirty = model.moveFocusedWindowUpOrWorkspace()
  of MsgKind.CmdMoveWindowDownOrToWorkspaceDown:
    result.dirty = model.moveFocusedWindowDownOrWorkspace()
  of MsgKind.CmdMoveColumnLeft:
    result.dirty = model.moveFocusedColumnLeft()
  of MsgKind.CmdMoveColumnRight:
    result.dirty = model.moveFocusedColumnRight()
  of MsgKind.CmdMoveColumnToFirst:
    result.dirty = model.moveFocusedColumnToFirst()
  of MsgKind.CmdMoveColumnToLast:
    result.dirty = model.moveFocusedColumnToLast()
  of MsgKind.CmdSwapWindowUp:
    result.dirty = model.moveFocusedWindowUp()
  of MsgKind.CmdSwapWindowDown:
    result.dirty = model.moveFocusedWindowDown()
  of MsgKind.CmdConsumeWindow:
    result.dirty = model.consumeNextColumnWindow()
  of MsgKind.CmdExpelWindow:
    result.dirty = model.expelFocusedWindow()
  of MsgKind.CmdZoom:
    result.dirty = model.zoomFocusedWindow()
  of MsgKind.CmdMoveToScratchpad:
    result.dirty = model.moveFocusedToScratchpad()
  of MsgKind.CmdMoveToNamedScratchpad:
    result.dirty = model.moveFocusedToScratchpad(msg.scratchpadName)
  of MsgKind.CmdToggleScratchpad:
    result.dirty = model.toggleScratchpad()
  of MsgKind.CmdToggleNamedScratchpad:
    result.dirty = model.toggleNamedScratchpad(msg.scratchpadName)
  of MsgKind.CmdRestoreScratchpad:
    result.dirty = model.restoreScratchpad()
  of MsgKind.CmdToggleOverview:
    if model.overviewActive:
      result.dirty = model.closeOverview()
      if result.dirty:
        model.recomputeAllTagFocus()
        result.effects.add(broadcastOverview(false))
    else:
      result.dirty = model.openOverview()
      if result.dirty:
        result.effects.add(broadcastOverview(true))
        result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdOpenOverview:
    result.dirty = model.openOverview()
    if result.dirty:
      result.effects.add(broadcastOverview(true))
      result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdCloseOverview:
    result.dirty = model.closeOverview()
    if result.dirty:
      result.effects.add(broadcastOverview(false))
  of MsgKind.CmdOverviewTab:
    if model.overviewTabMode and msg.overviewTabModifiers != 0:
      if not model.overviewActive:
        result.dirty = model.openOverview()
        result.dirty =
          model.setOverviewTabModeActive(true, msg.overviewTabModifiers) or result.dirty
        if result.dirty:
          result.effects.add(broadcastOverview(true))
          result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
      else:
        result.dirty =
          model.setOverviewTabModeActive(true, msg.overviewTabModifiers) or result.dirty
        result.dirty = model.focusOverviewTabNext() or result.dirty
  of MsgKind.CmdRecentWindowNext:
    result.dirty = model.openOrAdvanceRecentWindow(
      RecentWindowDirection.Forward, msg.recentScope, msg.recentScopeSet,
      msg.recentFilter, msg.recentFilterSet,
    )
  of MsgKind.CmdRecentWindowPrev:
    result.dirty = model.openOrAdvanceRecentWindow(
      RecentWindowDirection.Backward, msg.recentScope, msg.recentScopeSet,
      msg.recentFilter, msg.recentFilterSet,
    )
  of MsgKind.CmdRecentWindowConfirm:
    let selected = model.confirmedRecentWindow()
    result.dirty = selected != NullWindowId
    if selected != NullWindowId:
      result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.CmdRecentWindowCancel:
    result.dirty = model.cancelRecentWindows()
  of MsgKind.CmdRecentWindowFirst:
    result.dirty = model.selectFirstRecentWindow()
  of MsgKind.CmdRecentWindowLast:
    result.dirty = model.selectLastRecentWindow()
  of MsgKind.CmdRecentWindowScope:
    result.dirty = model.setRecentWindowScopeCommand(msg.recentTargetScope)
  of MsgKind.CmdRecentWindowCycleScope:
    result.dirty = model.cycleRecentWindowScope()
  of MsgKind.CmdRecentWindowCloseCurrent:
    let selected = model.closeCurrentRecentWindow()
    if selected != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffCloseWindow, closeId: model.runtimeWindowId(selected)
        )
      )
      result.dirty = true
  of MsgKind.CmdToggleFloating:
    result.dirty = model.toggleFloatingFocused()
  of MsgKind.CmdSetWindowFloatingById:
    result.dirty = model.setFloatingForExternal(
      ExternalWindowId(msg.floatingWindowId), msg.windowFloating
    )
  of MsgKind.CmdSetWindowMaximizedById:
    result.dirty = model.setMaximizedForExternal(
      ExternalWindowId(msg.maximizedWindowId), msg.windowMaximized
    )
  of MsgKind.CmdMoveFloating:
    result.dirty = model.moveFloatingFocused(msg.moveDX, msg.moveDY)
  of MsgKind.CmdResizeFloating:
    result.dirty = model.resizeFloatingFocused(msg.deltaFW, msg.deltaFH)
  of MsgKind.CmdAdjustGaps:
    result.dirty = model.adjustGaps(msg.deltaG)
  of MsgKind.CmdToggleGaps:
    result.dirty = model.toggleGaps()
  of MsgKind.CmdToggleFullscreen:
    result.dirty = model.toggleFullscreenFocused()
  of MsgKind.CmdToggleFullscreenById:
    result.dirty =
      model.toggleFullscreenForExternal(msg.fullscreenWindowId.externalWindowId())
  of MsgKind.CmdExitFullscreenById:
    result.dirty =
      model.exitFullscreenForExternal(msg.fullscreenWindowId.externalWindowId())
  of MsgKind.CmdToggleMaximized:
    result.dirty = model.toggleMaximizedFocused()
  of MsgKind.CmdMinimize:
    result.dirty = model.minimizeFocused()
  of MsgKind.CmdToggleKeyboardShortcutsInhibit:
    result.dirty = model.toggleKeyboardShortcutsInhibitFocused()
  of MsgKind.CmdSelectWindow:
    let selected = model.selectedOverviewWindow()
    result.dirty = model.closeOverview()
    if selected != NullWindowId:
      result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.CmdCloseWindow:
    let focused = model.focusedOnActiveTag()
    if focused != NullWindowId:
      result.effects.add(
        Effect(kind: EffectKind.EffCloseWindow, closeId: model.runtimeWindowId(focused))
      )
  of MsgKind.CmdCloseWindowById:
    if model.windowForExternal(msg.closeWindowId.externalWindowId()) != NullWindowId:
      result.effects.add(
        Effect(kind: EffectKind.EffCloseWindow, closeId: msg.closeWindowId)
      )
  of MsgKind.CmdSpawn:
    if msg.spawnCommand.len > 0:
      result.effects.add(
        Effect(kind: EffectKind.EffSpawn, spawnCommand: msg.spawnCommand)
      )
  of MsgKind.CmdTick:
    let elapsedMs =
      if msg.tickElapsedMs > 0: msg.tickElapsedMs else: DefaultFrameIntervalMs
    result.dirty = model.tickAnimations(elapsedMs)
    result.dirty = model.tickOverviewPointerHold(elapsedMs) or result.dirty
    result.dirty = model.tickRecentWindows(elapsedMs) or result.dirty
    result.dirty = model.tickLayoutSwitchToast(elapsedMs) or result.dirty
    result.dirty = model.flushPendingDialogFocus() or result.dirty
  of MsgKind.CmdExpireStartupWindowRules:
    result.dirty = model.expireStartupWindowRules()
  of MsgKind.CmdLockSession:
    if model.screenLockCommand.len > 0:
      result.effects.add(
        Effect(
          kind: EffectKind.EffSpawnScreenLock,
          screenLockCommand: model.screenLockCommand,
        )
      )
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "screen lock command is not configured")
      )
  of MsgKind.CmdWarpPointer:
    result.effects.add(
      Effect(kind: EffectKind.EffPointerWarp, warpX: msg.warpX, warpY: msg.warpY)
    )
  of MsgKind.CmdEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffEnsureNextKeyEaten))
  of MsgKind.CmdCancelEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffCancelEnsureNextKeyEaten))
  of MsgKind.CmdSwitchKeyboardLayout:
    let switched =
      model.switchKeyboardLayout(msg.keyboardLayoutDelta, msg.keyboardLayoutIndex)
    if switched.changed:
      result.dirty = true
      let snapshot = shellSnapshot(model)
      result.effects.add(
        Effect(
          kind: EffectKind.EffSetKeyboardLayout,
          keyboardLayoutIndex: switched.activeIndex,
        )
      )
      result.effects.add(broadcastKeyboardLayoutsChanged(snapshot))
      result.effects.add(broadcastKeyboardLayoutSwitched(switched.activeIndex))
  of MsgKind.CmdStopManager:
    result.effects.add(Effect(kind: EffectKind.EffStopManager))
  of MsgKind.CmdTriadReload:
    result.effects.add(Effect(kind: EffectKind.EffTriadReload))
  of MsgKind.CmdExitSession:
    if model.allowExitSession:
      result.dirty = model.setHotkeyOverlayOpen(false) or result.dirty
      result.dirty = model.cancelRecentWindows() or result.dirty
      result.dirty = model.setExitSessionConfirmOpen(true) or result.dirty
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdExitSessionImmediate:
    if model.allowExitSession:
      result.dirty = model.setHotkeyOverlayOpen(false) or result.dirty
      result.dirty = model.cancelRecentWindows() or result.dirty
      result.dirty = model.setExitSessionConfirmOpen(false) or result.dirty
      result.effects.add(Effect(kind: EffectKind.EffExitSession))
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdConfirmExitSession:
    let wasOpen = model.exitSessionConfirmOpen
    result.dirty = model.setExitSessionConfirmOpen(false)
    if wasOpen and model.allowExitSession:
      result.effects.add(Effect(kind: EffectKind.EffExitSession))
    elif wasOpen:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdDismissExitSessionConfirm:
    result.dirty = model.setExitSessionConfirmOpen(false)
  of MsgKind.CmdFocusShellUi:
    if not model.sessionLocked and not model.layerFocusExclusive:
      result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdSwitchShell:
    if model.shells.hasShellProfile(msg.shellName):
      if model.shells.active != msg.shellName:
        model.shells.active = msg.shellName
        result.dirty = true
    else:
      result.effects.add(
        Effect(
          kind: EffectKind.EffLog, msg: "shell profile not found: " & msg.shellName
        )
      )
  of MsgKind.CmdCycleShell:
    let nextShell = model.shells.nextShellName()
    if nextShell.len > 0 and model.shells.active != nextShell:
      model.shells.active = nextShell
      result.dirty = true
  of MsgKind.CmdShowHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(true)
  of MsgKind.CmdHideHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(false)
  of MsgKind.CmdToggleHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(not model.hotkeyOverlayOpen)
  of MsgKind.CmdScreenshot:
    result.effects.add(
      Effect(
        kind: EffectKind.EffScreenshot,
        screenshotKind: msg.screenshotKind,
        screenshotPath: msg.screenshotPath,
        screenshotPointerMode: msg.screenshotPointerMode,
        screenshotWriteToDisk: msg.screenshotWriteToDisk,
        screenshotCopyToClipboard: msg.screenshotCopyToClipboard,
      )
    )
  of MsgKind.CmdConfigReload, MsgKind.CmdSpawnTerminal:
    result.dirty = true
  else:
    discard
