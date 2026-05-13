import std/[json, options, strutils]
import ../core/layout_mode_codec
import ../core/[msg, triad_state]
import ../types/[runtime_values, shell_snapshot]

type TriadIpcResult* = object
  handled*: bool
  subscribeLayout*: bool
  subscribeState*: bool
  reply*: string
  initialEvents*: seq[string]
  messages*: seq[Msg]

proc okReply(payload: JsonNode): string =
  $(%*{"ok": true, "triad": payload})

proc ackReply(): string =
  okReply(%*{"version": TriadIpcVersion, "type": "ack"})

proc errReply(message: string): string =
  $(%*{"ok": false, "error": message})

proc uintFromField(node: JsonNode, field: string): Option[uint32] =
  if node.kind != JObject or not node.hasKey(field):
    return none(uint32)
  try:
    if node[field].kind == JInt and node[field].getInt() > 0 and
        node[field].getInt() <= int(high(uint32)):
      return some(uint32(node[field].getInt()))
  except CatchableError:
    discard
  none(uint32)

proc stringFromField(node: JsonNode, field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc hasEvent(node: JsonNode, eventName: string): bool =
  if node.kind != JObject or not node.hasKey("events"):
    return eventName == "layout"
  let events = node["events"]
  if events.kind != JArray:
    return false
  for event in events:
    if event.kind == JString and event.getStr() == eventName:
      return true
  false

proc hasUnsupportedEvent(node: JsonNode): bool =
  if node.kind != JObject or not node.hasKey("events"):
    return false
  let events = node["events"]
  if events.kind != JArray:
    return true
  for event in events:
    if event.kind != JString:
      return true
    if event.getStr() notin ["layout", "state"]:
      return true
  false

proc tagForWorkspaceIndex(snapshot: ShellSnapshot, workspaceIdx: uint32): uint32 =
  for workspace in snapshot.workspaces:
    if workspace.workspaceIdx == workspaceIdx:
      return workspace.tagId
  0

proc intFromField(node: JsonNode, field: string): Option[int] =
  if node.kind != JObject or not node.hasKey(field):
    return none(int)
  try:
    if node[field].kind == JInt:
      return some(node[field].getInt())
  except:
    discard
  none(int)

proc floatFromField(node: JsonNode, field: string): Option[float] =
  if node.kind != JObject or not node.hasKey(field):
    return none(float)
  try:
    if node[field].kind == JFloat:
      return some(node[field].getFloat())
    if node[field].kind == JInt:
      return some(float(node[field].getInt()))
  except:
    discard
  none(float)

proc actionToMsg(
    action: string, payload: JsonNode, snapshot: ShellSnapshot
): Option[Msg] =
  case action
  of "focus-next":
    some(Msg(kind: MsgKind.CmdFocusNext))
  of "focus-prev":
    some(Msg(kind: MsgKind.CmdFocusPrev))
  of "focus-last":
    some(Msg(kind: MsgKind.CmdFocusLast))
  of "focus-left":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
  of "focus-right":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
  of "focus-up":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
  of "focus-down":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
  of "focus-tag-left":
    some(Msg(kind: MsgKind.CmdFocusTagLeft))
  of "focus-tag-right":
    some(Msg(kind: MsgKind.CmdFocusTagRight))
  of "focus-occupied-tag-left":
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagLeft))
  of "focus-occupied-tag-right":
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagRight))
  of "focus-column-first":
    some(Msg(kind: MsgKind.CmdFocusColumnFirst))
  of "focus-column-last":
    some(Msg(kind: MsgKind.CmdFocusColumnLast))
  of "focus-window-or-workspace-up":
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
  of "focus-window-or-workspace-down":
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
  of "toggle-overview":
    some(Msg(kind: MsgKind.CmdToggleOverview))
  of "open-overview":
    some(Msg(kind: MsgKind.CmdOpenOverview))
  of "close-overview":
    some(Msg(kind: MsgKind.CmdCloseOverview))
  of "toggle-scratchpad":
    some(Msg(kind: MsgKind.CmdToggleScratchpad))
  of "restore-scratchpad":
    some(Msg(kind: MsgKind.CmdRestoreScratchpad))
  of "select-window":
    some(Msg(kind: MsgKind.CmdSelectWindow))
  of "toggle-floating":
    some(Msg(kind: MsgKind.CmdToggleFloating))
  of "fullscreen-window":
    some(Msg(kind: MsgKind.CmdToggleFullscreen))
  of "toggle-fullscreen":
    some(Msg(kind: MsgKind.CmdToggleFullscreen))
  of "maximize-window-to-edges":
    some(Msg(kind: MsgKind.CmdToggleMaximized))
  of "toggle-maximized":
    some(Msg(kind: MsgKind.CmdToggleMaximized))
  of "zoom":
    some(Msg(kind: MsgKind.CmdZoom))
  of "maximize-column":
    some(Msg(kind: MsgKind.CmdMaximizeColumn))
  of "toggle-gaps":
    some(Msg(kind: MsgKind.CmdToggleGaps))
  of "consume-window":
    some(Msg(kind: MsgKind.CmdConsumeWindow))
  of "expel-window":
    some(Msg(kind: MsgKind.CmdExpelWindow))
  of "group-windows":
    some(Msg(kind: MsgKind.CmdGroupWindows))
  of "ungroup-window":
    some(Msg(kind: MsgKind.CmdUngroupWindow))
  of "focus-next-in-group":
    some(Msg(kind: MsgKind.CmdFocusNextInGroup))
  of "lock-session":
    some(Msg(kind: MsgKind.CmdLockSession))
  of "triad-reload":
    some(Msg(kind: MsgKind.CmdTriadReload))
  of "config-reload":
    some(Msg(kind: MsgKind.CmdConfigReload))
  of "switch-layout":
    some(Msg(kind: MsgKind.CmdSwitchLayout))
  of "move-column-left":
    some(Msg(kind: MsgKind.CmdMoveColumnLeft))
  of "move-column-right":
    some(Msg(kind: MsgKind.CmdMoveColumnRight))
  of "move-column-to-first":
    some(Msg(kind: MsgKind.CmdMoveColumnToFirst))
  of "move-column-to-last":
    some(Msg(kind: MsgKind.CmdMoveColumnToLast))
  of "move-window-left":
    some(Msg(kind: MsgKind.CmdMoveWindowLeft))
  of "move-window-right":
    some(Msg(kind: MsgKind.CmdMoveWindowRight))
  of "move-window-up":
    some(Msg(kind: MsgKind.CmdMoveWindowUp))
  of "move-window-down":
    some(Msg(kind: MsgKind.CmdMoveWindowDown))
  of "move-window-up-or-to-workspace-up":
    some(Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp))
  of "move-window-down-or-to-workspace-down":
    some(Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown))
  of "focus-tag":
    let t = uintFromField(payload, "tag")
    if t.isSome:
      some(Msg(kind: MsgKind.CmdFocusTag, focusTag: t.get()))
    else:
      none(Msg)
  of "move-to-tag":
    let t = uintFromField(payload, "tag")
    if t.isSome:
      some(Msg(kind: MsgKind.CmdMoveToTag, targetTag: t.get()))
    else:
      none(Msg)
  of "focus-workspace":
    let i = uintFromField(payload, "workspace_idx")
    if i.isSome:
      some(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: i.get()))
    else:
      none(Msg)
  of "move-to-workspace":
    let i = uintFromField(payload, "workspace_idx")
    if i.isSome:
      some(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: i.get()))
    else:
      none(Msg)
  of "focus-window":
    let id = uintFromField(payload, "id")
    if id.isSome:
      some(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: WindowId(id.get())))
    else:
      none(Msg)
  of "close-window":
    let id = uintFromField(payload, "id")
    if id.isSome:
      some(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: WindowId(id.get())))
    else:
      some(Msg(kind: MsgKind.CmdCloseWindow))
  of "rename-tag":
    let name = stringFromField(payload, "name")
    if name.len > 0:
      some(Msg(kind: MsgKind.CmdRenameTag, newName: name))
    else:
      none(Msg)
  of "toggle-named-scratchpad":
    let name = stringFromField(payload, "name")
    if name.len > 0:
      some(Msg(kind: MsgKind.CmdToggleNamedScratchpad, scratchpadName: name))
    else:
      none(Msg)
  of "move-to-named-scratchpad":
    let name = stringFromField(payload, "name")
    if name.len > 0:
      some(Msg(kind: MsgKind.CmdMoveToNamedScratchpad, scratchpadName: name))
    else:
      none(Msg)
  of "resize-width":
    let d = floatFromField(payload, "delta")
    if d.isSome:
      some(Msg(kind: MsgKind.CmdResizeWidth, deltaW: d.get()))
    else:
      none(Msg)
  of "resize-height":
    let d = floatFromField(payload, "delta")
    if d.isSome:
      some(Msg(kind: MsgKind.CmdResizeHeight, deltaH: d.get()))
    else:
      none(Msg)
  of "adjust-master-ratio":
    let d = floatFromField(payload, "delta")
    if d.isSome:
      some(Msg(kind: MsgKind.CmdAdjustMasterRatio, deltaMR: d.get()))
    else:
      none(Msg)
  of "master-ratio":
    let v = floatFromField(payload, "value")
    if v.isSome:
      some(Msg(kind: MsgKind.CmdSetMasterRatio, ratio: v.get()))
    else:
      none(Msg)
  of "adjust-gaps":
    let d = floatFromField(payload, "delta")
    if d.isSome:
      some(Msg(kind: MsgKind.CmdAdjustGaps, deltaG: int32(d.get())))
    else:
      none(Msg)
  of "master-count":
    let c = intFromField(payload, "count")
    if c.isSome:
      some(Msg(kind: MsgKind.CmdSetMasterCount, count: c.get()))
    else:
      none(Msg)
  of "adjust-master-count":
    let d = intFromField(payload, "delta")
    if d.isSome:
      some(Msg(kind: MsgKind.CmdAdjustMasterCount, deltaMC: d.get()))
    else:
      none(Msg)
  of "move-floating":
    let dx = floatFromField(payload, "dx")
    let dy = floatFromField(payload, "dy")
    if dx.isSome and dy.isSome:
      some(
        Msg(
          kind: MsgKind.CmdMoveFloating,
          moveDX: int32(dx.get()),
          moveDY: int32(dy.get()),
        )
      )
    else:
      none(Msg)
  of "resize-floating":
    let dw = floatFromField(payload, "dw")
    let dh = floatFromField(payload, "dh")
    if dw.isSome and dh.isSome:
      some(
        Msg(
          kind: MsgKind.CmdResizeFloating,
          deltaFW: int32(dw.get()),
          deltaFH: int32(dh.get()),
        )
      )
    else:
      none(Msg)
  else:
    none(Msg)

