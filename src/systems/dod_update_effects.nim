import json, options
import ../core/effects
import ../core/msg
import ../core/niri_state
import ../core/triad_state
import ../state/engine
import ../types/shell_snapshot
from ../types/runtime_values import nil

type
  DodUpdateStep* = object
    dirty*: bool
    effects*: seq[Effect]

proc externalWindowId*(id: runtime_values.WindowId): ExternalWindowId =
  ExternalWindowId(uint32(id))

proc externalOutputId*(id: uint32): ExternalOutputId =
  ExternalOutputId(id)

proc legacyWindowId*(id: ExternalWindowId): runtime_values.WindowId =
  runtime_values.WindowId(uint32(id))

proc legacyWindowId*(model: DodModel; winId: WindowId):
    runtime_values.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacyWindowId(winOpt.get().externalId)
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
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WorkspaceActivated": {
      "id": workspace.tagId,
      "focused": true
    }
  }))

proc broadcastWindowFocusChanged*(winId: runtime_values.WindowId): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowFocusChanged": {
      "id": winId
    }
  }))

proc broadcastWindowOpened*(snapshot: ShellSnapshot;
    winId: runtime_values.WindowId): Effect =
  for win in snapshot.windows:
    if win.id == winId:
      return Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
        "WindowOpenedOrChanged": {
          "window": niriWindowJson(snapshot, win)
        }
      }))
  Effect(kind: EffNone)

proc broadcastWindowClosed*(winId: runtime_values.WindowId): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowClosed": {
      "id": winId
    }
  }))

proc broadcastWindowsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WindowsChanged": {
      "windows": niriWindowsJson(snapshot)
    }
  }))

proc broadcastWorkspacesChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "WorkspacesChanged": {
      "workspaces": niriWorkspacesJson(snapshot)
    }
  }))

proc broadcastOutputsChanged*(snapshot: ShellSnapshot): Effect =
  Effect(kind: EffBroadcastJson, jsonPayload: $(%*{
    "OutputsChanged": {
      "outputs": niriOutputsJson(snapshot)
    }
  }))

proc broadcastOverview*(open: bool): Effect =
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

proc broadcastTriadLayoutStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffBroadcastTriadJson,
    jsonPayload: triadLayoutStateChangedEvent(snapshot),
    triadEventName: "layout")

proc broadcastTriadStateChanged*(snapshot: ShellSnapshot): Effect =
  Effect(
    kind: EffBroadcastTriadJson,
    jsonPayload: triadStateChangedEvent(snapshot),
    triadEventName: "state")

proc shouldBroadcastWindowsChanged*(kind: MsgKind): bool =
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

proc shouldBroadcastOutputsChanged*(kind: MsgKind): bool =
  case kind
  of WlOutputDimensions,
      WlOutputName,
      WlOutputPosition,
      WlOutputUsable,
      WlOutputRemoved:
    true
  else:
    false

proc shouldBroadcastTriadLayoutChanged*(kind: MsgKind): bool =
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

proc shouldBroadcastTriadStateChanged*(kind: MsgKind): bool =
  kind.shouldBroadcastTriadLayoutChanged() or
    kind.shouldBroadcastWindowsChanged() or
    kind.shouldBroadcastOutputsChanged() or
    kind in {CmdToggleOverview, CmdOpenOverview, CmdCloseOverview}

proc isFocusChangingCommand*(kind: MsgKind): bool =
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

proc shouldCollapseAfterUpdate*(kind: MsgKind): bool =
  kind in {
    WlWindowDestroyed,
    CmdMoveToTag,
    CmdMoveWindowUpOrToWorkspaceUp,
    CmdMoveWindowDownOrToWorkspaceDown,
    CmdMoveToWorkspaceIndex,
    CmdMoveToScratchpad,
    CmdMoveToNamedScratchpad,
    CmdToggleNamedScratchpad}

proc addSetFullscreenEffect*(effects: var seq[Effect];
    winId: runtime_values.WindowId; fullscreen: bool; outputId = 0'u32) =
  effects.add(Effect(
    kind: EffSetFullscreen,
    fsWinId: winId,
    isFullscreen: fullscreen,
    fsOutputId: outputId))

proc addSetMaximizedEffect*(effects: var seq[Effect];
    winId: runtime_values.WindowId; maximized: bool) =
  effects.add(Effect(
    kind: EffSetMaximized,
    maxWinId: winId,
    isMaximized: maximized))

proc addPostUpdateEffects*(
    effects: var seq[Effect]; msg: Msg; before, after: ShellSnapshot;
    dirty, collapsed, pruned: bool) =
  let beforeFocus = before.focusedWindowId()
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
