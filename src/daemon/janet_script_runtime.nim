import std/[json, options, sets, strutils]
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../core/[msg, shell_focus]
import ../janet/[runtime as janet_runtime, snapshot_api]
import ../types/[janet_manifest, model, runtime_values, shell_snapshot]
import ../utils/[behavior_log]
import state

type
  JanetScriptEvent = tuple[name, source: string, currentWindow: Option[ShellWindow]]

  JanetUiHookState* = object
    overviewActive*: bool
    overviewSelectedWindow*: uint32
    recentWindowsActive*: bool
    recentWindowsSelectedWindow*: uint32
    recentWindowsScope*: RecentWindowScope
    recentWindowsFilter*: RecentWindowFilter
    recentWindowsAppIdFilter*: string
    hotkeyOverlayOpen*: bool
    exitSessionConfirmOpen*: bool
    layoutSwitchToastOpen*: bool
    layoutSwitchToastLayout*: LayoutMode
    layoutSwitchToastCustomLayout*: string
    layoutSwitchToastNativeLayout*: string

var suppressedNoopTitleHookLogs = 0

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

proc outputExpr(output: Option[ShellOutput]): string =
  if output.isSome:
    output.get().janetOutputExpr()
  else:
    "nil"

proc outputById(snapshot: ShellSnapshot, id: uint32): Option[ShellOutput] =
  for output in snapshot.outputs:
    if output.id == id:
      return some(output)
  none(ShellOutput)

proc isRealOutput(output: ShellOutput): bool =
  output.id != 0

proc activeLayoutId(snapshot: ShellSnapshot): string =
  snapshot.activeWorkspaceLayoutId()

proc recentScopeId(scope: RecentWindowScope): string =
  case scope
  of RecentWindowScope.All: "all"
  of RecentWindowScope.Workspace: "workspace"
  of RecentWindowScope.Output: "output"

proc recentFilterId(filter: RecentWindowFilter): string =
  case filter
  of RecentWindowFilter.All: "all"
  of RecentWindowFilter.AppId: "app-id"

proc janetUiHookState*(model: Model): JanetUiHookState =
  JanetUiHookState(
    overviewActive: model.overviewActive,
    overviewSelectedWindow: uint32(model.overviewSelectedWindow),
    recentWindowsActive: model.recentWindowsActive,
    recentWindowsSelectedWindow: uint32(model.recentWindowsSelectedWindow),
    recentWindowsScope: model.recentWindowsScope,
    recentWindowsFilter: model.recentWindowsFilter,
    recentWindowsAppIdFilter: model.recentWindowsAppIdFilter,
    hotkeyOverlayOpen: model.hotkeyOverlayOpen,
    exitSessionConfirmOpen: model.exitSessionConfirmOpen,
    layoutSwitchToastOpen: model.layoutSwitchToastOpen,
    layoutSwitchToastLayout: model.layoutSwitchToastLayout,
    layoutSwitchToastCustomLayout: model.layoutSwitchToastCustomLayout.layoutIdString(),
    layoutSwitchToastNativeLayout:
      model.layoutSwitchToastNativeLayout.nativeLayoutIdString(),
  )

proc layoutSwitchToastLabel(state: JanetUiHookState): string =
  if state.layoutSwitchToastCustomLayout.len > 0:
    return state.layoutSwitchToastCustomLayout
  if state.layoutSwitchToastNativeLayout.len > 0:
    return state.layoutSwitchToastNativeLayout
  state.layoutSwitchToastLayout.behaviorLayoutId()

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
  of MsgKind.CmdSetCustomLayout:
    result["layout"] = %msg.customLayout.layoutIdString()
    result["layout_kind"] = %"custom"
    if msg.customLayoutTargetTag != 0:
      result["target_tag"] = %msg.customLayoutTargetTag
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

proc shouldSuppressScriptEvalLog(evalResult: ScriptEvalResult): bool =
  evalResult.event == "window-title-changed" and
    evalResult.outcome == ScriptOutcome.Evaluated and evalResult.messages.len == 0 and
    evalResult.error.len == 0

