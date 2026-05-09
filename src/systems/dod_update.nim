import json, options
import ../core/effects
import ../core/msg
import ../core/niri_state
import ../core/triad_state
import ../state/engine
import ../types/shell_snapshot
from ../types/legacy_model import nil
import dod_focus
import dod_outputs
import dod_placement
import dod_runtime
import dod_scratchpad
import dod_window_lifecycle
import dod_window_state
import dod_workspaces

proc externalWindowId(id: legacy_model.WindowId): ExternalWindowId =
  ExternalWindowId(uint32(id))

proc externalOutputId(id: uint32): ExternalOutputId =
  ExternalOutputId(id)

proc legacyWindowId(id: ExternalWindowId): legacy_model.WindowId =
  legacy_model.WindowId(uint32(id))

proc legacyWindowId(model: DodModel; winId: WindowId): legacy_model.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacyWindowId(winOpt.get().externalId)
  0'u32

proc focusedWindowId(snapshot: ShellSnapshot): legacy_model.WindowId =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return workspace.focusedWindow
  for win in snapshot.windows:
    if win.isFocused:
      return win.id
  0'u32

proc activeWorkspace(snapshot: ShellSnapshot): ShellWorkspace =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return workspace
  ShellWorkspace()

proc hasEffect(effects: seq[Effect]; kind: EffectKind): bool =
  for effect in effects:
    if effect.kind == kind:
      return true
  false

proc broadcastWorkspaceActivated(snapshot: ShellSnapshot): Effect =
  let workspace = snapshot.activeWorkspace()
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WorkspaceActivated": {
      "id": workspace.tagId,
      "focused": true
    }
  }))

proc broadcastWindowFocusChanged(winId: legacy_model.WindowId): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowFocusChanged": {
      "id": winId
    }
  }))

proc broadcastWindowOpened(snapshot: ShellSnapshot;
    winId: legacy_model.WindowId): Effect =
  for win in snapshot.windows:
    if win.id == winId:
      return Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
        "WindowOpenedOrChanged": {
          "window": niriWindowJson(snapshot, win)
        }
      }))
  Effect(kind: EffNone)

proc broadcastWindowClosed(winId: legacy_model.WindowId): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowClosed": {
      "id": winId
    }
  }))

proc broadcastWindowsChanged(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowsChanged": {
      "windows": niriWindowsJson(snapshot)
    }
  }))

proc broadcastWorkspacesChanged(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WorkspacesChanged": {
      "workspaces": niriWorkspacesJson(snapshot)
    }
  }))

proc broadcastOutputsChanged(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "OutputsChanged": {
      "outputs": niriOutputsJson(snapshot)
    }
  }))

proc broadcastOverview(open: bool): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "OverviewOpenedOrClosed": {
      "is_open": open
    }
  }))

proc triadLayoutStateChangedEvent(snapshot: ShellSnapshot): string =
  $(%*{
    "triad": {
      "version": TriadIpcVersion,
      "event": "layout-state-changed",
      "state": triadLayoutStateJson(snapshot)
    }
  })

proc triadStateChangedEvent(snapshot: ShellSnapshot): string =
  $(%*{
    "triad": {
      "version": TriadIpcVersion,
      "event": "state-changed",
      "state": triadStateJson(snapshot)
    }
  })

proc broadcastTriadLayoutStateChanged(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffBroadcastTriadJson,
    jsonPayload: triadLayoutStateChangedEvent(snapshot),
    triadEventName: "layout")

proc broadcastTriadStateChanged(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffBroadcastTriadJson,
    jsonPayload: triadStateChangedEvent(snapshot),
    triadEventName: "state")

