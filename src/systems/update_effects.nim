import std/[json, options]
import ../core/[effects, msg, niri_state, shell_focus, triad_state]
import ../state/engine
import ../types/shell_snapshot
import ../types/system_views
import idle_inhibit, presentation_policy

export system_views

proc externalWindowId*(id: uint32): ExternalWindowId =
  ExternalWindowId(uint32(id))

proc externalOutputId*(id: uint32): ExternalOutputId =
  ExternalOutputId(id)

proc runtimeWindowId*(id: ExternalWindowId): uint32 =
  uint32(uint32(id))

proc runtimeWindowId*(model: Model, winId: WindowId): uint32 =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return runtimeWindowId(winOpt.get().externalId)
  0'u32

proc activeWorkspace(snapshot: ShellSnapshot): ShellWorkspace =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return workspace
  ShellWorkspace()

proc hasEffect*(effects: seq[Effect], kind: EffectKind): bool =
  for effect in effects:
    if effect.kind == kind:
      return true
  false

proc broadcastWorkspaceActivated*(snapshot: ShellSnapshot): Effect =
  let workspace = snapshot.activeWorkspace()
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"WorkspaceActivated": {"id": workspace.tagId, "focused": true}}),
  )

proc broadcastWorkspaceActiveWindowChanged*(workspace: ShellWorkspace): Effect =
  let activeWindow =
    if workspace.focusedWindow == 0:
      newJNull()
    else:
      %workspace.focusedWindow
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload:
      $(
        %*{
          "WorkspaceActiveWindowChanged":
            {"workspace_id": workspace.tagId, "active_window_id": activeWindow}
        }
      ),
  )

proc broadcastWindowFocusChanged*(winId: uint32): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"WindowFocusChanged": {"id": winId}}),
  )

proc broadcastWindowOpened*(snapshot: ShellSnapshot, winId: uint32): Effect =
  for win in snapshot.windows:
    if win.id == winId:
      return Effect(
        kind: EffectKind.EffBroadcastJson,
        jsonPayload:
          $(%*{"WindowOpenedOrChanged": {"window": niriWindowJson(snapshot, win)}}),
      )
  Effect(kind: EffectKind.EffNone)

proc broadcastWindowClosed*(winId: uint32): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{"WindowClosed": {"id": winId}})
  )

proc broadcastWindowsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"WindowsChanged": {"windows": niriWindowsJson(snapshot)}}),
  )

proc broadcastWorkspacesChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload:
      $(%*{"WorkspacesChanged": {"workspaces": niriWorkspacesJson(snapshot)}}),
  )

proc broadcastOutputsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"OutputsChanged": {"outputs": niriOutputsJson(snapshot)}}),
  )

proc broadcastKeyboardLayoutsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload:
      $(
        %*{
          "KeyboardLayoutsChanged":
            {"keyboard_layouts": niriKeyboardLayoutsJson(snapshot)}
        }
      ),
  )

proc broadcastKeyboardLayoutSwitched*(index: uint32): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"KeyboardLayoutSwitched": {"idx": index}}),
  )

proc broadcastOverview*(open: bool): Effect =
  Effect(
    kind: EffectKind.EffBroadcastJson,
    jsonPayload: $(%*{"OverviewOpenedOrClosed": {"is_open": open}}),
  )

proc broadcastTriadLayoutStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastTriadJson,
    jsonPayload: triadLayoutStateChangedEvent(snapshot),
    triadEventName: "layout",
  )

proc broadcastTriadStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastTriadJson,
    jsonPayload: triadStateChangedEvent(snapshot),
    triadEventName: "state",
  )

proc broadcastTriadWindowChanged*(snapshot: ShellSnapshot, winId: uint32): Effect =
  let win = snapshot.windowById(winId)
  if win.isNone:
    return Effect(kind: EffectKind.EffNone)
  Effect(
    kind: EffectKind.EffBroadcastTriadJson,
    jsonPayload: triadWindowChangedEvent(win.get()),
    triadEventName: "window",
  )