proc writeScriptEvalEvent(evalResult: ScriptEvalResult) =
  if evalResult.shouldSuppressScriptEvalLog():
    inc suppressedNoopTitleHookLogs
    return

  let payload = evalResult.scriptEvalPayload()
  if suppressedNoopTitleHookLogs > 0:
    payload["suppressed_noop_title_count"] = %suppressedNoopTitleHookLogs
    suppressedNoopTitleHookLogs = 0
  writeBehaviorEvent("janet_script_eval", payload)

proc shouldDispatchJanetScripts*(kind: MsgKind): bool =
  kind in {
    MsgKind.WlWindowCreated, MsgKind.WlWindowAdmissionSettled,
    MsgKind.WlWindowDestroyed, MsgKind.WlWindowTitle, MsgKind.WlWindowAppId,
    MsgKind.WlFocusChanged, MsgKind.WlSessionLocked, MsgKind.WlSessionUnlocked,
    MsgKind.WlOutputDimensions, MsgKind.WlOutputName, MsgKind.WlOutputIdentity,
    MsgKind.WlOutputDescription, MsgKind.WlOutputPosition, MsgKind.WlOutputRefreshRate,
    MsgKind.WlOutputRemoved, MsgKind.CmdFocusTag, MsgKind.CmdFocusTagLeft,
    MsgKind.CmdFocusTagRight, MsgKind.CmdFocusOccupiedTagLeft,
    MsgKind.CmdFocusOccupiedTagRight, MsgKind.CmdFocusWorkspaceIndex,
    MsgKind.CmdNewWorkspace, MsgKind.CmdFocusWindowOrWorkspaceUp,
    MsgKind.CmdFocusWindowOrWorkspaceDown, MsgKind.CmdMoveToTag,
    MsgKind.CmdMoveToTagLeft, MsgKind.CmdMoveToTagRight,
    MsgKind.CmdMoveToWorkspaceIndex, MsgKind.CmdMoveWindowUpOrToWorkspaceUp,
    MsgKind.CmdMoveWindowDownOrToWorkspaceDown, MsgKind.CmdSetLayout,
    MsgKind.CmdSetCustomLayout, MsgKind.CmdSwitchLayout,
  }

proc shouldDispatchJanetUiScripts*(origin: QueuedMsgOrigin): bool =
  origin != QueuedMsgOrigin.JanetHook

