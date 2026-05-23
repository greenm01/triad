import std/[json, options]
import ../core/[effects, msg, shell_focus]
import ../state/engine
import ../types/janet_layouts
import ../utils/behavior_log
import update_commands, update_effects, update_events, update_maintenance, window_rules

proc shouldLogRuntimeUpdate(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowCreated, MsgKind.WlWindowDestroyed, MsgKind.WlWindowAppId,
    MsgKind.WlWindowMaximizeRequested, MsgKind.WlWindowUnmaximizeRequested,
    MsgKind.WlWindowMinimizeRequested, MsgKind.WlSessionLocked,
    MsgKind.WlSessionUnlocked, MsgKind.WlFocusChanged, MsgKind.WlFrameTabClicked,
    MsgKind.CmdFocusTag, MsgKind.CmdFocusTagLeft, MsgKind.CmdFocusTagRight,
    MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdNewWorkspace, MsgKind.CmdMoveToTag,
    MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight,
    MsgKind.CmdMoveWorkspaceToOutput, MsgKind.CmdMoveWindowToTag,
    MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowToWorkspaceIndex,
    MsgKind.CmdMoveWindowUpOrToWorkspaceUp, MsgKind.CmdMoveWindowDownOrToWorkspaceDown,
    MsgKind.CmdSetLayout, MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout,
    MsgKind.CmdMaximizeColumn, MsgKind.CmdToggleFloating,
    MsgKind.CmdSetWindowFloatingById, MsgKind.CmdSetWindowMaximizedById,
    MsgKind.CmdToggleMaximized, MsgKind.CmdMoveToScratchpad,
    MsgKind.CmdMoveToNamedScratchpad, MsgKind.CmdToggleScratchpad,
    MsgKind.CmdToggleNamedScratchpad, MsgKind.CmdRestoreScratchpad,
  }

proc updateSnapshotSummary(
    snapshot: ShellSnapshot, sessionLocked, layerFocusExclusive: bool
): JsonNode =
  %*{
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "layout_mode": snapshot.activeWorkspaceLayoutId(),
    "focused_window": uint32(snapshot.focusedWindowId()),
    "session_locked": sessionLocked,
    "layer_focus_exclusive": layerFocusExclusive,
    "workspaces": snapshot.workspaces.len,
    "windows": snapshot.windows.len,
    "workspace_distribution": snapshot.compactWorkspaceDistribution(),
  }

proc addTrackedWindowId(ids: var seq[uint32], id: uint32) =
  if id == 0:
    return
  for existing in ids:
    if existing == id:
      return
  ids.add(id)

proc addMsgWindowId(ids: var seq[uint32], msg: Msg) =
  case msg.kind
  of MsgKind.WlWindowCreated:
    ids.addTrackedWindowId(msg.windowId)
  of MsgKind.WlWindowDestroyed:
    ids.addTrackedWindowId(msg.destroyedId)
  of MsgKind.WlFocusChanged:
    ids.addTrackedWindowId(msg.newFocusedId)
  of MsgKind.WlFrameTabClicked:
    ids.addTrackedWindowId(msg.frameClickWindowId)
  of MsgKind.WlWindowAppId:
    ids.addTrackedWindowId(msg.appIdWindowId)
  of MsgKind.WlWindowMaximizeRequested:
    ids.addTrackedWindowId(msg.maximizeRequestId)
  of MsgKind.WlWindowUnmaximizeRequested:
    ids.addTrackedWindowId(msg.unmaximizeRequestId)
  of MsgKind.WlWindowMinimizeRequested:
    ids.addTrackedWindowId(msg.minimizeRequestId)
  of MsgKind.CmdMoveWindowToTag:
    ids.addTrackedWindowId(msg.moveWindowId)
  of MsgKind.CmdMoveWindowToWorkspaceIndex:
    ids.addTrackedWindowId(msg.moveWorkspaceWindowId)
  of MsgKind.CmdSetWindowFloatingById:
    ids.addTrackedWindowId(msg.floatingWindowId)
  of MsgKind.CmdSetWindowMaximizedById:
    ids.addTrackedWindowId(msg.maximizedWindowId)
  else:
    discard

