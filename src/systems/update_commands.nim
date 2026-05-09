import options
import ../core/effects
import ../core/msg
import ../state/engine
import focus
import placement
import runtime
import scratchpad
import update_effects
import window_state
import workspaces

proc closeOverview(model: var Model): bool =
  model.setOverviewActive(false)

proc openOverview(model: var Model): bool =
  model.setOverviewActive(true)

proc recomputeAllTagFocus(model: var Model) =
  for tagId, _ in model.tagsWithId():
    discard model.recomputeVisibleFocus(tagId)

proc applyCommand*(model: var Model; msg: Msg): UpdateStep =
  case msg.kind
  of CmdSetLayout:
    result.dirty = model.setLayoutForSlot(msg.layoutTargetTag, msg.newLayout)
  of CmdSwitchLayout:
    result.dirty = model.switchLayout()
  of CmdSetMasterCount:
    result.dirty = model.setMasterCount(msg.count)
  of CmdAdjustMasterCount:
    result.dirty = model.adjustMasterCount(msg.deltaMC)
  of CmdSetMasterRatio:
    result.dirty = model.setMasterRatio(msg.ratio)
  of CmdAdjustMasterRatio:
    result.dirty = model.adjustMasterRatio(msg.deltaMR)
  of CmdResizeWidth:
    result.dirty = model.resizeWidth(msg.deltaW)
  of CmdResizeHeight:
    result.dirty = model.resizeHeight(msg.deltaH)
  of CmdSetColumnWidth:
    result.dirty = model.setFocusedColumnWidth(msg.targetWidth)

  of CmdRenameTag:
    result.dirty = model.renameActiveWorkspace(msg.newName)
    if result.dirty:
      result.effects.add(broadcastWorkspaceActivated(shellSnapshot(model)))
  of CmdGroupWindows:
    result.dirty = model.groupFocusedWindow()
  of CmdUngroupWindow, CmdFocusNextInGroup:
    result.dirty = true

  of CmdFocusNext:
    result.dirty = model.focusCycle(1)
  of CmdFocusPrev:
    result.dirty = model.focusCycle(-1)
  of CmdFocusDirection:
    result.dirty = model.focusByDirection(msg.direction)
  of CmdFocusLast:
    result.dirty = model.focusLast()
  of CmdFocusTagLeft:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, false))
  of CmdFocusTagRight:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, false))
  of CmdFocusOccupiedTagLeft:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, true))
  of CmdFocusOccupiedTagRight:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, true))
  of CmdFocusColumnFirst:
    result.dirty = model.focusColumnAtEdge(true)
  of CmdFocusColumnLast:
    result.dirty = model.focusColumnAtEdge(false)
  of CmdFocusWindowOrWorkspaceUp:
    result.dirty = model.focusWindowOrWorkspace(-1)
  of CmdFocusWindowOrWorkspaceDown:
    result.dirty = model.focusWindowOrWorkspace(1)
  of CmdFocusTag:
    result.dirty = model.focusWorkspaceSlot(msg.focusTag)
  of CmdFocusWorkspaceIndex:
    result.dirty = model.focusWorkspaceIndex(msg.workspaceIndex)
  of CmdFocusWindowById:
    result.dirty = model.focusExternalWindow(msg.focusWindowId.externalWindowId())

  of CmdMoveToTag:
    result.dirty = model.moveFocusedWindowToSlot(msg.targetTag)
  of CmdSwapWindowToTag:
    result.dirty = model.swapFocusedWindowToSlot(msg.targetTagSwap)
  of CmdMoveToTagLeft:
    result.dirty = model.moveFocusedWindowToSlot(
      model.nearestWorkspaceSlot(-1, false))
  of CmdMoveToTagRight:
    result.dirty = model.moveFocusedWindowToSlot(
      model.nearestWorkspaceSlot(1, false))
  of CmdMoveToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.workspaceIndex)
    result.dirty = slot != 0 and model.moveFocusedWindowToSlot(slot)
  of CmdMoveWindowLeft:
    result.dirty = model.moveFocusedWindowLeft()
  of CmdMoveWindowRight:
    result.dirty = model.moveFocusedWindowRight()
  of CmdMoveWindowUp:
    result.dirty = model.moveFocusedWindowUp()
  of CmdMoveWindowDown:
    result.dirty = model.moveFocusedWindowDown()
  of CmdMoveWindowUpOrToWorkspaceUp:
    result.dirty = model.moveFocusedWindowUpOrWorkspace()
  of CmdMoveWindowDownOrToWorkspaceDown:
    result.dirty = model.moveFocusedWindowDownOrWorkspace()
  of CmdMoveColumnLeft:
    result.dirty = model.moveFocusedColumnLeft()
  of CmdMoveColumnRight:
    result.dirty = model.moveFocusedColumnRight()
  of CmdMoveColumnToFirst:
    result.dirty = model.moveFocusedColumnToFirst()
  of CmdMoveColumnToLast:
    result.dirty = model.moveFocusedColumnToLast()
  of CmdSwapWindowUp:
    result.dirty = model.moveFocusedWindowUp()
  of CmdSwapWindowDown:
    result.dirty = model.moveFocusedWindowDown()
  of CmdConsumeWindow:
    result.dirty = model.consumeNextColumnWindow()
  of CmdExpelWindow:
    result.dirty = model.expelFocusedWindow()
  of CmdZoom:
    result.dirty = model.zoomFocusedWindow()

  of CmdMoveToScratchpad:
    result.dirty = model.moveFocusedToScratchpad()
  of CmdMoveToNamedScratchpad:
    result.dirty = model.moveFocusedToScratchpad(msg.scratchpadName)
  of CmdToggleScratchpad:
    result.dirty = model.toggleScratchpad()
  of CmdToggleNamedScratchpad:
    result.dirty = model.toggleNamedScratchpad(msg.scratchpadName)
  of CmdRestoreScratchpad:
    result.dirty = model.restoreScratchpad()

  of CmdToggleOverview:
    if model.overviewActive:
      result.dirty = model.closeOverview()
      if result.dirty:
        model.recomputeAllTagFocus()
        result.effects.add(broadcastOverview(false))
    else:
      result.dirty = model.openOverview()
      if result.dirty:
        result.effects.add(broadcastOverview(true))
        result.effects.add(Effect(kind: EffFocusShellUi))
  of CmdOpenOverview:
    result.dirty = model.openOverview()
    if result.dirty:
      result.effects.add(broadcastOverview(true))
      result.effects.add(Effect(kind: EffFocusShellUi))
  of CmdCloseOverview:
    result.dirty = model.closeOverview()
    if result.dirty:
      model.recomputeAllTagFocus()
      result.effects.add(broadcastOverview(false))

  of CmdToggleFloating:
    result.dirty = model.toggleFloatingFocused()
  of CmdMoveFloating:
    result.dirty = model.moveFloatingFocused(msg.moveDX, msg.moveDY)
  of CmdResizeFloating:
    result.dirty = model.resizeFloatingFocused(msg.deltaFW, msg.deltaFH)
  of CmdAdjustGaps:
    result.dirty = model.adjustGaps(msg.deltaG)
  of CmdToggleGaps:
    result.dirty = model.toggleGaps()
  of CmdToggleFullscreen:
    let focused = model.focusedWindow()
    result.dirty = model.toggleFullscreenFocused()
    if result.dirty:
      let win = model.windowData(focused).get()
      result.effects.addSetFullscreenEffect(
        model.runtimeWindowId(focused), win.isFullscreen,
        uint32(win.fullscreenOutput))
  of CmdToggleMaximized:
    let focused = model.focusedWindow()
    result.dirty = model.toggleMaximizedFocused()
    if result.dirty:
      let win = model.windowData(focused).get()
      result.effects.addSetMaximizedEffect(
        model.runtimeWindowId(focused), win.isMaximized)
  of CmdMinimize:
    let focused = model.focusedWindow()
    result.dirty = model.minimizeFocused()
    if result.dirty:
      result.effects.addSetMaximizedEffect(model.runtimeWindowId(focused), false)
  of CmdToggleKeyboardShortcutsInhibit:
    result.dirty = model.toggleKeyboardShortcutsInhibitFocused()
  of CmdSelectWindow:
    result.dirty = model.closeOverview()
    if result.dirty:
      model.recomputeAllTagFocus()
  of CmdCloseWindow:
    let focused = model.focusedWindow()
    if focused != NullWindowId:
      result.effects.add(Effect(
        kind: EffCloseWindow,
        closeId: model.runtimeWindowId(focused)))
  of CmdCloseWindowById:
    if model.windowForExternal(msg.closeWindowId.externalWindowId()) !=
        NullWindowId:
      result.effects.add(Effect(kind: EffCloseWindow, closeId: msg.closeWindowId))
  of CmdSpawn:
    if msg.spawnCommand.len > 0:
      result.effects.add(Effect(kind: EffSpawn, spawnCommand: msg.spawnCommand))
  of CmdTick:
    result.dirty = model.tickAnimations()
  of CmdLockSession:
    if model.screenLockCommand.len > 0:
      result.effects.add(Effect(
        kind: EffSpawnScreenLock,
        screenLockCommand: model.screenLockCommand))
    else:
      result.effects.add(Effect(
        kind: EffLog,
        msg: "screen lock command is not configured"))
  of CmdWarpPointer:
    result.effects.add(Effect(
      kind: EffPointerWarp,
      warpX: msg.warpX,
      warpY: msg.warpY))
  of CmdEatNextKey:
    result.effects.add(Effect(kind: EffEnsureNextKeyEaten))
  of CmdCancelEatNextKey:
    result.effects.add(Effect(kind: EffCancelEnsureNextKeyEaten))
  of CmdStopManager:
    result.effects.add(Effect(kind: EffStopManager))
  of CmdTriadReload:
    result.effects.add(Effect(kind: EffTriadReload))
  of CmdExitSession:
    if model.allowExitSession:
      result.effects.add(Effect(kind: EffExitSession))
    else:
      result.effects.add(Effect(
        kind: EffLog,
        msg: "exit-session is disabled by config"))
  of CmdFocusShellUi:
    if not model.sessionLocked and not model.layerFocusExclusive:
      result.effects.add(Effect(kind: EffFocusShellUi))
  of CmdScreenshot:
    result.effects.add(Effect(
      kind: EffScreenshot,
      screenshotKind: msg.screenshotKind,
      screenshotPath: msg.screenshotPath,
      screenshotShowPointer: msg.screenshotShowPointer))
  of CmdConfigReload, CmdSpawnTerminal:
    result.dirty = true
  else:
    discard
