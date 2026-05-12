import std/json
import ../core/[effects, msg]
import ../state/engine
import ../utils/behavior_log
import update_commands, update_effects, update_events, update_maintenance

proc shouldLogRuntimeUpdate(kind: MsgKind): bool =
  kind in {
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
    MsgKind.CmdSwitchLayout}

proc updateSnapshotSummary(snapshot: ShellSnapshot): JsonNode =
  %*{
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "focused_window": uint32(snapshot.focusedWindowId()),
    "workspaces": snapshot.workspaces.len,
    "windows": snapshot.windows.len
  }

proc writeRuntimeUpdateEvent(
    kind: MsgKind; before, after: ShellSnapshot; dirty, collapsed,
    pruned: bool; effectCount: int) =
  if not kind.shouldLogRuntimeUpdate():
    return
  writeBehaviorEvent("runtime_update", %*{
    "kind": $kind,
    "dirty": dirty,
    "collapsed": collapsed,
    "pruned": pruned,
    "effect_count": effectCount,
    "before": before.updateSnapshotSummary(),
    "after": after.updateSnapshotSummary()
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
  msg.kind.writeRuntimeUpdateEvent(
    before, after, dirty, maintenance.collapsed, maintenance.pruned,
    effects.len)

  (next, effects)
