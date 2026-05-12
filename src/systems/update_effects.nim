import std/[json, options]
import ../core/[effects, msg, niri_state, triad_state]
import ../state/engine
import ../types/shell_snapshot
from ../types/runtime_values import nil
import presentation_policy

type
  UpdateStep* = object
    dirty*: bool
    effects*: seq[Effect]

proc externalWindowId*(id: runtime_values.WindowId): ExternalWindowId =
  ExternalWindowId(uint32(id))

proc externalOutputId*(id: uint32): ExternalOutputId =
  ExternalOutputId(id)

proc runtimeWindowId*(id: ExternalWindowId): runtime_values.WindowId =
  runtime_values.WindowId(uint32(id))

proc runtimeWindowId*(model: Model; winId: WindowId):
    runtime_values.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return runtimeWindowId(winOpt.get().externalId)
  0'u32

proc focusedWindowId*(snapshot: ShellSnapshot): runtime_values.WindowId =
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

proc hasEffect*(effects: seq[Effect]; kind: EffectKind): bool =
  for effect in effects:
    if effect.kind == kind:
      return true
  false

proc broadcastWorkspaceActivated*(snapshot: ShellSnapshot): Effect =
  let workspace = snapshot.activeWorkspace()
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "WorkspaceActivated": {
      "id": workspace.tagId,
      "focused": true
    }
  }))

proc broadcastWindowFocusChanged*(winId: runtime_values.WindowId): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "WindowFocusChanged": {
      "id": winId
    }
  }))

proc broadcastWindowOpened*(snapshot: ShellSnapshot;
    winId: runtime_values.WindowId): Effect =
  for win in snapshot.windows:
    if win.id == winId:
      return Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
        "WindowOpenedOrChanged": {
          "window": niriWindowJson(snapshot, win)
        }
      }))
  Effect(kind: EffectKind.EffNone)

proc broadcastWindowClosed*(winId: runtime_values.WindowId): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "WindowClosed": {
      "id": winId
    }
  }))

proc broadcastWindowsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "WindowsChanged": {
      "windows": niriWindowsJson(snapshot)
    }
  }))

proc broadcastWorkspacesChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "WorkspacesChanged": {
      "workspaces": niriWorkspacesJson(snapshot)
    }
  }))

proc broadcastOutputsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
    "OutputsChanged": {
      "outputs": niriOutputsJson(snapshot)
    }
  }))