proc broadcastWindowChanged*(winId: uint32, niri = true): Effect =
  Effect(
    kind: EffectKind.EffBroadcastWindowChanged,
    broadcastWindowId: winId,
    broadcastNiriWindowChanged: niri,
  )

proc renderDirty*(reason: string): Effect =
  Effect(kind: EffectKind.EffRenderDirty, renderDirtyReason: reason)

proc shouldBroadcastWindowsChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlWindowCreated, MsgKind.WlWindowDestroyed, MsgKind.WlFocusChanged,
      MsgKind.WlWindowFullscreenRequested, MsgKind.WlWindowExitFullscreenRequested,
      MsgKind.WlWindowParent, MsgKind.WlWindowMaximizeRequested,
      MsgKind.WlWindowUnmaximizeRequested, MsgKind.WlWindowMinimizeRequested,
      MsgKind.WlWindowIdentifier, MsgKind.WlWindowAppId, MsgKind.WlWindowTitle,
      MsgKind.WlWindowDimensionsHint, MsgKind.CmdFocusNext, MsgKind.CmdFocusPrev,
      MsgKind.CmdFocusDirection, MsgKind.CmdFocusLast, MsgKind.CmdFocusTagLeft,
      MsgKind.CmdFocusTagRight, MsgKind.CmdFocusOccupiedTagLeft,
      MsgKind.CmdFocusOccupiedTagRight, MsgKind.CmdFocusColumnFirst,
      MsgKind.CmdFocusColumnLast, MsgKind.CmdFocusWindowOrWorkspaceUp,
      MsgKind.CmdFocusWindowOrWorkspaceDown, MsgKind.CmdFocusWorkspaceIndex,
      MsgKind.CmdNewWorkspace, MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight,
      MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowToWorkspaceIndex,
      MsgKind.CmdMoveWindow, MsgKind.CmdMoveWindowLeft, MsgKind.CmdMoveWindowRight,
      MsgKind.CmdMoveWindowUp, MsgKind.CmdMoveWindowDown,
      MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
      MsgKind.CmdMoveWindowDownOrToWorkspaceDown, MsgKind.CmdMoveColumnLeft,
      MsgKind.CmdMoveColumnRight, MsgKind.CmdMoveColumnToFirst,
      MsgKind.CmdMoveColumnToLast, MsgKind.CmdSwapWindowUp, MsgKind.CmdSwapWindowDown,
      MsgKind.CmdConsumeWindow, MsgKind.CmdExpelWindow, MsgKind.CmdMoveToTag,
      MsgKind.CmdMoveWindowToTag, MsgKind.CmdSwapWindowToTag,
      MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
      MsgKind.CmdToggleScratchpad, MsgKind.CmdToggleNamedScratchpad,
      MsgKind.CmdRestoreScratchpad, MsgKind.CmdToggleFloating,
      MsgKind.CmdSetWindowFloatingById, MsgKind.CmdSetWindowMaximizedById,
      MsgKind.CmdToggleFullscreen, MsgKind.CmdToggleFullscreenById,
      MsgKind.CmdExitFullscreenById, MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize,
      MsgKind.CmdSelectWindow, MsgKind.CmdRecentWindowConfirm, MsgKind.CmdFocusTag,
      MsgKind.CmdFocusWindowById:
    true
  else:
    false

proc shouldBroadcastNiriWindowsChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlWindowDestroyed, MsgKind.WlWindowParent,
      MsgKind.WlWindowFullscreenRequested, MsgKind.WlWindowExitFullscreenRequested,
      MsgKind.WlWindowMaximizeRequested, MsgKind.WlWindowUnmaximizeRequested,
      MsgKind.WlWindowMinimizeRequested, MsgKind.CmdMoveToTagLeft,
      MsgKind.CmdMoveToTagRight, MsgKind.CmdMoveToWorkspaceIndex,
      MsgKind.CmdMoveWindowToWorkspaceIndex, MsgKind.CmdMoveWindow,
      MsgKind.CmdMoveWindowLeft, MsgKind.CmdMoveWindowRight, MsgKind.CmdMoveWindowUp,
      MsgKind.CmdMoveWindowDown, MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
      MsgKind.CmdMoveWindowDownOrToWorkspaceDown, MsgKind.CmdMoveColumnLeft,
      MsgKind.CmdMoveColumnRight, MsgKind.CmdMoveColumnToFirst,
      MsgKind.CmdMoveColumnToLast, MsgKind.CmdSwapWindowUp, MsgKind.CmdSwapWindowDown,
      MsgKind.CmdConsumeWindow, MsgKind.CmdExpelWindow, MsgKind.CmdMoveToTag,
      MsgKind.CmdMoveWindowToTag, MsgKind.CmdSwapWindowToTag,
      MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
      MsgKind.CmdToggleScratchpad, MsgKind.CmdToggleNamedScratchpad,
      MsgKind.CmdRestoreScratchpad, MsgKind.CmdToggleFloating,
      MsgKind.CmdSetWindowFloatingById, MsgKind.CmdSetWindowMaximizedById,
      MsgKind.CmdToggleFullscreen, MsgKind.CmdToggleFullscreenById,
      MsgKind.CmdExitFullscreenById, MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize:
    true
  else:
    false

proc shouldBroadcastOutputsChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlOutputDimensions, MsgKind.WlOutputName, MsgKind.WlOutputPosition,
      MsgKind.WlOutputRefreshRate, MsgKind.WlOutputPhysicalMetadata,
      MsgKind.WlOutputScale, MsgKind.WlOutputUsable, MsgKind.WlOutputRemoved:
    true
  else:
    false

proc shouldBroadcastTriadLayoutChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlWindowCreated, MsgKind.WlWindowDestroyed, MsgKind.WlWindowDimensionsHint,
      MsgKind.WlWindowParent, MsgKind.WlWindowFullscreenRequested,
      MsgKind.WlWindowExitFullscreenRequested, MsgKind.WlWindowMaximizeRequested,
      MsgKind.WlWindowUnmaximizeRequested, MsgKind.WlWindowMinimizeRequested,
      MsgKind.CmdSetLayout, MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout,
      MsgKind.CmdSetMasterCount, MsgKind.CmdSetMasterRatio,
      MsgKind.CmdAdjustMasterCount, MsgKind.CmdAdjustMasterRatio,
      MsgKind.CmdMaximizeColumn, MsgKind.CmdResizeWidth, MsgKind.CmdResizeHeight,
      MsgKind.CmdSetColumnWidth, MsgKind.CmdSwitchProportionPreset, MsgKind.CmdFocusTag,
      MsgKind.CmdBspPreselect, MsgKind.CmdBspPreselectCancel,
      MsgKind.CmdBspPreselectRatio, MsgKind.CmdFocusWorkspaceIndex,
      MsgKind.CmdNewWorkspace, MsgKind.CmdMoveToTag, MsgKind.CmdMoveWindowToTag,
      MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowToWorkspaceIndex,
      MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight, MsgKind.CmdMoveWindow,
      MsgKind.CmdMoveWindowLeft, MsgKind.CmdMoveWindowRight, MsgKind.CmdMoveWindowUp,
      MsgKind.CmdMoveWindowDown, MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
      MsgKind.CmdMoveWindowDownOrToWorkspaceDown, MsgKind.CmdMoveColumnLeft,
      MsgKind.CmdMoveColumnRight, MsgKind.CmdMoveColumnToFirst,
      MsgKind.CmdMoveColumnToLast, MsgKind.CmdSwapWindowUp, MsgKind.CmdSwapWindowDown,
      MsgKind.CmdConsumeWindow, MsgKind.CmdExpelWindow, MsgKind.CmdMoveToScratchpad,
      MsgKind.CmdMoveToNamedScratchpad, MsgKind.CmdToggleScratchpad,
      MsgKind.CmdToggleNamedScratchpad, MsgKind.CmdRestoreScratchpad,
      MsgKind.CmdToggleFloating, MsgKind.CmdSetWindowFloatingById,
      MsgKind.CmdSetWindowMaximizedById, MsgKind.CmdToggleFullscreen,
      MsgKind.CmdToggleFullscreenById, MsgKind.CmdExitFullscreenById,
      MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize, MsgKind.CmdSelectWindow:
    true
  else:
    false