proc shouldBroadcastWindowsChanged(kind: MsgKind): bool =
  case kind
  of WlWindowCreated,
      WlWindowDestroyed,
      WlFocusChanged,
      WlWindowFullscreenRequested,
      WlWindowExitFullscreenRequested,
      WlWindowMaximizeRequested,
      WlWindowUnmaximizeRequested,
      WlWindowMinimizeRequested,
      WlWindowDimensions,
      WlWindowIdentifier,
      WlWindowAppId,
      WlWindowTitle,
      WlWindowDimensionsHint,
      CmdFocusNext,
      CmdFocusPrev,
      CmdFocusDirection,
      CmdFocusLast,
      CmdFocusTagLeft,
      CmdFocusTagRight,
      CmdFocusOccupiedTagLeft,
      CmdFocusOccupiedTagRight,
      CmdFocusColumnFirst,
      CmdFocusColumnLast,
      CmdFocusWindowOrWorkspaceUp,
      CmdFocusWindowOrWorkspaceDown,
      CmdFocusWorkspaceIndex,
      CmdMoveToTagLeft,
      CmdMoveToTagRight,
      CmdMoveToWorkspaceIndex,
      CmdMoveWindow,
      CmdMoveWindowLeft,
      CmdMoveWindowRight,
      CmdMoveWindowUp,
      CmdMoveWindowDown,
      CmdMoveWindowUpOrToWorkspaceUp,
      CmdMoveWindowDownOrToWorkspaceDown,
      CmdMoveColumnLeft,
      CmdMoveColumnRight,
      CmdMoveColumnToFirst,
      CmdMoveColumnToLast,
      CmdSwapWindowUp,
      CmdSwapWindowDown,
      CmdConsumeWindow,
      CmdExpelWindow,
      CmdMoveToTag,
      CmdSwapWindowToTag,
      CmdMoveToScratchpad,
      CmdMoveToNamedScratchpad,
      CmdToggleScratchpad,
      CmdToggleNamedScratchpad,
      CmdRestoreScratchpad,
      CmdToggleFloating,
      CmdToggleFullscreen,
      CmdToggleMaximized,
      CmdMinimize,
      CmdSelectWindow,
      CmdFocusTag,
      CmdFocusWindowById:
    true
  else:
    false

proc shouldBroadcastOutputsChanged(kind: MsgKind): bool =
  case kind
  of WlOutputDimensions,
      WlOutputName,
      WlOutputPosition,
      WlOutputUsable,
      WlOutputRemoved:
    true
  else:
    false

proc shouldBroadcastTriadLayoutChanged(kind: MsgKind): bool =
  case kind
  of WlWindowCreated,
      WlWindowDestroyed,
      WlWindowDimensions,
      WlWindowFullscreenRequested,
      WlWindowExitFullscreenRequested,
      WlWindowMaximizeRequested,
      WlWindowUnmaximizeRequested,
      WlWindowMinimizeRequested,
      CmdSetLayout,
      CmdSwitchLayout,
      CmdSetMasterCount,
      CmdSetMasterRatio,
      CmdAdjustMasterCount,
      CmdAdjustMasterRatio,
      CmdResizeWidth,
      CmdResizeHeight,
      CmdSetColumnWidth,
      CmdFocusTag,
      CmdFocusWorkspaceIndex,
      CmdMoveToTag,
      CmdMoveToWorkspaceIndex,
      CmdMoveToTagLeft,
      CmdMoveToTagRight,
      CmdMoveWindow,
      CmdMoveWindowLeft,
      CmdMoveWindowRight,
      CmdMoveWindowUp,
      CmdMoveWindowDown,
      CmdMoveWindowUpOrToWorkspaceUp,
      CmdMoveWindowDownOrToWorkspaceDown,
      CmdMoveColumnLeft,
      CmdMoveColumnRight,
      CmdMoveColumnToFirst,
      CmdMoveColumnToLast,
      CmdSwapWindowUp,
      CmdSwapWindowDown,
      CmdConsumeWindow,
      CmdExpelWindow,
      CmdMoveToScratchpad,
      CmdMoveToNamedScratchpad,
      CmdToggleScratchpad,
      CmdToggleNamedScratchpad,
      CmdRestoreScratchpad,
      CmdToggleFloating,
      CmdToggleFullscreen,
      CmdToggleMaximized,
      CmdMinimize,
      CmdSelectWindow:
    true
  else:
    false

