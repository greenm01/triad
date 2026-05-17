import std/[json, options, sets, strutils]
import ../core/[msg, shell_focus]
import ../janet/[runtime as janet_runtime, snapshot_api]
import ../types/[janet_manifest, shell_snapshot]
import ../utils/[behavior_log]
import state

proc scriptOutcomeId(outcome: ScriptOutcome): string =
  case outcome
  of ScriptOutcome.Disabled: "disabled"
  of ScriptOutcome.Missing: "missing"
  of ScriptOutcome.ReadFailed: "read_failed"
  of ScriptOutcome.CachedFailed: "cached_failed"
  of ScriptOutcome.EvalFailed: "eval_failed"
  of ScriptOutcome.Evaluated: "evaluated"

proc escaped(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '\\':
      result.add("\\\\")
    of '"':
      result.add("\\\"")
    of '\n':
      result.add("\\n")
    of '\r':
      result.add("\\r")
    of '\t':
      result.add("\\t")
    else:
      result.add(ch)
  result.add("\"")

proc eventKeyword(name: string): string =
  ":" & name

proc eventStruct(kind: string, fields: openArray[(string, string)]): string =
  result = "{:kind " & kind.eventKeyword()
  for field in fields:
    result.add(" :")
    result.add(field[0])
    result.add(" ")
    result.add(field[1])
  result.add("}")

proc windowExpr(win: Option[ShellWindow]): string =
  if win.isSome:
    win.get().janetWindowExpr()
  else:
    "nil"

proc windowTitle(win: Option[ShellWindow]): string =
  if win.isSome:
    win.get().title
  else:
    ""

proc windowAppId(win: Option[ShellWindow]): string =
  if win.isSome:
    win.get().appId
  else:
    ""

proc windowById(snapshot: ShellSnapshot, id: uint32): Option[ShellWindow] =
  for win in snapshot.windows:
    if win.id == id:
      return some(win)
  none(ShellWindow)

proc activeLayoutId(snapshot: ShellSnapshot): string =
  snapshot.activeWorkspaceLayoutId()

proc scriptCommandPayload(msg: Msg): JsonNode =
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

proc scriptEvalPayload(evalResult: ScriptEvalResult): JsonNode =
  let commands = newJArray()
  for msg in evalResult.messages:
    commands.add(msg.scriptCommandPayload())
  result =
    %*{
      "event": evalResult.event,
      "outcome": evalResult.outcome.scriptOutcomeId(),
      "path": evalResult.path,
      "command_count": evalResult.messages.len,
      "commands": commands,
      "duration_ms": evalResult.durationMs,
    }
  if evalResult.error.len > 0:
    result["error"] = %evalResult.error
  if evalResult.currentWindow.isSome:
    result["current_window_id"] = %evalResult.currentWindow.get().id

proc shouldDispatchJanetScripts*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowCreated, MsgKind.WlWindowAdmissionSettled,
    MsgKind.WlWindowDestroyed, MsgKind.WlWindowTitle, MsgKind.WlWindowAppId,
    MsgKind.WlFocusChanged, MsgKind.WlSessionLocked, MsgKind.WlSessionUnlocked,
    MsgKind.CmdFocusTag, MsgKind.CmdFocusTagLeft, MsgKind.CmdFocusTagRight,
    MsgKind.CmdFocusOccupiedTagLeft, MsgKind.CmdFocusOccupiedTagRight,
    MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown, MsgKind.CmdMoveToTag,
    MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight,
    MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
    MsgKind.CmdMoveWindowDownOrToWorkspaceDown, MsgKind.CmdSetLayout,
    MsgKind.CmdSwitchLayout,
  }

proc addScriptEvent(
    events: var seq[tuple[name, source: string, currentWindow: Option[ShellWindow]]],
    name, source: string,
    currentWindow = none(ShellWindow),
) =
  events.add((name: name, source: source, currentWindow: currentWindow))

proc emptyEventStruct(kind: string): string =
  "{:kind " & kind.eventKeyword() & "}"

proc windowAppIdReady(appId: string): bool =
  let normalized = appId.strip().normalize()
  normalized.len > 0 and normalized notin ["unknown", "unset", "none"]

proc windowReadyEventStruct(windowId: uint32, win: Option[ShellWindow]): string =
  eventStruct(
    "window-ready",
    [("window-id", $windowId), ("window", win.windowExpr())],
  )