proc shouldBroadcastTriadStateChanged*(kind: MsgKind): bool =
  if kind in {MsgKind.WlWindowTitle, MsgKind.WlWindowDimensions}:
    return false
  kind.shouldBroadcastTriadLayoutChanged() or kind.shouldBroadcastWindowsChanged() or
    kind.shouldBroadcastOutputsChanged() or
    kind in {
      MsgKind.CmdToggleOverview, MsgKind.CmdOpenOverview, MsgKind.CmdCloseOverview,
      MsgKind.CmdOverviewTab,
    }

proc workspaceByTag(snapshot: ShellSnapshot, tagId: uint32): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == tagId:
      return some(workspace)
  none(ShellWorkspace)

proc workspaceSnapshotChanged*(before, after: ShellSnapshot): bool =
  if before.workspaces.len != after.workspaces.len:
    return true

  for workspace in before.workspaces:
    if after.workspaceByTag(workspace.tagId).isNone:
      return true

  for workspace in after.workspaces:
    let beforeWorkspace = before.workspaceByTag(workspace.tagId)
    if beforeWorkspace.isNone:
      return true
    let previous = beforeWorkspace.get()
    if previous.workspaceIdx != workspace.workspaceIdx or previous.name != workspace.name or
        previous.outputName != workspace.outputName or
        previous.isActive != workspace.isActive or
        previous.occupied != workspace.occupied:
      return true

  false

proc isFocusChangingCommand*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlFocusChanged, MsgKind.CmdFocusNext, MsgKind.CmdFocusPrev,
    MsgKind.CmdFocusDirection, MsgKind.CmdFocusLast, MsgKind.CmdFocusTagLeft,
    MsgKind.CmdFocusTagRight, MsgKind.CmdFocusOccupiedTagLeft,
    MsgKind.CmdFocusOccupiedTagRight, MsgKind.CmdFocusColumnFirst,
    MsgKind.CmdFocusColumnLast, MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown, MsgKind.CmdFocusTag,
    MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdNewWorkspace, MsgKind.CmdFocusWindowById,
    MsgKind.CmdSelectWindow, MsgKind.CmdRecentWindowConfirm,
    MsgKind.CmdToggleScratchpad, MsgKind.CmdToggleNamedScratchpad,
    MsgKind.CmdRestoreScratchpad, MsgKind.WlShellSurfaceInteraction,
  }

proc shouldCollapseAfterUpdate*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowDestroyed, MsgKind.CmdMoveToTag, MsgKind.CmdMoveWindowToTag,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp, MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowToWorkspaceIndex,
    MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
    MsgKind.CmdToggleNamedScratchpad,
  }

proc isOverviewPreviewCommand(kind: MsgKind): bool =
  kind in {
    MsgKind.CmdFocusNext, MsgKind.CmdFocusPrev, MsgKind.CmdFocusDirection,
    MsgKind.CmdFocusWindowById, MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown, MsgKind.CmdOverviewTab,
    MsgKind.WlOverviewWheel,
  }

proc isFocusPreservingLayoutCommand(kind: MsgKind): bool =
  kind in {
    MsgKind.CmdMoveWindow, MsgKind.CmdMoveWindowLeft, MsgKind.CmdMoveWindowRight,
    MsgKind.CmdMoveWindowUp, MsgKind.CmdMoveWindowDown,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp, MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdMoveColumnLeft, MsgKind.CmdMoveColumnRight, MsgKind.CmdMoveColumnToFirst,
    MsgKind.CmdMoveColumnToLast, MsgKind.CmdSwapWindowUp, MsgKind.CmdSwapWindowDown,
    MsgKind.CmdConsumeWindow, MsgKind.CmdExpelWindow, MsgKind.CmdZoom,
  }

