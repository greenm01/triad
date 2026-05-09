import json, options, strutils
import ../core/msg
import ../core/triad_state
import ../types/shell_snapshot

type
  TriadIpcResult* = object
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

proc uintFromField(node: JsonNode; field: string): Option[uint32] =
  if node.kind != JObject or not node.hasKey(field):
    return none(uint32)
  try:
    if node[field].kind == JInt and node[field].getInt() > 0 and node[field].getInt() <= int(high(uint32)):
      return some(uint32(node[field].getInt()))
  except CatchableError:
    discard
  none(uint32)

proc stringFromField(node: JsonNode; field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc hasEvent(node: JsonNode; eventName: string): bool =
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

proc tagForWorkspaceIndex(snapshot: ShellSnapshot; workspaceIdx: uint32): uint32 =
  for workspace in snapshot.workspaces:
    if workspace.workspaceIdx == workspaceIdx:
      return workspace.tagId
  0

proc targetTagFromPayload(payload: JsonNode; snapshot: ShellSnapshot): tuple[ok: bool, tag: uint32, error: string] =
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

proc handleTriadRequest*(line: string; snapshot: ShellSnapshot): TriadIpcResult =
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
    result.reply = okReply(%*{
      "version": TriadIpcVersion,
      "type": "state",
      "state": triadStateJson(snapshot)
    })

  of "layout-state":
    result.reply = okReply(%*{
      "version": TriadIpcVersion,
      "type": "layout-state",
      "state": triadLayoutStateJson(snapshot)
    })

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

    result.messages.add(Msg(kind: CmdSetLayout, newLayout: layout.get(), layoutTargetTag: target.tag))
    result.reply = ackReply()

  of "switch-layout":
    result.messages.add(Msg(kind: CmdSwitchLayout))
    result.reply = ackReply()

  of "event-stream":
    if payload.hasUnsupportedEvent() or (not payload.hasEvent("layout") and not payload.hasEvent("state")):
      result.reply = errReply("unsupported event stream")
      return
    result.subscribeLayout = payload.hasEvent("layout")
    result.subscribeState = payload.hasEvent("state")
    result.reply = ackReply()
    if result.subscribeLayout:
      result.initialEvents.add(triadLayoutStateChangedEvent(snapshot))
    if result.subscribeState:
      result.initialEvents.add(triadStateChangedEvent(snapshot))

  else:
    result.reply = errReply("unsupported triad request: " & request)
