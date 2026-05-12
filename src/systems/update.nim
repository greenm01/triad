import std/[json, options]
import ../core/[effects, msg]
import ../state/engine
from ../types/runtime_values import nil
import ../utils/behavior_log
import update_commands, update_effects, update_events, update_maintenance

proc shouldLogRuntimeUpdate(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowMaximizeRequested,
    MsgKind.WlWindowUnmaximizeRequested,
    MsgKind.WlWindowMinimizeRequested,
    MsgKind.WlFocusChanged,
    MsgKind.CmdFocusTag,
    MsgKind.CmdFocusTagLeft,
    MsgKind.CmdFocusTagRight,
    MsgKind.CmdFocusWorkspaceIndex,
    MsgKind.CmdMoveToTag,
    MsgKind.CmdMoveToTagLeft,
    MsgKind.CmdMoveToTagRight,
    MsgKind.CmdMoveToWorkspaceIndex,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
    MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdSetLayout,
    MsgKind.CmdSwitchLayout,
    MsgKind.CmdMaximizeColumn,
    MsgKind.CmdToggleMaximized}

proc updateSnapshotSummary(snapshot: ShellSnapshot): JsonNode =
  %*{
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "focused_window": uint32(snapshot.focusedWindowId()),
    "workspaces": snapshot.workspaces.len,
    "windows": snapshot.windows.len,
    "workspace_distribution": snapshot.compactWorkspaceDistribution()
  }

proc addTrackedWindowId(
    ids: var seq[runtime_values.WindowId]; id: runtime_values.WindowId) =
  if id == 0:
    return
  for existing in ids:
    if existing == id:
      return
  ids.add(id)

proc addMsgWindowId(ids: var seq[runtime_values.WindowId]; msg: Msg) =
  case msg.kind
  of MsgKind.WlFocusChanged:
    ids.addTrackedWindowId(msg.newFocusedId)
  of MsgKind.WlWindowMaximizeRequested:
    ids.addTrackedWindowId(msg.maximizeRequestId)
  of MsgKind.WlWindowUnmaximizeRequested:
    ids.addTrackedWindowId(msg.unmaximizeRequestId)
  of MsgKind.WlWindowMinimizeRequested:
    ids.addTrackedWindowId(msg.minimizeRequestId)
  else:
    discard

proc trackedRuntimeWindowIds(
    msg: Msg; before, after: ShellSnapshot): seq[runtime_values.WindowId] =
  result.addTrackedWindowId(before.focusedWindowId())
  result.addTrackedWindowId(after.focusedWindowId())
  result.addMsgWindowId(msg)

proc compactWindowState(
    snapshot: ShellSnapshot; id: runtime_values.WindowId): JsonNode =
  for win in snapshot.windows:
    if win.id != id:
      continue
    result = %*{
      "id": win.id,
      "workspace_idx": win.workspaceIdx,
      "focused": win.isFocused,
      "floating": win.isFloating,
      "fullscreen": win.isFullscreen,
      "maximized": win.isMaximized,
      "minimized": win.isMinimized,
      "app_id": win.appId,
      "title": win.title
    }
    result["tag_id"] =
      if win.tagId.isSome: %win.tagId.get()
      else: newJNull()
    return
  result = newJNull()

proc compactTrackedWindows(
    snapshot: ShellSnapshot;
    ids: seq[runtime_values.WindowId]): JsonNode =
  result = newJArray()
  for id in ids:
    let node = snapshot.compactWindowState(id)
    if node.kind != JNull:
      result.add(node)

proc compactRuntimeEffects(effects: seq[Effect]): JsonNode =
  result = newJArray()
  for effect in effects:
    case effect.kind
    of EffectKind.EffSetMaximized:
      result.add(%*{
        "kind": $effect.kind,
        "window_id": effect.maxWinId,
        "maximized": effect.isMaximized
      })
    of EffectKind.EffSetFullscreen:
      result.add(%*{
        "kind": $effect.kind,
        "window_id": effect.fsWinId,
        "fullscreen": effect.isFullscreen,
        "output_id": effect.fsOutputId
      })
    of EffectKind.EffFocusWindow:
      result.add(%*{
        "kind": $effect.kind,
        "window_id": effect.focusId
      })
    else:
      discard

proc writeRuntimeUpdateEvent(
    msg: Msg; before, after: ShellSnapshot; dirty, collapsed,
    pruned: bool; effects: seq[Effect]) =
  let kind = msg.kind
  if not kind.shouldLogRuntimeUpdate():
    return
  let trackedIds = trackedRuntimeWindowIds(msg, before, after)
  writeBehaviorEvent("runtime_update", %*{
    "kind": $kind,
    "dirty": dirty,
    "collapsed": collapsed,
    "pruned": pruned,
    "effect_count": effects.len,
    "effects": effects.compactRuntimeEffects(),
    "before": before.updateSnapshotSummary(),
    "after": after.updateSnapshotSummary(),
    "window_states": {
      "before": before.compactSnapshotWindows(),
      "after": after.compactSnapshotWindows()
    },
    "tracked_windows": {
      "before": before.compactTrackedWindows(trackedIds),
      "after": after.compactTrackedWindows(trackedIds)
    }
  })

proc update*(model: Model; msg: Msg): (Model, seq[Effect]) =
  var next = model
  var effects: seq[Effect] = @[]
  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return (next, effects)

  let before = shellSnapshot(model)
  let step =
    case msg.kind
    of MsgKind.WlWindowCreated .. MsgKind.WlModifiersChanged:
      next.applyEvent(msg)
    of MsgKind.CmdSetLayout .. MsgKind.CmdScreenshot:
      next.applyCommand(msg)
  for effect in step.effects:
    effects.add(effect)
  var dirty = step.dirty

  let maintenance = next.applyUpdateMaintenance(msg.kind)
  if maintenance.collapsed or maintenance.pruned:
    dirty = true

  let after = shellSnapshot(next)
  effects.addPostUpdateEffects(
    msg, before, after, dirty, maintenance.collapsed, maintenance.pruned)
  writeRuntimeUpdateEvent(
    msg, before, after, dirty, maintenance.collapsed, maintenance.pruned,
    effects)

  (next, effects)