proc shouldReassertFocusedWindow(kind: MsgKind, before, after: ShellSnapshot): bool =
  if after.focusedWindowId() == 0 or after.overviewActive:
    return false
  if kind in {MsgKind.CmdFocusTag, MsgKind.CmdFocusWorkspaceIndex}:
    return true
  if kind in {
    MsgKind.CmdMoveToTag, MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight,
    MsgKind.CmdMoveToWorkspaceIndex,
  }:
    return before.activeTag != after.activeTag
  if kind in {MsgKind.CmdSetLayout, MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout}:
    return before.activeWorkspace().layoutId != after.activeWorkspace().layoutId
  false

proc addSetFullscreenEffect*(
    effects: var seq[Effect], winId: uint32, fullscreen: bool, outputId = 0'u32
) =
  effects.add(
    Effect(
      kind: EffectKind.EffSetFullscreen,
      fsWinId: winId,
      isFullscreen: fullscreen,
      fsOutputId: outputId,
    )
  )

proc addSetMaximizedEffect*(effects: var seq[Effect], winId: uint32, maximized: bool) =
  effects.add(
    Effect(kind: EffectKind.EffSetMaximized, maxWinId: winId, isMaximized: maximized)
  )

proc hasFullscreenEffect(effects: seq[Effect], winId: uint32, fullscreen: bool): bool =
  for effect in effects:
    if effect.kind == EffectKind.EffSetFullscreen and effect.fsWinId == winId and
        effect.isFullscreen == fullscreen:
      return true

proc hasMaximizedEffect(effects: seq[Effect], winId: uint32, maximized: bool): bool =
  for effect in effects:
    if effect.kind == EffectKind.EffSetMaximized and effect.maxWinId == winId and
        effect.isMaximized == maximized:
      return true

proc addFullscreenPresentationEffect(
    effects: var seq[Effect], win: ShellWindow, present: bool
) =
  if effects.hasFullscreenEffect(win.id, present):
    return
  effects.addSetFullscreenEffect(
    win.id, present, if present: win.fullscreenOutput else: 0'u32
  )

proc addMaximizedPresentationEffect(
    effects: var seq[Effect], win: ShellWindow, present: bool
) =
  if effects.hasMaximizedEffect(win.id, present):
    return
  effects.addSetMaximizedEffect(win.id, present)

proc shouldRequestManageDirty(kind: MsgKind): bool =
  kind notin {MsgKind.WlWindowTitle, MsgKind.WlWindowDimensions}

proc fullscreenWindow(snapshot: ShellSnapshot, winId: uint32): Option[ShellWindow] =
  let win = snapshot.windowById(winId)
  if win.isSome and win.get().isFullscreen:
    return win
  none(ShellWindow)

proc maximizedWindow(snapshot: ShellSnapshot, winId: uint32): Option[ShellWindow] =
  let win = snapshot.windowById(winId)
  if win.isSome and win.get().isMaximized:
    return win
  none(ShellWindow)

proc shouldSyncFullscreenPresentation(
    kind: MsgKind, before, after: ShellSnapshot
): bool =
  if before.focusedWindowId() != after.focusedWindowId() or
      before.activeTag != after.activeTag or
      before.overviewActive != after.overviewActive:
    return true
  kind in {
    MsgKind.WlManageStart, MsgKind.WlWindowCreated, MsgKind.WlWindowDestroyed,
    MsgKind.WlWindowAppId, MsgKind.WlWindowFullscreenRequested,
    MsgKind.WlWindowExitFullscreenRequested, MsgKind.WlOutputRemoved,
    MsgKind.CmdToggleFullscreen, MsgKind.CmdToggleFullscreenById,
    MsgKind.CmdExitFullscreenById, MsgKind.CmdToggleOverview, MsgKind.CmdOpenOverview,
    MsgKind.CmdCloseOverview, MsgKind.CmdOverviewTab, MsgKind.CmdSelectWindow,
    MsgKind.CmdConfigReload,
  }