proc addScriptEvent(
    events: var seq[JanetScriptEvent],
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
  eventStruct("window-ready", [("window-id", $windowId), ("window", win.windowExpr())])

proc addOutputLifecycleEvents(
    events: var seq[JanetScriptEvent], before, after: ShellSnapshot
) =
  for output in after.outputs:
    if not output.isRealOutput():
      continue
    let oldOutput = before.outputById(output.id)
    if oldOutput.isNone:
      events.addScriptEvent(
        "output-added",
        eventStruct(
          "output-added",
          [
            ("output-id", $output.id),
            ("output", some(output).outputExpr()),
            ("old-output", "nil"),
          ],
        ),
      )
    elif oldOutput.get() != output:
      events.addScriptEvent(
        "output-changed",
        eventStruct(
          "output-changed",
          [
            ("output-id", $output.id),
            ("output", some(output).outputExpr()),
            ("old-output", oldOutput.outputExpr()),
          ],
        ),
      )

  for output in before.outputs:
    if not output.isRealOutput():
      continue
    if after.outputById(output.id).isNone:
      events.addScriptEvent(
        "output-removed",
        eventStruct(
          "output-removed",
          [
            ("output-id", $output.id),
            ("output", "nil"),
            ("old-output", some(output).outputExpr()),
          ],
        ),
      )

proc hookEvents(
    msg: Msg, before, after: ShellSnapshot, windowReadyEmitted: var HashSet[uint32]
): seq[JanetScriptEvent] =
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
        "window-ready", windowReadyEventStruct(msg.admissionWindowId, win), win
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
    if msg.updatedAppId.windowAppIdReady() and msg.appIdWindowId notin windowReadyEmitted and
        newWin.isSome:
      windowReadyEmitted.incl(msg.appIdWindowId)
      result.addScriptEvent(
        "window-ready", windowReadyEventStruct(msg.appIdWindowId, newWin), newWin
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
  of MsgKind.WlOutputDimensions, MsgKind.WlOutputName, MsgKind.WlOutputIdentity,
      MsgKind.WlOutputDescription, MsgKind.WlOutputPosition,
      MsgKind.WlOutputRefreshRate, MsgKind.WlOutputRemoved:
    result.addOutputLifecycleEvents(before, after)
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

proc uiHookEvents(before, after: JanetUiHookState): seq[JanetScriptEvent] =
  if before.overviewActive != after.overviewActive:
    let name = if after.overviewActive: "overview-opened" else: "overview-closed"
    result.addScriptEvent(
      name,
      eventStruct(
        name,
        [
          ("active", $after.overviewActive),
          ("selected-window-id", $after.overviewSelectedWindow),
        ],
      ),
    )

  if before.recentWindowsActive != after.recentWindowsActive:
    let name =
      if after.recentWindowsActive: "recent-windows-opened" else: "recent-windows-closed"
    result.addScriptEvent(
      name,
      eventStruct(
        name,
        [
          ("active", $after.recentWindowsActive),
          ("selected-window-id", $after.recentWindowsSelectedWindow),
          ("scope", after.recentWindowsScope.recentScopeId().escaped()),
          ("filter", after.recentWindowsFilter.recentFilterId().escaped()),
          ("app-id-filter", after.recentWindowsAppIdFilter.escaped()),
        ],
      ),
    )

  if before.hotkeyOverlayOpen != after.hotkeyOverlayOpen:
    let name =
      if after.hotkeyOverlayOpen: "hotkey-overlay-opened" else: "hotkey-overlay-closed"
    result.addScriptEvent(
      name, eventStruct(name, [("active", $after.hotkeyOverlayOpen)])
    )

  if before.exitSessionConfirmOpen != after.exitSessionConfirmOpen:
    let name =
      if after.exitSessionConfirmOpen:
        "exit-session-confirm-opened"
      else:
        "exit-session-confirm-closed"
    result.addScriptEvent(
      name, eventStruct(name, [("active", $after.exitSessionConfirmOpen)])
    )

  if before.layoutSwitchToastOpen != after.layoutSwitchToastOpen:
    let name =
      if after.layoutSwitchToastOpen:
        "layout-switch-toast-opened"
      else:
        "layout-switch-toast-closed"
    result.addScriptEvent(
      name,
      eventStruct(
        name,
        [
          ("active", $after.layoutSwitchToastOpen),
          ("layout", after.layoutSwitchToastLabel().escaped()),
        ],
      ),
    )

proc collectScriptMessages(
    daemon: var TriadDaemon, events: seq[JanetScriptEvent], snapshot: ShellSnapshot
): seq[QueuedMsg] =
  if daemon.janetRuntime.handle == nil:
    return @[]
  for ev in events:
    let evalResults = daemon.janetRuntime.evalScriptsDetailed(
      ev.name, ev.source, snapshot, ev.currentWindow
    )
    for evalResult in evalResults:
      evalResult.writeScriptEvalEvent()
      for scriptMsg in evalResult.messages:
        result.add(QueuedMsg(msg: scriptMsg, origin: QueuedMsgOrigin.JanetHook))

proc collectJanetScriptMessages*(
    daemon: var TriadDaemon, msg: Msg, before, after: ShellSnapshot
): seq[QueuedMsg] =
  let events = hookEvents(msg, before, after, daemon.windowReadyEmitted)
  daemon.collectScriptMessages(events, after)

proc collectJanetUiScriptMessages*(
    daemon: var TriadDaemon, before, after: JanetUiHookState, snapshot: ShellSnapshot
): seq[QueuedMsg] =
  daemon.collectScriptMessages(uiHookEvents(before, after), snapshot)