proc trackedRuntimeWindowIds(msg: Msg, before, after: ShellSnapshot): seq[uint32] =
  result.addTrackedWindowId(before.focusedWindowId())
  result.addTrackedWindowId(after.focusedWindowId())
  result.addMsgWindowId(msg)

proc compactWindowState(snapshot: ShellSnapshot, id: uint32): JsonNode =
  for win in snapshot.windows:
    if win.id != id:
      continue
    result =
      %*{
        "id": win.id,
        "workspace_idx": win.workspaceIdx,
        "focused": win.isFocused,
        "floating": win.isFloating,
        "fullscreen": win.isFullscreen,
        "maximized": win.isMaximized,
        "minimized": win.isMinimized,
        "app_id": win.appId,
        "title": win.title,
      }
    result["tag_id"] =
      if win.tagId.isSome:
        %win.tagId.get()
      else:
        newJNull()
    return
  result = newJNull()

proc compactTrackedWindows(snapshot: ShellSnapshot, ids: seq[uint32]): JsonNode =
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
      result.add(
        %*{
          "kind": $effect.kind,
          "window_id": effect.maxWinId,
          "maximized": effect.isMaximized,
        }
      )
    of EffectKind.EffSetFullscreen:
      result.add(
        %*{
          "kind": $effect.kind,
          "window_id": effect.fsWinId,
          "fullscreen": effect.isFullscreen,
          "output_id": effect.fsOutputId,
        }
      )
    of EffectKind.EffFocusWindow:
      result.add(%*{"kind": $effect.kind, "window_id": effect.focusId})
    of EffectKind.EffRenderDirty:
      result.add(%*{"kind": $effect.kind, "reason": effect.renderDirtyReason})
    of EffectKind.EffBroadcastWindowChanged:
      result.add(%*{"kind": $effect.kind, "window_id": effect.broadcastWindowId})
    of EffectKind.EffSetIdleInhibit:
      result.add(%*{"kind": $effect.kind, "active": effect.idleInhibitActive})
    else:
      discard

proc isLayoutCommand(kind: MsgKind): bool =
  kind in {MsgKind.CmdSetLayout, MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout}

proc needsFullSnapshotAlways(kind: MsgKind): bool =
  case kind
  of MsgKind.WlPointerDelta, MsgKind.WlRecentWindowPointerMotion,
      MsgKind.WlOverviewPointerScrollRequested, MsgKind.WlPointerMoveRequested,
      MsgKind.WlPointerResizeRequested, MsgKind.WlOverviewPointerDragRequested,
      MsgKind.WlWindowTitle, MsgKind.CmdTick:
    false
  else:
    true

proc modelFocusedWindowId(model: Model): uint32 =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    let winOpt = model.windowData(scratchpad)
    if winOpt.isSome:
      return uint32(winOpt.get().externalId)
  if model.activeTag == NullTagId:
    return 0
  let focused = model.effectiveTagFocusedWindow(model.activeTag)
  if focused != NullWindowId:
    let winOpt = model.windowData(focused)
    if winOpt.isSome:
      return uint32(winOpt.get().externalId)
  0

proc layoutTransitionPayload(before, after: ShellSnapshot): JsonNode =
  %*{
    "before": before.activeWorkspaceLayoutId(),
    "after": after.activeWorkspaceLayoutId(),
    "active_tag_before": before.activeTag,
    "active_tag_after": after.activeTag,
  }