proc addFullscreenPresentationSync(
    effects: var seq[Effect], msg: Msg, before, after: ShellSnapshot
) =
  if not msg.kind.shouldSyncFullscreenPresentation(before, after):
    return

  let afterFocus = after.focusedWindowId()
  let focusedWin = after.windowById(afterFocus)
  let overlayFocus =
    (afterFocus != 0'u32 and afterFocus == after.activeScratchpadWindow) or
    (focusedWin.isSome and (focusedWin.get().isFloating or focusedWin.get().isOverlay))
  let overlayRoot =
    if overlayFocus:
      after.popupRoot(afterFocus)
    else:
      0'u32
  for win in after.windows:
    if win.isFullscreen:
      let present =
        if after.overviewActive:
          false
        elif overlayFocus and overlayRoot != afterFocus:
          win.id == overlayRoot
        elif overlayFocus:
          not win.isFloating and not win.isOverlay and after.windowOnActiveWorkspace(
            win
          )
        else:
          win.id == afterFocus
      effects.addFullscreenPresentationEffect(win, present)

  for beforeWin in before.windows:
    if beforeWin.isFullscreen and after.fullscreenWindow(beforeWin.id).isNone:
      effects.addFullscreenPresentationEffect(beforeWin, false)

proc shouldSyncMaximizedPresentation(
    kind: MsgKind, before, after: ShellSnapshot
): bool =
  if before.focusedWindowId() != after.focusedWindowId() or
      before.activeTag != after.activeTag or
      before.overviewActive != after.overviewActive:
    return true
  kind in {
    MsgKind.WlManageStart, MsgKind.WlWindowCreated, MsgKind.WlWindowDestroyed,
    MsgKind.WlWindowAppId, MsgKind.WlWindowMaximizeRequested,
    MsgKind.WlWindowUnmaximizeRequested, MsgKind.WlWindowMinimizeRequested,
    MsgKind.CmdSetLayout, MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout,
    MsgKind.CmdMaximizeColumn, MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize,
    MsgKind.CmdToggleFloating, MsgKind.CmdSetWindowFloatingById,
    MsgKind.CmdSetWindowMaximizedById, MsgKind.CmdToggleOverview,
    MsgKind.CmdOpenOverview, MsgKind.CmdCloseOverview, MsgKind.CmdOverviewTab,
    MsgKind.CmdSelectWindow, MsgKind.CmdConfigReload,
  }

proc addMaximizedPresentationSync(
    effects: var seq[Effect], msg: Msg, before, after: ShellSnapshot
) =
  if not msg.kind.shouldSyncMaximizedPresentation(before, after):
    return

  let afterFocus = after.focusedWindowId()
  for win in after.windows:
    if win.isMaximized:
      effects.addMaximizedPresentationEffect(
        win, after.effectiveMaximized(win, afterFocus)
      )

  for beforeWin in before.windows:
    if beforeWin.isMaximized and after.maximizedWindow(beforeWin.id).isNone:
      effects.addMaximizedPresentationEffect(beforeWin, false)

proc addPostUpdateEffects*(
    effects: var seq[Effect],
    msg: Msg,
    before, after: ShellSnapshot,
    dirty, collapsed, pruned: bool,
) =
  let beforeFocus = before.focusedWindowId()
  let afterFocus = after.focusedWindowId()
  let overviewClosed = before.overviewActive and not after.overviewActive
  let overviewPreview = after.overviewActive and msg.kind.isOverviewPreviewCommand()
  let overviewWorkspaceChanged = overviewPreview and before.activeTag != after.activeTag
  let workspaceSnapshotChanged =
    collapsed or pruned or before.workspaceSnapshotChanged(after)

  let beforeIdleInhibitActive = before.idleInhibitActive()
  let afterIdleInhibitActive = after.idleInhibitActive()
  if beforeIdleInhibitActive != afterIdleInhibitActive:
    effects.add(
      Effect(
        kind: EffectKind.EffSetIdleInhibit, idleInhibitActive: afterIdleInhibitActive
      )
    )

  if before.overviewActive != after.overviewActive:
    effects.add(broadcastOverview(after.overviewActive))
  if before.activeTag != after.activeTag and after.activeTag != 0:
    effects.add(broadcastWorkspaceActivated(after))
  for workspace in after.workspaces:
    let beforeWorkspace = before.workspaceByTag(workspace.tagId)
    if beforeWorkspace.isSome and
        beforeWorkspace.get().focusedWindow != workspace.focusedWindow:
      effects.add(broadcastWorkspaceActiveWindowChanged(workspace))
  if beforeFocus != afterFocus:
    effects.add(broadcastWindowFocusChanged(afterFocus))
    if afterFocus != 0 and after.overviewActive:
      effects.add(Effect(kind: EffectKind.EffFocusShellUi))
    elif afterFocus != 0:
      effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif overviewClosed and afterFocus != 0:
    effects.add(broadcastWindowFocusChanged(afterFocus))
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and afterFocus != 0 and not after.overviewActive and
      msg.kind.isFocusPreservingLayoutCommand():
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and beforeFocus == afterFocus and
      msg.kind.shouldReassertFocusedWindow(before, after):
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif msg.kind == MsgKind.CmdFocusWindowById and msg.focusWindowId == afterFocus and
      afterFocus != 0:
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif (
    msg.kind in {MsgKind.CmdCloseOverview, MsgKind.CmdSelectWindow} or (
      msg.kind == MsgKind.WlModifiersChanged and before.overviewActive and
      not after.overviewActive
    )
  ) and afterFocus != 0:
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and overviewPreview:
    effects.add(Effect(kind: EffectKind.EffFocusShellUi))

  effects.addFullscreenPresentationSync(msg, before, after)
  effects.addMaximizedPresentationSync(msg, before, after)

  if dirty and
      msg.kind in {
        MsgKind.WlWindowCreated, MsgKind.WlWindowAppId, MsgKind.WlWindowTitle,
        MsgKind.WlWindowDimensions,
      }:
    let openedId =
      case msg.kind
      of MsgKind.WlWindowCreated: msg.windowId
      of MsgKind.WlWindowAppId: msg.appIdWindowId
      of MsgKind.WlWindowTitle: msg.titleWindowId
      of MsgKind.WlWindowDimensions: msg.dimensionsWindowId
      else: 0'u32
    if msg.kind in {MsgKind.WlWindowTitle, MsgKind.WlWindowDimensions}:
      effects.add(
        broadcastWindowChanged(openedId, niri = msg.kind != MsgKind.WlWindowTitle)
      )
    else:
      let effect = after.broadcastWindowOpened(openedId)
      if effect.kind != EffectKind.EffNone:
        effects.add(effect)

  if dirty and msg.kind.shouldRequestManageDirty() and
      not effects.hasEffect(EffectKind.EffManageDirty):
    effects.add(Effect(kind: EffectKind.EffManageDirty))
  elif dirty and msg.kind == MsgKind.WlWindowDimensions:
    effects.add(renderDirty("effect:" & $msg.kind))

  if dirty or collapsed or pruned:
    if overviewPreview and not overviewWorkspaceChanged:
      effects.add(after.broadcastTriadStateChanged())
    else:
      if msg.kind.shouldBroadcastOutputsChanged():
        effects.add(after.broadcastOutputsChanged())
        effects.add(after.broadcastWorkspacesChanged())
        if msg.kind.shouldBroadcastNiriWindowsChanged():
          effects.add(after.broadcastWindowsChanged())
      elif workspaceSnapshotChanged:
        effects.add(after.broadcastWorkspacesChanged())
        if msg.kind.shouldBroadcastNiriWindowsChanged():
          effects.add(after.broadcastWindowsChanged())
      elif msg.kind.shouldBroadcastNiriWindowsChanged():
        effects.add(after.broadcastWindowsChanged())

      if msg.kind.shouldBroadcastTriadLayoutChanged() or overviewWorkspaceChanged or
          collapsed or pruned:
        effects.add(after.broadcastTriadLayoutStateChanged())
      if msg.kind.shouldBroadcastTriadStateChanged() or overviewWorkspaceChanged or
          collapsed or pruned:
        effects.add(after.broadcastTriadStateChanged())