proc targetTagFromPayload(
    payload: JsonNode, snapshot: ShellSnapshot
): tuple[ok: bool, tag: uint32, error: string] =
  if payload.kind != JObject or not payload.hasKey("target"):
    return (true, 0'u32, "")
  let target = payload["target"]
  if target.kind != JObject:
    return (false, 0'u32, "target must be an object")

  let tag = uintFromField(target, "tag")
  if tag.isSome:
    return (true, tag.get(), "")

  let idx = uintFromField(target, "workspace_idx")
  if idx.isSome:
    let mapped = snapshot.tagForWorkspaceIndex(idx.get())
    if mapped != 0:
      return (true, mapped, "")
    return (false, 0'u32, "unknown workspace_idx: " & $idx.get())

  (false, 0'u32, "target must contain tag or workspace_idx")

proc handleTriadRequest*(line: string, snapshot: ShellSnapshot): TriadIpcResult =
  result.handled = false
  let stripped = line.strip()
  if stripped.len == 0 or stripped[0] != '{':
    return

  var root: JsonNode
  try:
    root = parseJson(stripped)
  except CatchableError:
    return

  if root.kind != JObject or not root.hasKey("triad"):
    return

  result.handled = true
  let payload = root["triad"]
  if payload.kind != JObject:
    result.reply = errReply("triad request must be an object")
    return

  let version = uintFromField(payload, "version")
  if version.isNone or version.get() != TriadIpcVersion:
    result.reply = errReply("unsupported triad ipc version")
    return

  let request = stringFromField(payload, "request")
  case request
  of "state":
    result.reply = okReply(
      %*{"version": TriadIpcVersion, "type": "state", "state": triadStateJson(snapshot)}
    )
  of "layout-state":
    result.reply = okReply(
      %*{
        "version": TriadIpcVersion,
        "type": "layout-state",
        "state": triadLayoutStateJson(snapshot),
      }
    )
  of "set-layout":
    let layoutId = stringFromField(payload, "layout")
    let layout = parseLayoutModeId(layoutId)
    if layout.isNone:
      result.reply = errReply("unknown layout: " & layoutId)
      return

    let target = targetTagFromPayload(payload, snapshot)
    if not target.ok:
      result.reply = errReply(target.error)
      return

    result.messages.add(
      Msg(
        kind: MsgKind.CmdSetLayout, newLayout: layout.get(), layoutTargetTag: target.tag
      )
    )
    result.reply = ackReply()
  of "switch-layout":
    result.messages.add(Msg(kind: MsgKind.CmdSwitchLayout))
    result.reply = ackReply()
  of "event-stream":
    if payload.hasUnsupportedEvent() or
        (not payload.hasEvent("layout") and not payload.hasEvent("state")):
      result.reply = errReply("unsupported event stream")
      return
    result.subscribeLayout = payload.hasEvent("layout")
    result.subscribeState = payload.hasEvent("state")
    result.reply = ackReply()
    if result.subscribeLayout:
      result.initialEvents.add(triadLayoutStateChangedEvent(snapshot))
    if result.subscribeState:
      result.initialEvents.add(triadStateChangedEvent(snapshot))
  of "action":
    let action = stringFromField(payload, "action")
    if action.len == 0:
      result.reply = errReply("action name required")
      return
    let msgOpt = actionToMsg(action, payload, snapshot)
    if msgOpt.isNone:
      result.reply = errReply("unknown action or bad parameters: " & action)
      return
    result.messages.add(msgOpt.get())
    result.reply = ackReply()
  else:
    result.reply = errReply("unsupported triad request: " & request)