proc writeRuntimeUpdateEvent(
    msg: Msg,
    beforeSessionLocked, beforeLayerFocusExclusive: bool,
    afterSessionLocked, afterLayerFocusExclusive: bool,
    before, after: ShellSnapshot,
    dirty, collapsed, pruned: bool,
    effects: seq[Effect],
) =
  if not behaviorLogEnabled():
    return
  let kind = msg.kind
  if not kind.shouldLogRuntimeUpdate():
    return
  let trackedIds = trackedRuntimeWindowIds(msg, before, after)
  let payload =
    %*{
      "kind": $kind,
      "dirty": dirty,
      "collapsed": collapsed,
      "pruned": pruned,
      "effect_count": effects.len,
      "effects": effects.compactRuntimeEffects(),
      "before":
        before.updateSnapshotSummary(beforeSessionLocked, beforeLayerFocusExclusive),
      "after": after.updateSnapshotSummary(afterSessionLocked, afterLayerFocusExclusive),
      "tracked_windows": {
        "before": before.compactTrackedWindows(trackedIds),
        "after": after.compactTrackedWindows(trackedIds),
      },
    }
  if kind.isLayoutCommand():
    payload["layout_transition"] = before.layoutTransitionPayload(after)
  writeBehaviorEvent("runtime_update", payload)

proc updateInPlace*(
    model: var Model, msg: Msg, movementEval: CustomLayoutMovementEval = nil
): seq[Effect] =
  var effects: seq[Effect] = @[]
  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return effects

  let beforeFocus = model.modelFocusedWindowId()
  let beforeTag = model.activeSlot
  let beforeOverview = model.overviewActive
  let beforeSessionLocked = model.sessionLocked
  let beforeLayerFocusExclusive = model.layerFocusExclusive
  let cmdTickMayChangeFocus =
    msg.kind == MsgKind.CmdTick and model.pendingDialogFocusWindows.len > 0
  let needsSnapshotBeforeMutation =
    msg.kind.needsFullSnapshotAlways() or cmdTickMayChangeFocus or
    (behaviorLogEnabled() and msg.kind.shouldLogRuntimeUpdate())
  let before =
    if needsSnapshotBeforeMutation:
      shellSnapshot(model)
    else:
      ShellSnapshot()

  let step =
    case msg.kind
    of MsgKind.WlWindowCreated .. MsgKind.WlModifiersChanged:
      model.applyEvent(msg)
    of MsgKind.CmdSetLayout .. MsgKind.CmdScreenshot:
      model.applyCommand(msg, movementEval)
  for effect in step.effects:
    effects.add(effect)
  var dirty = step.dirty

  if msg.kind == MsgKind.WlManageStart and not dirty and effects.len == 0:
    return effects

  let maintenance = model.applyUpdateMaintenance(msg.kind)
  if maintenance.collapsed or maintenance.pruned or maintenance.outputCovered:
    dirty = true
  if dirty and msg.kind != MsgKind.CmdTick and model.windowRuleStateMatchersEnabled():
    dirty = model.refreshWindowRuleDerivedState() or dirty

  let afterFocus = model.modelFocusedWindowId()
  let afterTag = model.activeSlot
  let afterOverview = model.overviewActive

  let needSnapshot =
    needsSnapshotBeforeMutation or beforeFocus != afterFocus or beforeTag != afterTag or
    beforeOverview != afterOverview or maintenance.collapsed or maintenance.pruned or
    maintenance.outputCovered or
    (behaviorLogEnabled() and msg.kind.shouldLogRuntimeUpdate())

  let after =
    if needSnapshot:
      shellSnapshot(model)
    else:
      ShellSnapshot()

  effects.addPostUpdateEffects(
    msg, before, after, dirty, maintenance.collapsed, maintenance.pruned
  )
  writeRuntimeUpdateEvent(
    msg, beforeSessionLocked, beforeLayerFocusExclusive, model.sessionLocked,
    model.layerFocusExclusive, before, after, dirty, maintenance.collapsed,
    maintenance.pruned, effects,
  )

  effects

proc update*(
    model: Model, msg: Msg, movementEval: CustomLayoutMovementEval = nil
): (Model, seq[Effect]) =
  var next = model
  let effects = next.updateInPlace(msg, movementEval)
  (next, effects)
