import std/[json, options, strutils]
import ../core/msg
import ../janet/runtime as janet_runtime
import ../types/[janet_manifest, shell_snapshot]
import ../utils/behavior_log
import message_queue, state

proc manifestOutcomeId(outcome: ManifestOutcome): string =
  case outcome
  of ManifestOutcome.Disabled: "disabled"
  of ManifestOutcome.InvalidAppId: "invalid_app_id"
  of ManifestOutcome.Missing: "missing"
  of ManifestOutcome.ReadFailed: "read_failed"
  of ManifestOutcome.CachedFailed: "cached_failed"
  of ManifestOutcome.EvalFailed: "eval_failed"
  of ManifestOutcome.Evaluated: "evaluated"

proc manifestAppIdReady*(appId: string): bool =
  let normalized = appId.strip().normalize()
  normalized.len > 0 and normalized notin ["unknown", "unset", "none"]

proc manifestWindowPayload(win: ShellWindow): JsonNode =
  result =
    %*{
      "id": win.id,
      "pid": win.pid,
      "parent_id": win.parentId,
      "title": win.title,
      "app_id": win.appId,
      "identifier": win.identifier,
      "workspace_idx": win.workspaceIdx,
    }
  result["tag_id"] =
    if win.tagId.isSome:
      %win.tagId.get()
    else:
      newJNull()

proc manifestCommandPayload(msg: Msg): JsonNode =
  result = %*{"kind": $msg.kind}
  case msg.kind
  of MsgKind.CmdMoveToTag:
    result["target_tag"] = %msg.targetTag
  of MsgKind.CmdMoveWindowToTag:
    result["window_id"] = %msg.moveWindowId
    result["target_tag"] = %msg.moveTargetTag
    result["follow_window"] = %msg.moveFollowWindow
  of MsgKind.CmdMoveToWorkspaceIndex:
    result["workspace_index"] = %msg.workspaceIndex
  of MsgKind.CmdMoveWindowToWorkspaceIndex:
    result["window_id"] = %msg.moveWorkspaceWindowId
    result["workspace_index"] = %msg.moveWorkspaceIndex
    result["follow_window"] = %msg.moveWorkspaceFollowWindow
  of MsgKind.CmdSetLayout:
    result["layout"] = %msg.newLayout.behaviorLayoutId()
    if msg.layoutTargetTag != 0:
      result["target_tag"] = %msg.layoutTargetTag
  of MsgKind.CmdSetWindowFloatingById:
    result["window_id"] = %msg.floatingWindowId
    result["floating"] = %msg.windowFloating
  of MsgKind.CmdSetWindowMaximizedById:
    result["window_id"] = %msg.maximizedWindowId
    result["maximized"] = %msg.windowMaximized
  of MsgKind.CmdFocusWindowById:
    result["window_id"] = %msg.focusWindowId
  of MsgKind.CmdSpawn:
    result["command"] = %msg.spawnCommand
  else:
    discard

proc manifestEvalPayload(evalResult: ManifestEvalResult, trigger: string): JsonNode =
  let commands = newJArray()
  for msg in evalResult.messages:
    commands.add(msg.manifestCommandPayload())
  result =
    %*{
      "trigger": trigger,
      "app_id": evalResult.appId,
      "outcome": evalResult.outcome.manifestOutcomeId(),
      "candidate_paths": evalResult.candidatePaths,
      "path": evalResult.path,
      "command_count": evalResult.messages.len,
      "commands": commands,
    }
  if evalResult.error.len > 0:
    result["error"] = %evalResult.error
  if evalResult.currentWindow.isSome:
    result["current_window"] = evalResult.currentWindow.get().manifestWindowPayload()

proc snapshotWindow*(
    snapshot: ShellSnapshot, id: uint32, fallback: ShellWindow
): ShellWindow =
  for win in snapshot.windows:
    if win.id == id:
      return win
  fallback

proc snapshotHasWindow*(snapshot: ShellSnapshot, id: uint32): bool =
  for win in snapshot.windows:
    if win.id == id:
      return true
  false

proc runWindowManifest*(
    daemon: var TriadDaemon,
    appId: string,
    snapshot: ShellSnapshot,
    currentWindow: ShellWindow,
    trigger: string,
    enqueue = true,
): ManifestEvalResult =
  result =
    daemon.janetRuntime.evalManifestDetailed(appId, snapshot, some(currentWindow))
  writeBehaviorEvent("janet_manifest_eval", result.manifestEvalPayload(trigger))
  if enqueue:
    daemon.enqueueNext(result.messages)
