import ../core/effects
import ../core/msg
import ../state/engine
from ../types/runtime_values import Direction
import focus
import placement
import runtime
import scratchpad
import update_effects
import window_state
import workspaces

proc closeOverview(model: var Model): bool =
  let wasActive = model.overviewActive
  result = model.setOverviewActive(false)
  result = model.clearOverviewSelection() or result
  if wasActive:
    result = model.restoreOverviewViewportSnapshot() or result

proc openOverview(model: var Model): bool =
  result = model.setOverviewActive(true)
  if result:
    discard model.saveOverviewViewportSnapshot()
    discard model.setOverviewSelection(model.initialOverviewWindow())

proc recomputeAllTagFocus(model: var Model) =
  for tagId, _ in model.tagsWithId():
    discard model.recomputeVisibleFocus(tagId)

proc applyCommand*(model: var Model; msg: Msg): UpdateStep =
  case msg.kind
  of MsgKind.CmdSetLayout:
    result.dirty = model.setLayoutForSlot(msg.layoutTargetTag, msg.newLayout)
  of MsgKind.CmdSwitchLayout:
    result.dirty = model.switchLayout()
  of MsgKind.CmdSetMasterCount:
    result.dirty = model.setMasterCount(msg.count)
  of MsgKind.CmdAdjustMasterCount:
    result.dirty = model.adjustMasterCount(msg.deltaMC)
  of MsgKind.CmdSetMasterRatio:
    result.dirty = model.setMasterRatio(msg.ratio)
  of MsgKind.CmdAdjustMasterRatio:
    result.dirty = model.adjustMasterRatio(msg.deltaMR)
  of MsgKind.CmdResizeWidth:
    result.dirty = model.resizeWidth(msg.deltaW)
  of MsgKind.CmdResizeHeight:
    result.dirty = model.resizeHeight(msg.deltaH)
  of MsgKind.CmdSetColumnWidth:
    result.dirty = model.setFocusedColumnWidth(msg.targetWidth)

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
    if not model.overviewActive:
      result.dirty = model.focusLast()
  of MsgKind.CmdFocusTagLeft:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceSlot(
        model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdFocusTagRight:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceSlot(
        model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdFocusOccupiedTagLeft:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceSlot(
        model.nearestWorkspaceSlot(-1, true))
  of MsgKind.CmdFocusOccupiedTagRight:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceSlot(
        model.nearestWorkspaceSlot(1, true))
  of MsgKind.CmdFocusColumnFirst:
    if not model.overviewActive:
      result.dirty = model.focusColumnAtEdge(true)
  of MsgKind.CmdFocusColumnLast:
    if not model.overviewActive:
      result.dirty = model.focusColumnAtEdge(false)
  of MsgKind.CmdFocusWindowOrWorkspaceUp:
    if model.overviewActive:
      result.dirty = model.focusByDirection(Direction.DirUp)
    else:
      result.dirty = model.focusWindowOrWorkspace(-1)
  of MsgKind.CmdFocusWindowOrWorkspaceDown:
    if model.overviewActive:
      result.dirty = model.focusByDirection(Direction.DirDown)
    else:
      result.dirty = model.focusWindowOrWorkspace(1)
  of MsgKind.CmdFocusTag:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceSlot(msg.focusTag)
  of MsgKind.CmdFocusWorkspaceIndex:
    if not model.overviewActive:
      result.dirty = model.focusWorkspaceIndex(msg.workspaceIndex)
  of MsgKind.CmdFocusWindowById:
    if model.overviewActive:
      let winId = model.windowForExternal(msg.focusWindowId.externalWindowId())
      if model.overviewWindowIds().find(winId) != -1:
        result.dirty = model.setOverviewSelection(winId)
    else:
      result.dirty = model.focusExternalWindow(
        msg.focusWindowId.externalWindowId())

  of MsgKind.CmdMoveToTag:
    result.dirty = model.moveFocusedWindowToSlotAndFocus(msg.targetTag)
  of MsgKind.CmdSwapWindowToTag:
    result.dirty = model.swapFocusedWindowToSlot(msg.targetTagSwap)
  of MsgKind.CmdMoveToTagLeft:
    result.dirty = model.moveFocusedWindowToSlotAndFocus(
      model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdMoveToTagRight:
    result.dirty = model.moveFocusedWindowToSlotAndFocus(
      model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdMoveToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.workspaceIndex)
    result.dirty = slot != 0 and model.moveFocusedWindowToSlotAndFocus(slot)
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

  of MsgKind.CmdToggleFloating:
    result.dirty = model.toggleFloatingFocused()
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
    result.dirty = model.toggleFullscreenForExternal(
      msg.fullscreenWindowId.externalWindowId())
  of MsgKind.CmdExitFullscreenById:
    result.dirty = model.exitFullscreenForExternal(
      msg.fullscreenWindowId.externalWindowId())
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
      result.effects.add(Effect(
        kind: EffectKind.EffCloseWindow,
        closeId: model.runtimeWindowId(focused)))
  of MsgKind.CmdCloseWindowById:
    if model.windowForExternal(msg.closeWindowId.externalWindowId()) !=
        NullWindowId:
      result.effects.add(Effect(kind: EffectKind.EffCloseWindow,
          closeId: msg.closeWindowId))
  of MsgKind.CmdSpawn:
    if msg.spawnCommand.len > 0:
      result.effects.add(Effect(kind: EffectKind.EffSpawn,
          spawnCommand: msg.spawnCommand))
  of MsgKind.CmdTick:
    result.dirty = model.tickAnimations()
  of MsgKind.CmdLockSession:
    if model.screenLockCommand.len > 0:
      result.effects.add(Effect(
        kind: EffectKind.EffSpawnScreenLock,
        screenLockCommand: model.screenLockCommand))
    else:
      result.effects.add(Effect(
        kind: EffectKind.EffLog,
        msg: "screen lock command is not configured"))
  of MsgKind.CmdWarpPointer:
    result.effects.add(Effect(
      kind: EffectKind.EffPointerWarp,
      warpX: msg.warpX,
      warpY: msg.warpY))
  of MsgKind.CmdEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffEnsureNextKeyEaten))
  of MsgKind.CmdCancelEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffCancelEnsureNextKeyEaten))
  of MsgKind.CmdStopManager:
    result.effects.add(Effect(kind: EffectKind.EffStopManager))
  of MsgKind.CmdTriadReload:
    result.effects.add(Effect(kind: EffectKind.EffTriadReload))
  of MsgKind.CmdExitSession:
    if model.allowExitSession:
      result.effects.add(Effect(kind: EffectKind.EffExitSession))
    else:
      result.effects.add(Effect(
        kind: EffectKind.EffLog,
        msg: "exit-session is disabled by config"))
  of MsgKind.CmdFocusShellUi:
    if not model.sessionLocked and not model.layerFocusExclusive:
      result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdShowHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(true)
  of MsgKind.CmdHideHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(false)
  of MsgKind.CmdToggleHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(not model.hotkeyOverlayOpen)
  of MsgKind.CmdScreenshot:
    result.effects.add(Effect(
      kind: EffectKind.EffScreenshot,
      screenshotKind: msg.screenshotKind,
      screenshotPath: msg.screenshotPath,
      screenshotPointerMode: msg.screenshotPointerMode,
      screenshotWriteToDisk: msg.screenshotWriteToDisk,
      screenshotCopyToClipboard: msg.screenshotCopyToClipboard))
  of MsgKind.CmdConfigReload, MsgKind.CmdSpawnTerminal:
    result.dirty = true
  else:
    discard