proc shouldBroadcastTriadStateChanged(kind: MsgKind): bool =
  kind.shouldBroadcastTriadLayoutChanged() or
    kind.shouldBroadcastWindowsChanged() or
    kind.shouldBroadcastOutputsChanged() or
    kind in {CmdToggleOverview, CmdOpenOverview, CmdCloseOverview}

proc isFocusChangingCommand(kind: MsgKind): bool =
  kind in {
    WlFocusChanged,
    CmdFocusNext,
    CmdFocusPrev,
    CmdFocusDirection,
    CmdFocusLast,
    CmdFocusTagLeft,
    CmdFocusTagRight,
    CmdFocusOccupiedTagLeft,
    CmdFocusOccupiedTagRight,
    CmdFocusColumnFirst,
    CmdFocusColumnLast,
    CmdFocusWindowOrWorkspaceUp,
    CmdFocusWindowOrWorkspaceDown,
    CmdFocusTag,
    CmdFocusWindowById,
    CmdSelectWindow,
    CmdToggleScratchpad,
    CmdToggleNamedScratchpad,
    CmdRestoreScratchpad,
    WlShellSurfaceInteraction
  }

proc closeOverview(model: var DodModel): bool =
  if not model.overviewActive:
    return false
  model.overviewActive = false
  true

proc openOverview(model: var DodModel): bool =
  if model.overviewActive:
    return false
  model.overviewActive = true
  true

proc recomputeAllTagFocus(model: var DodModel) =
  for tagId, _ in model.tagsWithId():
    discard model.recomputeVisibleFocus(tagId)

proc setExternalFocus(model: var DodModel;
    externalId: ExternalWindowId): bool =
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  if externalId == NullExternalWindowId:
    return model.setTagFocus(tagId, NullWindowId)
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or
      model.placementForWindowOnTag(tagId, winId).isNone:
    return false
  discard model.setTagFocus(tagId, winId)
  model.recordWorkspace(tagId)
  model.recordFocus(winId)
  true