proc hookEvents(
    msg: Msg,
    before, after: ShellSnapshot,
    windowReadyEmitted: var HashSet[uint32],
): seq[tuple[name, source: string, currentWindow: Option[ShellWindow]]] =
  case msg.kind
  of MsgKind.WlWindowCreated:
    let win = after.windowById(msg.windowId)
    let fallback = ShellWindow(
      id: msg.windowId,
      pid: msg.createdPid,
      parentId: msg.createdParentWindowId,
      title: msg.title,
      appId: msg.appId,
      identifier: msg.createdIdentifier,
    )
    let currentWindow =
      if win.isSome:
        win
      else:
        some(fallback)
    result.addScriptEvent(
      "window-opened",
      eventStruct(
        "window-opened",
        [("window-id", $msg.windowId), ("window", currentWindow.windowExpr())],
      ),
      currentWindow,
    )
  of MsgKind.WlWindowAdmissionSettled:
    let win = after.windowById(msg.admissionWindowId)
    if win.isSome and win.get().appId.windowAppIdReady() and
        msg.admissionWindowId notin windowReadyEmitted:
      windowReadyEmitted.incl(msg.admissionWindowId)
      result.addScriptEvent(
        "window-ready",
        windowReadyEventStruct(msg.admissionWindowId, win),
        win,
      )
    result.addScriptEvent(
      "window-admitted",
      eventStruct(
        "window-admitted",
        [("window-id", $msg.admissionWindowId), ("window", win.windowExpr())],
      ),
      win,
    )
  of MsgKind.WlWindowDestroyed:
    let win = before.windowById(msg.destroyedId)
    result.addScriptEvent(
      "window-closed",
      eventStruct(
        "window-closed", [("window-id", $msg.destroyedId), ("window", win.windowExpr())]
      ),
      win,
    )
    windowReadyEmitted.excl(msg.destroyedId)
  of MsgKind.WlWindowTitle:
    let oldWin = before.windowById(msg.titleWindowId)
    let newWin = after.windowById(msg.titleWindowId)
    result.addScriptEvent(
      "window-title-changed",
      eventStruct(
        "window-title-changed",
        [
          ("window-id", $msg.titleWindowId),
          ("old-title", oldWin.windowTitle().escaped()),
          ("new-title", msg.updatedTitle.escaped()),
          ("old-window", oldWin.windowExpr()),
          ("new-window", newWin.windowExpr()),
        ],
      ),
      newWin,
    )
  of MsgKind.WlWindowAppId:
    let oldWin = before.windowById(msg.appIdWindowId)
    let newWin = after.windowById(msg.appIdWindowId)
    if msg.updatedAppId.windowAppIdReady() and
        msg.appIdWindowId notin windowReadyEmitted and newWin.isSome:
      windowReadyEmitted.incl(msg.appIdWindowId)
      result.addScriptEvent(
        "window-ready",
        windowReadyEventStruct(msg.appIdWindowId, newWin),
        newWin,
      )
    result.addScriptEvent(
      "window-app-id-changed",
      eventStruct(
        "window-app-id-changed",
        [
          ("window-id", $msg.appIdWindowId),
          ("old-app-id", oldWin.windowAppId().escaped()),
          ("new-app-id", msg.updatedAppId.escaped()),
          ("old-window", oldWin.windowExpr()),
          ("new-window", newWin.windowExpr()),
        ],
      ),
      newWin,
    )
  of MsgKind.WlFocusChanged:
    let oldWin = before.windowById(before.focusedWindowId())
    let newWin = after.windowById(after.focusedWindowId())
    result.addScriptEvent(
      "window-focus-changed",
      eventStruct(
        "window-focus-changed",
        [
          ("old-window-id", $before.focusedWindowId()),
          ("new-window-id", $after.focusedWindowId()),
          ("old-window", oldWin.windowExpr()),
          ("new-window", newWin.windowExpr()),
        ],
      ),
      newWin,
    )
  of MsgKind.WlSessionLocked:
    result.addScriptEvent("session-locked", emptyEventStruct("session-locked"))
  of MsgKind.WlSessionUnlocked:
    result.addScriptEvent("session-unlocked", emptyEventStruct("session-unlocked"))
  else:
    discard

  if before.activeTag != after.activeTag:
    result.addScriptEvent(
      "tag-changed",
      eventStruct(
        "tag-changed",
        [("old-tag-id", $before.activeTag), ("new-tag-id", $after.activeTag)],
      ),
    )

  let beforeLayout = before.activeLayoutId()
  let afterLayout = after.activeLayoutId()
  if beforeLayout != afterLayout:
    result.addScriptEvent(
      "layout-changed",
      eventStruct(
        "layout-changed",
        [
          ("old-layout", beforeLayout.escaped()),
          ("new-layout", afterLayout.escaped()),
          ("tag-id", $after.activeTag),
        ],
      ),
    )

proc collectJanetScriptMessages*(
    daemon: var TriadDaemon, msg: Msg, before, after: ShellSnapshot
): seq[QueuedMsg] =
  if daemon.janetRuntime.handle == nil:
    return @[]
  for ev in hookEvents(msg, before, after, daemon.windowReadyEmitted):
    let evalResults =
      daemon.janetRuntime.evalScriptsDetailed(ev.name, ev.source, after, ev.currentWindow)
    for evalResult in evalResults:
      writeBehaviorEvent("janet_script_eval", evalResult.scriptEvalPayload())
      for scriptMsg in evalResult.messages:
        result.add(QueuedMsg(msg: scriptMsg, origin: QueuedMsgOrigin.JanetHook))