proc broadcastOverview*(open: bool): Effect =
  Effect(kind: EffectKind.EffBroadcastJson, jsonPayload: $(%*{
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

proc broadcastTriadLayoutStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastTriadJson,
    jsonPayload: triadLayoutStateChangedEvent(snapshot),
    triadEventName: "layout")

proc broadcastTriadStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffectKind.EffBroadcastTriadJson,
    jsonPayload: triadStateChangedEvent(snapshot),
    triadEventName: "state")

proc shouldBroadcastWindowsChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlWindowCreated,
      MsgKind.WlWindowDestroyed,
      MsgKind.WlFocusChanged,
      MsgKind.WlWindowFullscreenRequested,
      MsgKind.WlWindowExitFullscreenRequested,
      MsgKind.WlWindowParent,
      MsgKind.WlWindowMaximizeRequested,
      MsgKind.WlWindowUnmaximizeRequested,
      MsgKind.WlWindowMinimizeRequested,
      MsgKind.WlWindowDimensions,
      MsgKind.WlWindowIdentifier,
      MsgKind.WlWindowAppId,
      MsgKind.WlWindowTitle,
      MsgKind.WlWindowDimensionsHint,
      MsgKind.CmdFocusNext,
      MsgKind.CmdFocusPrev,
      MsgKind.CmdFocusDirection,
      MsgKind.CmdFocusLast,
      MsgKind.CmdFocusTagLeft,
      MsgKind.CmdFocusTagRight,
      MsgKind.CmdFocusOccupiedTagLeft,
      MsgKind.CmdFocusOccupiedTagRight,
      MsgKind.CmdFocusColumnFirst,
      MsgKind.CmdFocusColumnLast,
      MsgKind.CmdFocusWindowOrWorkspaceUp,
      MsgKind.CmdFocusWindowOrWorkspaceDown,
      MsgKind.CmdFocusWorkspaceIndex,
      MsgKind.CmdMoveToTagLeft,
      MsgKind.CmdMoveToTagRight,
      MsgKind.CmdMoveToWorkspaceIndex,
      MsgKind.CmdMoveWindow,
      MsgKind.CmdMoveWindowLeft,
      MsgKind.CmdMoveWindowRight,
      MsgKind.CmdMoveWindowUp,
      MsgKind.CmdMoveWindowDown,
      MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
      MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
      MsgKind.CmdMoveColumnLeft,
      MsgKind.CmdMoveColumnRight,
      MsgKind.CmdMoveColumnToFirst,
      MsgKind.CmdMoveColumnToLast,
      MsgKind.CmdSwapWindowUp,
      MsgKind.CmdSwapWindowDown,
      MsgKind.CmdConsumeWindow,
      MsgKind.CmdExpelWindow,
      MsgKind.CmdMoveToTag,
      MsgKind.CmdSwapWindowToTag,
      MsgKind.CmdMoveToScratchpad,
      MsgKind.CmdMoveToNamedScratchpad,
      MsgKind.CmdToggleScratchpad,
      MsgKind.CmdToggleNamedScratchpad,
      MsgKind.CmdRestoreScratchpad,
      MsgKind.CmdToggleFloating,
      MsgKind.CmdToggleFullscreen,
      MsgKind.CmdToggleFullscreenById,
      MsgKind.CmdExitFullscreenById,
      MsgKind.CmdToggleMaximized,
      MsgKind.CmdMinimize,
      MsgKind.CmdSelectWindow,
      MsgKind.CmdFocusTag,
      MsgKind.CmdFocusWindowById:
    true
  else:
    false

proc shouldBroadcastOutputsChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlOutputDimensions,
      MsgKind.WlOutputName,
      MsgKind.WlOutputPosition,
      MsgKind.WlOutputUsable,
      MsgKind.WlOutputRemoved:
    true
  else:
    false

proc shouldBroadcastTriadLayoutChanged*(kind: MsgKind): bool =
  case kind
  of MsgKind.WlWindowCreated,
      MsgKind.WlWindowDestroyed,
      MsgKind.WlWindowDimensions,
      MsgKind.WlWindowDimensionsHint,
      MsgKind.WlWindowParent,
      MsgKind.WlWindowFullscreenRequested,
      MsgKind.WlWindowExitFullscreenRequested,
      MsgKind.WlWindowMaximizeRequested,
      MsgKind.WlWindowUnmaximizeRequested,
      MsgKind.WlWindowMinimizeRequested,
      MsgKind.CmdSetLayout,
      MsgKind.CmdSwitchLayout,
      MsgKind.CmdSetMasterCount,
      MsgKind.CmdSetMasterRatio,
      MsgKind.CmdAdjustMasterCount,
      MsgKind.CmdAdjustMasterRatio,
      MsgKind.CmdResizeWidth,
      MsgKind.CmdResizeHeight,
      MsgKind.CmdSetColumnWidth,
      MsgKind.CmdFocusTag,
      MsgKind.CmdFocusWorkspaceIndex,
      MsgKind.CmdMoveToTag,
      MsgKind.CmdMoveToWorkspaceIndex,
      MsgKind.CmdMoveToTagLeft,
      MsgKind.CmdMoveToTagRight,
      MsgKind.CmdMoveWindow,
      MsgKind.CmdMoveWindowLeft,
      MsgKind.CmdMoveWindowRight,
      MsgKind.CmdMoveWindowUp,
      MsgKind.CmdMoveWindowDown,
      MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
      MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
      MsgKind.CmdMoveColumnLeft,
      MsgKind.CmdMoveColumnRight,
      MsgKind.CmdMoveColumnToFirst,
      MsgKind.CmdMoveColumnToLast,
      MsgKind.CmdSwapWindowUp,
      MsgKind.CmdSwapWindowDown,
      MsgKind.CmdConsumeWindow,
      MsgKind.CmdExpelWindow,
      MsgKind.CmdMoveToScratchpad,
      MsgKind.CmdMoveToNamedScratchpad,
      MsgKind.CmdToggleScratchpad,
      MsgKind.CmdToggleNamedScratchpad,
      MsgKind.CmdRestoreScratchpad,
      MsgKind.CmdToggleFloating,
      MsgKind.CmdToggleFullscreen,
      MsgKind.CmdToggleFullscreenById,
      MsgKind.CmdExitFullscreenById,
      MsgKind.CmdToggleMaximized,
      MsgKind.CmdMinimize,
      MsgKind.CmdSelectWindow:
    true
  else:
    false

proc shouldBroadcastTriadStateChanged*(kind: MsgKind): bool =
  kind.shouldBroadcastTriadLayoutChanged() or
    kind.shouldBroadcastWindowsChanged() or
    kind.shouldBroadcastOutputsChanged() or
    kind in {MsgKind.CmdToggleOverview, MsgKind.CmdOpenOverview,
        MsgKind.CmdCloseOverview}

proc isFocusChangingCommand*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlFocusChanged,
    MsgKind.CmdFocusNext,
    MsgKind.CmdFocusPrev,
    MsgKind.CmdFocusDirection,
    MsgKind.CmdFocusLast,
    MsgKind.CmdFocusTagLeft,
    MsgKind.CmdFocusTagRight,
    MsgKind.CmdFocusOccupiedTagLeft,
    MsgKind.CmdFocusOccupiedTagRight,
    MsgKind.CmdFocusColumnFirst,
    MsgKind.CmdFocusColumnLast,
    MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown,
    MsgKind.CmdFocusTag,
    MsgKind.CmdFocusWindowById,
    MsgKind.CmdSelectWindow,
    MsgKind.CmdToggleScratchpad,
    MsgKind.CmdToggleNamedScratchpad,
    MsgKind.CmdRestoreScratchpad,
    MsgKind.WlShellSurfaceInteraction
  }