proc addSetFullscreenEffect(effects: var seq[Effect];
    winId: legacy_model.WindowId; fullscreen: bool; outputId = 0'u32) =
  effects.add(Effect(
    kind: EffSetFullscreen,
    fsWinId: winId,
    isFullscreen: fullscreen,
    fsOutputId: outputId))

proc addSetMaximizedEffect(effects: var seq[Effect];
    winId: legacy_model.WindowId; maximized: bool) =
  effects.add(Effect(
    kind: EffSetMaximized,
    maxWinId: winId,
    isMaximized: maximized))

proc dodUpdate*(model: DodModel; msg: Msg): (DodModel, seq[Effect]) =
  var next = model
  var effects: seq[Effect] = @[]
  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return (next, effects)

  let before = dodShellSnapshot(model)
  let beforeFocus = before.focusedWindowId()
  var dirty = false

  case msg.kind
  of WlManageStart:
    let focused = next.focusedWindow()
    if focused != NullWindowId:
      next.recordWorkspace(next.activeTag)
      next.recordFocus(focused)
      let externalId = next.legacyWindowId(focused)
      effects.add(broadcastWindowFocusChanged(externalId))
      if not next.sessionLocked and not next.layerFocusExclusive:
        effects.add(Effect(kind: EffFocusWindow, focusId: externalId))
    dirty = true

  of WlOutputDimensions:
    dirty = next.setOutputDimensionsForExternal(
      msg.outputId.externalOutputId(), msg.width, msg.height)
  of WlOutputName:
    dirty = next.setOutputNameForExternal(
      msg.nameOutputId.externalOutputId(), msg.outputName)
  of WlOutputPosition:
    dirty = next.setOutputPositionForExternal(
      msg.positionOutputId.externalOutputId(), msg.outputX, msg.outputY)
  of WlOutputUsable:
    dirty = next.setOutputUsableForExternal(
      msg.usableOutputId.externalOutputId(),
      msg.usableX,
      msg.usableY,
      msg.usableW,
      msg.usableH)
  of WlOutputRemoved:
    for winId in next.removeOutputForExternal(msg.removedOutputId.externalOutputId()):
      dirty = true
      effects.addSetFullscreenEffect(next.legacyWindowId(winId), false)

  of WlWindowCreated:
    let winId = next.createWindowForExternal(
      msg.windowId.externalWindowId(),
      msg.appId,
      msg.title,
      msg.createdIdentifier)
    dirty = winId != NullWindowId
    if dirty:
      let win = next.windowData(winId).get()
      if win.isFullscreen:
        effects.addSetFullscreenEffect(
          msg.windowId, true, uint32(win.fullscreenOutput))
      if win.isMaximized:
        effects.addSetMaximizedEffect(msg.windowId, true)

  of WlWindowDestroyed:
    dirty = next.destroyWindowForExternal(msg.destroyedId.externalWindowId())
    if dirty:
      effects.add(broadcastWindowClosed(msg.destroyedId))

  of WlWindowDimensions:
    dirty = next.updateWindowDimensionsForExternal(
      msg.dimensionsWindowId.externalWindowId(),
      msg.actualWidth,
      msg.actualHeight)
  of WlWindowDecorationHint:
    dirty = next.updateWindowDecorationHintForExternal(
      msg.decorationWindowId.externalWindowId(), msg.decorationHint)
  of WlWindowPresentationHint:
    dirty = next.updateWindowPresentationHintForExternal(
      msg.presentationWindowId.externalWindowId(), msg.presentationHint)
  of WlWindowParent:
    dirty = next.updateWindowParentForExternal(
      msg.childWindowId.externalWindowId(),
      msg.parentWindowId.externalWindowId())
  of WlWindowIdentifier:
    dirty = next.updateWindowIdentifierAndRestoreForExternal(
      msg.identifierWindowId.externalWindowId(), msg.identifier)
  of WlWindowAppId:
    dirty = next.updateWindowAppIdForExternal(
      msg.appIdWindowId.externalWindowId(), msg.updatedAppId)
  of WlWindowTitle:
    dirty = next.updateWindowTitleForExternal(
      msg.titleWindowId.externalWindowId(), msg.updatedTitle)
  of WlWindowDimensionsHint:
    dirty = next.updateWindowDimensionsHintForExternal(
      msg.hintWindowId.externalWindowId(),
      msg.minWidth,
      msg.minHeight,
      msg.maxWidth,
      msg.maxHeight)

  of WlWindowMenuRequested:
    if next.windowMenuCommand.len > 0 and
        next.windowForExternal(msg.menuWindowId.externalWindowId()) !=
        NullWindowId:
      effects.add(Effect(
        kind: EffSpawnWindowMenu,
        windowMenuCommand: next.windowMenuCommand,
        windowMenuId: msg.menuWindowId,
        windowMenuX: msg.menuX,
        windowMenuY: msg.menuY))
  of WlShellSurfaceInteraction:
    if msg.shellSurfaceId != 0 and not next.sessionLocked and
        not next.layerFocusExclusive:
      effects.add(Effect(
        kind: EffFocusShellSurface,
        focusShellSurfaceId: msg.shellSurfaceId))
  of WlModifiersChanged:
    discard next.setActiveModifiers(msg.newModifiers)
  of WlLayerFocusExclusive:
    dirty = next.setLayerFocusExclusive(true)
  of WlLayerFocusNonExclusive, WlLayerFocusNone:
    dirty = next.setLayerFocusExclusive(false)
  of WlSessionLocked:
    dirty = next.setSessionLocked(true)
  of WlSessionUnlocked:
    dirty = next.setSessionLocked(false)
    let focused = next.focusedWindow()
    if focused != NullWindowId:
      let externalId = next.legacyWindowId(focused)
      effects.add(broadcastWindowFocusChanged(externalId))
      effects.add(Effect(kind: EffFocusWindow, focusId: externalId))
  of WlPointerMoveRequested:
    if next.beginPointerMove(msg.moveWinId.externalWindowId()):
      effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.moveSeat))
  of WlPointerResizeRequested:
    if next.beginPointerResize(
        msg.resizeWinId.externalWindowId(), msg.resizeEdges):
      effects.add(Effect(
        kind: EffInformResizeStart,
        resizeLifecycleWinId: msg.resizeWinId))
      effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.resizeSeat))
  of WlPointerDelta:
    dirty = next.applyPointerDelta(msg.dx, msg.dy)
  of WlPointerRelease:
    let resized = next.finishPointerOp()
    if resized != NullWindowId:
      effects.add(Effect(
        kind: EffInformResizeEnd,
        resizeLifecycleWinId: next.legacyWindowId(resized)))

  of WlFocusChanged:
    dirty = next.setExternalFocus(msg.newFocusedId.externalWindowId())
  of WlWindowFullscreenRequested:
    dirty = next.requestFullscreenForExternal(
      msg.fullscreenRequestId.externalWindowId(),
      msg.fullscreenOutputId.externalOutputId())
    if dirty:
      let winId = next.windowForExternal(msg.fullscreenRequestId.externalWindowId())
      let win = next.windowData(winId).get()
      effects.addSetFullscreenEffect(
        msg.fullscreenRequestId, true, uint32(win.fullscreenOutput))
  of WlWindowExitFullscreenRequested:
    dirty = next.exitFullscreenForExternal(
      msg.exitFullscreenRequestId.externalWindowId())
    if dirty:
      effects.addSetFullscreenEffect(msg.exitFullscreenRequestId, false)
  of WlWindowMaximizeRequested:
    dirty = next.requestMaximizeForExternal(
      msg.maximizeRequestId.externalWindowId())
    if dirty:
      effects.addSetMaximizedEffect(msg.maximizeRequestId, true)
  of WlWindowUnmaximizeRequested:
    dirty = next.requestUnmaximizeForExternal(
      msg.unmaximizeRequestId.externalWindowId())
    if dirty:
      effects.addSetMaximizedEffect(msg.unmaximizeRequestId, false)
  of WlWindowMinimizeRequested:
    dirty = next.requestMinimizeForExternal(
      msg.minimizeRequestId.externalWindowId())
    if dirty:
      effects.addSetMaximizedEffect(msg.minimizeRequestId, false)

  of CmdSetLayout:
    dirty = next.setLayoutForSlot(msg.layoutTargetTag, msg.newLayout)
  of CmdSwitchLayout:
    dirty = next.switchLayout()
  of CmdSetMasterCount:
    dirty = next.setMasterCount(msg.count)
  of CmdAdjustMasterCount:
    dirty = next.adjustMasterCount(msg.deltaMC)
  of CmdSetMasterRatio:
    dirty = next.setMasterRatio(msg.ratio)
  of CmdAdjustMasterRatio:
    dirty = next.adjustMasterRatio(msg.deltaMR)
  of CmdResizeWidth:
    dirty = next.resizeWidth(msg.deltaW)
  of CmdResizeHeight:
    dirty = next.resizeHeight(msg.deltaH)
  of CmdSetColumnWidth:
    dirty = next.setFocusedColumnWidth(msg.targetWidth)

  of CmdRenameTag:
    dirty = next.renameActiveWorkspace(msg.newName)
    if dirty:
      effects.add(broadcastWorkspaceActivated(dodShellSnapshot(next)))
  of CmdGroupWindows:
    dirty = next.groupFocusedWindow()
  of CmdUngroupWindow, CmdFocusNextInGroup:
    dirty = true

  of CmdFocusNext:
    dirty = next.focusCycle(1)
  of CmdFocusPrev:
    dirty = next.focusCycle(-1)
  of CmdFocusDirection:
    dirty = next.focusByDirection(msg.direction)
  of CmdFocusLast:
    dirty = next.focusLast()
  of CmdFocusTagLeft:
    dirty = next.focusWorkspaceSlot(next.nearestWorkspaceSlot(-1, false))
  of CmdFocusTagRight:
    dirty = next.focusWorkspaceSlot(next.nearestWorkspaceSlot(1, false))
  of CmdFocusOccupiedTagLeft:
    dirty = next.focusWorkspaceSlot(next.nearestWorkspaceSlot(-1, true))
  of CmdFocusOccupiedTagRight:
    dirty = next.focusWorkspaceSlot(next.nearestWorkspaceSlot(1, true))
  of CmdFocusColumnFirst:
    dirty = next.focusColumnAtEdge(true)
  of CmdFocusColumnLast:
    dirty = next.focusColumnAtEdge(false)
  of CmdFocusWindowOrWorkspaceUp:
    dirty = next.focusWindowOrWorkspace(-1)
  of CmdFocusWindowOrWorkspaceDown:
    dirty = next.focusWindowOrWorkspace(1)
  of CmdFocusTag:
    dirty = next.focusWorkspaceSlot(msg.focusTag)
  of CmdFocusWorkspaceIndex:
    dirty = next.focusWorkspaceIndex(msg.workspaceIndex)
  of CmdFocusWindowById:
    dirty = next.focusExternalWindow(msg.focusWindowId.externalWindowId())

  of CmdMoveToTag:
    dirty = next.moveFocusedWindowToSlot(msg.targetTag)
  of CmdSwapWindowToTag:
    dirty = next.swapFocusedWindowToSlot(msg.targetTagSwap)
  of CmdMoveToTagLeft:
    dirty = next.moveFocusedWindowToSlot(
      next.nearestWorkspaceSlot(-1, false))
  of CmdMoveToTagRight:
    dirty = next.moveFocusedWindowToSlot(
      next.nearestWorkspaceSlot(1, false))
  of CmdMoveToWorkspaceIndex:
    let slot = next.workspaceSlotForClampedIndex(msg.workspaceIndex)
    dirty = slot != 0 and next.moveFocusedWindowToSlot(slot)
  of CmdMoveWindowLeft:
    dirty = next.moveFocusedWindowLeft()
  of CmdMoveWindowRight:
    dirty = next.moveFocusedWindowRight()
  of CmdMoveWindowUp:
    dirty = next.moveFocusedWindowUp()
  of CmdMoveWindowDown:
    dirty = next.moveFocusedWindowDown()
  of CmdMoveWindowUpOrToWorkspaceUp:
    dirty = next.moveFocusedWindowUpOrWorkspace()
  of CmdMoveWindowDownOrToWorkspaceDown:
    dirty = next.moveFocusedWindowDownOrWorkspace()
  of CmdMoveColumnLeft:
    dirty = next.moveFocusedColumnLeft()
  of CmdMoveColumnRight:
    dirty = next.moveFocusedColumnRight()
  of CmdMoveColumnToFirst:
    dirty = next.moveFocusedColumnToFirst()
  of CmdMoveColumnToLast:
    dirty = next.moveFocusedColumnToLast()
  of CmdSwapWindowUp:
    dirty = next.moveFocusedWindowUp()
  of CmdSwapWindowDown:
    dirty = next.moveFocusedWindowDown()
  of CmdConsumeWindow:
    dirty = next.consumeNextColumnWindow()
  of CmdExpelWindow:
    dirty = next.expelFocusedWindow()
  of CmdZoom:
    dirty = next.zoomFocusedWindow()

  of CmdMoveToScratchpad:
    dirty = next.moveFocusedToScratchpad()
  of CmdMoveToNamedScratchpad:
    dirty = next.moveFocusedToScratchpad(msg.scratchpadName)
  of CmdToggleScratchpad:
    dirty = next.toggleScratchpad()
  of CmdToggleNamedScratchpad:
    dirty = next.toggleNamedScratchpad(msg.scratchpadName)
  of CmdRestoreScratchpad:
    dirty = next.restoreScratchpad()

  of CmdToggleOverview:
    if next.overviewActive:
      dirty = next.closeOverview()
      if dirty:
        next.recomputeAllTagFocus()
        effects.add(broadcastOverview(false))
    else:
      dirty = next.openOverview()
      if dirty:
        effects.add(broadcastOverview(true))
        effects.add(Effect(kind: EffFocusShellUi))
  of CmdOpenOverview:
    dirty = next.openOverview()
    if dirty:
      effects.add(broadcastOverview(true))
      effects.add(Effect(kind: EffFocusShellUi))
  of CmdCloseOverview:
    dirty = next.closeOverview()
    if dirty:
      next.recomputeAllTagFocus()
      effects.add(broadcastOverview(false))

  of CmdToggleFloating:
    dirty = next.toggleFloatingFocused()
  of CmdMoveFloating:
    dirty = next.moveFloatingFocused(msg.moveDX, msg.moveDY)
  of CmdResizeFloating:
    dirty = next.resizeFloatingFocused(msg.deltaFW, msg.deltaFH)
  of CmdAdjustGaps:
    dirty = next.adjustGaps(msg.deltaG)
  of CmdToggleGaps:
    dirty = next.toggleGaps()
  of CmdToggleFullscreen:
    let focused = next.focusedWindow()
    dirty = next.toggleFullscreenFocused()
    if dirty:
      let win = next.windowData(focused).get()
      effects.addSetFullscreenEffect(
        next.legacyWindowId(focused), win.isFullscreen,
        uint32(win.fullscreenOutput))
  of CmdToggleMaximized:
    let focused = next.focusedWindow()
    dirty = next.toggleMaximizedFocused()
    if dirty:
      let win = next.windowData(focused).get()
      effects.addSetMaximizedEffect(
        next.legacyWindowId(focused), win.isMaximized)
  of CmdMinimize:
    let focused = next.focusedWindow()
    dirty = next.minimizeFocused()
    if dirty:
      effects.addSetMaximizedEffect(next.legacyWindowId(focused), false)
  of CmdToggleKeyboardShortcutsInhibit:
    dirty = next.toggleKeyboardShortcutsInhibitFocused()
  of CmdSelectWindow:
    dirty = next.closeOverview()
    if dirty:
      next.recomputeAllTagFocus()
  of CmdCloseWindow:
    let focused = next.focusedWindow()
    if focused != NullWindowId:
      effects.add(Effect(
        kind: EffCloseWindow,
        closeId: next.legacyWindowId(focused)))
  of CmdCloseWindowById:
    if next.windowForExternal(msg.closeWindowId.externalWindowId()) !=
        NullWindowId:
      effects.add(Effect(kind: EffCloseWindow, closeId: msg.closeWindowId))
  of CmdSpawn:
    if msg.spawnCommand.len > 0:
      effects.add(Effect(kind: EffSpawn, spawnCommand: msg.spawnCommand))
  of CmdTick:
    dirty = next.tickAnimations()
  of CmdLockSession:
    if next.screenLockCommand.len > 0:
      effects.add(Effect(
        kind: EffSpawnScreenLock,
        screenLockCommand: next.screenLockCommand))
    else:
      effects.add(Effect(
        kind: EffLog,
        msg: "screen lock command is not configured"))
  of CmdWarpPointer:
    effects.add(Effect(
      kind: EffPointerWarp,
      warpX: msg.warpX,
      warpY: msg.warpY))
  of CmdEatNextKey:
    effects.add(Effect(kind: EffEnsureNextKeyEaten))
  of CmdCancelEatNextKey:
    effects.add(Effect(kind: EffCancelEnsureNextKeyEaten))
  of CmdStopManager:
    effects.add(Effect(kind: EffStopManager))
  of CmdTriadReload:
    effects.add(Effect(kind: EffTriadReload))
  of CmdExitSession:
    if next.allowExitSession:
      effects.add(Effect(kind: EffExitSession))
    else:
      effects.add(Effect(
        kind: EffLog,
        msg: "exit-session is disabled by config"))
  of CmdFocusShellUi:
    if not next.sessionLocked and not next.layerFocusExclusive:
      effects.add(Effect(kind: EffFocusShellUi))
  of CmdScreenshot:
    effects.add(Effect(
      kind: EffScreenshot,
      screenshotKind: msg.screenshotKind,
      screenshotPath: msg.screenshotPath,
      screenshotShowPointer: msg.screenshotShowPointer))
  of CmdConfigReload, CmdSpawnTerminal:
    dirty = true

  else:
    discard

  let collapsed =
    if msg.kind in {
        WlWindowDestroyed,
        CmdMoveToTag,
        CmdMoveWindowUpOrToWorkspaceUp,
        CmdMoveWindowDownOrToWorkspaceDown,
        CmdMoveToWorkspaceIndex,
        CmdMoveToScratchpad,
        CmdMoveToNamedScratchpad,
        CmdToggleNamedScratchpad}:
      next.collapseEmptyActiveDynamicWorkspace()
    else:
      false
  let pruned = next.pruneDynamicWorkspaces()
  if collapsed or pruned:
    dirty = true
  next.refreshVisibleWorkspaceSlots()

  let after = dodShellSnapshot(next)
  let afterFocus = after.focusedWindowId()

  if before.activeTag != after.activeTag and after.activeTag != 0:
    effects.add(broadcastWorkspaceActivated(after))
  if beforeFocus != afterFocus:
    effects.add(broadcastWindowFocusChanged(afterFocus))
    if afterFocus != 0:
      effects.add(Effect(kind: EffFocusWindow, focusId: afterFocus))
  elif msg.kind in {CmdCloseOverview, CmdSelectWindow} and afterFocus != 0:
    effects.add(Effect(kind: EffFocusWindow, focusId: afterFocus))

  if msg.kind in {WlWindowCreated, WlWindowAppId, WlWindowTitle}:
    let openedId =
      case msg.kind
      of WlWindowCreated: msg.windowId
      of WlWindowAppId: msg.appIdWindowId
      of WlWindowTitle: msg.titleWindowId
      else: 0'u32
    let effect = after.broadcastWindowOpened(openedId)
    if effect.kind != EffNone:
      effects.add(effect)

  if dirty and not effects.hasEffect(EffManageDirty):
    effects.add(Effect(kind: EffManageDirty))

  if dirty or collapsed or pruned:
    if msg.kind.shouldBroadcastOutputsChanged():
      effects.add(after.broadcastOutputsChanged())
      effects.add(after.broadcastWorkspacesChanged())
      effects.add(after.broadcastWindowsChanged())
    elif msg.kind.shouldBroadcastWindowsChanged():
      effects.add(after.broadcastWorkspacesChanged())
      effects.add(after.broadcastWindowsChanged())
    elif collapsed or pruned:
      effects.add(after.broadcastWorkspacesChanged())

    if msg.kind.shouldBroadcastTriadLayoutChanged() or collapsed or pruned:
      effects.add(after.broadcastTriadLayoutStateChanged())
    if msg.kind.shouldBroadcastTriadStateChanged() or collapsed or pruned:
      effects.add(after.broadcastTriadStateChanged())

  (next, effects)