proc shouldCollapseAfterUpdate*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowDestroyed,
    MsgKind.CmdMoveToTag,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
    MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdMoveToWorkspaceIndex,
    MsgKind.CmdMoveToScratchpad,
    MsgKind.CmdMoveToNamedScratchpad,
    MsgKind.CmdToggleNamedScratchpad}

proc isOverviewPreviewCommand(kind: MsgKind): bool =
  kind in {
    MsgKind.CmdFocusNext,
    MsgKind.CmdFocusPrev,
    MsgKind.CmdFocusDirection,
    MsgKind.CmdFocusWindowById,
    MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown}

proc isFocusPreservingLayoutCommand(kind: MsgKind): bool =
  kind in {
    MsgKind.CmdMoveWindow,
    MsgKind.CmdMoveWindowLeft,
    MsgKind.CmdMoveWindowRight,
    MsgKind.CmdMoveWindowUp,
    MsgKind.CmdMoveWindowDown,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
    MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdMoveColumnLeft,
    MsgKind.CmdMoveColumnRight,
    MsgKind.CmdMoveColumnToFirst,
    MsgKind.CmdMoveColumnToLast,
    MsgKind.CmdSwapWindowUp,
    MsgKind.CmdSwapWindowDown,
    MsgKind.CmdConsumeWindow,
    MsgKind.CmdExpelWindow,
    MsgKind.CmdZoom}

proc shouldReassertFocusedWindow(
    kind: MsgKind; before, after: ShellSnapshot): bool =
  if after.focusedWindowId() == 0 or after.overviewActive:
    return false
  if kind in {
      MsgKind.CmdMoveToTag,
      MsgKind.CmdMoveToTagLeft,
      MsgKind.CmdMoveToTagRight,
      MsgKind.CmdMoveToWorkspaceIndex}:
    return before.activeTag != after.activeTag
  if kind in {MsgKind.CmdSetLayout, MsgKind.CmdSwitchLayout}:
    return before.activeWorkspace().layoutMode !=
      after.activeWorkspace().layoutMode
  false

proc addSetFullscreenEffect*(effects: var seq[Effect];
    winId: runtime_values.WindowId; fullscreen: bool; outputId = 0'u32) =
  effects.add(Effect(
    kind: EffectKind.EffSetFullscreen,
    fsWinId: winId,
    isFullscreen: fullscreen,
    fsOutputId: outputId))

proc addSetMaximizedEffect*(effects: var seq[Effect];
    winId: runtime_values.WindowId; maximized: bool) =
  effects.add(Effect(
    kind: EffectKind.EffSetMaximized,
    maxWinId: winId,
    isMaximized: maximized))

proc hasFullscreenEffect(
    effects: seq[Effect]; winId: runtime_values.WindowId;
    fullscreen: bool): bool =
  for effect in effects:
    if effect.kind == EffectKind.EffSetFullscreen and
        effect.fsWinId == winId and effect.isFullscreen == fullscreen:
      return true

proc hasMaximizedEffect(
    effects: seq[Effect]; winId: runtime_values.WindowId;
    maximized: bool): bool =
  for effect in effects:
    if effect.kind == EffectKind.EffSetMaximized and
        effect.maxWinId == winId and effect.isMaximized == maximized:
      return true

proc addFullscreenPresentationEffect(
    effects: var seq[Effect]; win: ShellWindow; present: bool) =
  if effects.hasFullscreenEffect(win.id, present):
    return
  effects.addSetFullscreenEffect(
    win.id,
    present,
    if present: win.fullscreenOutput else: 0'u32)

proc addMaximizedPresentationEffect(
    effects: var seq[Effect]; win: ShellWindow; present: bool) =
  if effects.hasMaximizedEffect(win.id, present):
    return
  effects.addSetMaximizedEffect(win.id, present)

proc fullscreenWindow(
    snapshot: ShellSnapshot; winId: runtime_values.WindowId):
    Option[ShellWindow] =
  let win = snapshot.windowById(winId)
  if win.isSome and win.get().isFullscreen:
    return win
  none(ShellWindow)

proc maximizedWindow(
    snapshot: ShellSnapshot; winId: runtime_values.WindowId):
    Option[ShellWindow] =
  let win = snapshot.windowById(winId)
  if win.isSome and win.get().isMaximized:
    return win
  none(ShellWindow)

proc shouldSyncFullscreenPresentation(
    kind: MsgKind; before, after: ShellSnapshot): bool =
  if before.focusedWindowId() != after.focusedWindowId() or
      before.activeTag != after.activeTag or
      before.overviewActive != after.overviewActive:
    return true
  kind in {
    MsgKind.WlManageStart,
    MsgKind.WlWindowCreated,
    MsgKind.WlWindowDestroyed,
    MsgKind.WlWindowFullscreenRequested,
    MsgKind.WlWindowExitFullscreenRequested,
    MsgKind.WlOutputRemoved,
    MsgKind.CmdToggleFullscreen,
    MsgKind.CmdToggleFullscreenById,
    MsgKind.CmdExitFullscreenById,
    MsgKind.CmdToggleOverview,
    MsgKind.CmdOpenOverview,
    MsgKind.CmdCloseOverview,
    MsgKind.CmdSelectWindow
  }

proc addFullscreenPresentationSync(
    effects: var seq[Effect]; msg: Msg; before, after: ShellSnapshot) =
  if not msg.kind.shouldSyncFullscreenPresentation(before, after):
    return

  let afterFocus = after.focusedWindowId()
  let focusedWin = after.windowById(afterFocus)
  let overlayFocus = focusedWin.isSome and focusedWin.get().isFloating
  let overlayRoot =
    if overlayFocus: after.popupRoot(afterFocus)
    else: 0'u32
  for win in after.windows:
    if win.isFullscreen:
      let present =
        if after.overviewActive:
          false
        elif overlayFocus and overlayRoot != afterFocus:
          win.id == overlayRoot
        elif overlayFocus:
          not win.isFloating and after.windowOnActiveWorkspace(win)
        else:
          win.id == afterFocus
      effects.addFullscreenPresentationEffect(win, present)

  for beforeWin in before.windows:
    if beforeWin.isFullscreen and after.fullscreenWindow(beforeWin.id).isNone:
      effects.addFullscreenPresentationEffect(beforeWin, false)

proc shouldSyncMaximizedPresentation(
    kind: MsgKind; before, after: ShellSnapshot): bool =
  if before.focusedWindowId() != after.focusedWindowId() or
      before.activeTag != after.activeTag or
      before.overviewActive != after.overviewActive:
    return true
  kind in {
    MsgKind.WlManageStart,
    MsgKind.WlWindowCreated,
    MsgKind.WlWindowDestroyed,
    MsgKind.WlWindowMaximizeRequested,
    MsgKind.WlWindowUnmaximizeRequested,
    MsgKind.WlWindowMinimizeRequested,
    MsgKind.CmdSetLayout,
    MsgKind.CmdSwitchLayout,
    MsgKind.CmdToggleMaximized,
    MsgKind.CmdMinimize,
    MsgKind.CmdToggleFloating,
    MsgKind.CmdToggleOverview,
    MsgKind.CmdOpenOverview,
    MsgKind.CmdCloseOverview,
    MsgKind.CmdSelectWindow
  }

proc addMaximizedPresentationSync(
    effects: var seq[Effect]; msg: Msg; before, after: ShellSnapshot) =
  if not msg.kind.shouldSyncMaximizedPresentation(before, after):
    return

  let afterFocus = after.focusedWindowId()
  for win in after.windows:
    if win.isMaximized:
      effects.addMaximizedPresentationEffect(
        win, after.effectiveMaximized(win, afterFocus))

  for beforeWin in before.windows:
    if beforeWin.isMaximized and after.maximizedWindow(beforeWin.id).isNone:
      effects.addMaximizedPresentationEffect(beforeWin, false)

proc addPostUpdateEffects*(
    effects: var seq[Effect]; msg: Msg; before, after: ShellSnapshot;
    dirty, collapsed, pruned: bool) =
  let beforeFocus = before.focusedWindowId()
  let afterFocus = after.focusedWindowId()
  let overviewPreview = after.overviewActive and
    msg.kind.isOverviewPreviewCommand()

  if before.activeTag != after.activeTag and after.activeTag != 0:
    effects.add(broadcastWorkspaceActivated(after))
  if beforeFocus != afterFocus:
    effects.add(broadcastWindowFocusChanged(afterFocus))
    if afterFocus != 0 and after.overviewActive:
      effects.add(Effect(kind: EffectKind.EffFocusShellUi))
    elif afterFocus != 0:
      effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and afterFocus != 0 and not after.overviewActive and
      msg.kind.isFocusPreservingLayoutCommand():
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and beforeFocus == afterFocus and
      msg.kind.shouldReassertFocusedWindow(before, after):
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif msg.kind in {MsgKind.CmdCloseOverview, MsgKind.CmdSelectWindow} and
      afterFocus != 0:
    effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: afterFocus))
  elif dirty and overviewPreview:
    effects.add(Effect(kind: EffectKind.EffFocusShellUi))

  effects.addFullscreenPresentationSync(msg, before, after)
  effects.addMaximizedPresentationSync(msg, before, after)

  if msg.kind in {MsgKind.WlWindowCreated, MsgKind.WlWindowAppId,
      MsgKind.WlWindowTitle}:
    let openedId =
      case msg.kind
      of MsgKind.WlWindowCreated: msg.windowId
      of MsgKind.WlWindowAppId: msg.appIdWindowId
      of MsgKind.WlWindowTitle: msg.titleWindowId
      else: 0'u32
    let effect = after.broadcastWindowOpened(openedId)
    if effect.kind != EffectKind.EffNone:
      effects.add(effect)

  if dirty and not effects.hasEffect(EffectKind.EffManageDirty):
    effects.add(Effect(kind: EffectKind.EffManageDirty))

  if dirty or collapsed or pruned:
    if overviewPreview:
      effects.add(after.broadcastTriadStateChanged())
    else:
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
