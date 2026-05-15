import std/[json, options, strutils]
import ../core/layout_mode_codec
import ../core/[msg, triad_state]
import command_registry
import commands
import ../types/shell_snapshot

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

proc boolFromField(node: JsonNode, field: string): Option[bool] =
  if node.kind != JObject or not node.hasKey(field):
    return none(bool)
  if node[field].kind == JBool:
    return some(node[field].getBool())
  none(bool)

proc numberStringFromField(node: JsonNode, field: string): Option[string] =
  if node.kind != JObject or not node.hasKey(field):
    return none(string)
  case node[field].kind
  of JInt:
    some($node[field].getInt())
  of JFloat:
    some($node[field].getFloat())
  else:
    none(string)

proc intStringFromField(node: JsonNode, field: string): Option[string] =
  let value = intFromField(node, field)
  if value.isSome:
    some($value.get())
  else:
    none(string)

proc uintStringFromField(node: JsonNode, field: string): Option[string] =
  let value = uintFromField(node, field)
  if value.isSome:
    some($value.get())
  else:
    none(string)

proc argvFromField(node: JsonNode, field: string): Option[seq[string]] =
  if node.kind != JObject or not node.hasKey(field) or node[field].kind != JArray:
    return none(seq[string])
  var argv: seq[string] = @[]
  for arg in node[field]:
    if arg.kind != JString:
      return none(seq[string])
    argv.add(arg.getStr())
  if argv.len == 0:
    return none(seq[string])
  some(argv)

proc commandPartsForAction(action: string, payload: JsonNode): Option[seq[string]] =
  let specOpt = resolveCommandSpec(action)
  if specOpt.isNone:
    return none(seq[string])

  let spec = specOpt.get()
  var parts = @[spec.name]
  case spec.argShape
  of CommandArgShape.NoArgs:
    some(parts)
  of CommandArgShape.OptionalWindowId:
    let id = uintFromField(payload, "id")
    if id.isSome:
      parts.add($id.get())
    some(parts)
  of CommandArgShape.RequiredWindowId:
    let id = uintFromField(payload, "id")
    if id.isSome:
      parts.add($id.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredTag:
    let tag = uintStringFromField(payload, "tag")
    if tag.isSome:
      parts.add(tag.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredWorkspaceIdx:
    let index = uintStringFromField(payload, "workspace_idx")
    if index.isSome:
      parts.add(index.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredName:
    let name = stringFromField(payload, "name")
    if name.len > 0:
      parts.add(name)
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredOutput:
    let output = stringFromField(payload, "output")
    if output.len > 0:
      parts.add(output)
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredFloatDelta:
    let delta = numberStringFromField(payload, "delta")
    if delta.isSome:
      parts.add(delta.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredFloatValue:
    var value = numberStringFromField(payload, "value")
    if spec.id == CommandId.CidSetColumnWidth and value.isNone:
      value = numberStringFromField(payload, "width")
    if value.isSome:
      parts.add(value.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredIntCount:
    let count = intStringFromField(payload, "count")
    if count.isSome:
      parts.add(count.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RequiredIntDelta:
    let delta = intStringFromField(payload, "delta")
    if delta.isSome:
      parts.add(delta.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.OptionalIntDelta:
    let delta = intStringFromField(payload, "delta")
    if delta.isSome:
      parts.add(delta.get())
    some(parts)
  of CommandArgShape.MoveDelta:
    let dx = intStringFromField(payload, "dx")
    let dy = intStringFromField(payload, "dy")
    if dx.isSome and dy.isSome:
      parts.add(dx.get())
      parts.add(dy.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.ResizeDelta:
    let dw = intStringFromField(payload, "dw")
    let dh = intStringFromField(payload, "dh")
    if dw.isSome and dh.isSome:
      parts.add(dw.get())
      parts.add(dh.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.RecentAdvance:
    let scope = stringFromField(payload, "scope")
    if scope.len > 0:
      parts.add("--scope")
      parts.add(scope)
    let filter = stringFromField(payload, "filter")
    if filter.len > 0:
      parts.add("--filter")
      parts.add(filter)
    some(parts)
  of CommandArgShape.RecentScope:
    let scope = stringFromField(payload, "scope")
    if scope.len > 0:
      parts.add(scope)
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.SpawnArgv:
    let argv = argvFromField(payload, "argv")
    if argv.isSome:
      parts.add(argv.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.WarpPointer:
    let x = intStringFromField(payload, "x")
    let y = intStringFromField(payload, "y")
    if x.isSome and y.isSome:
      parts.add(x.get())
      parts.add(y.get())
      some(parts)
    else:
      none(seq[string])
  of CommandArgShape.Screenshot:
    let path = stringFromField(payload, "path")
    if path.len > 0:
      parts.add("--path")
      parts.add(path)
    if payload.hasKey("show_pointer"):
      let show = boolFromField(payload, "show_pointer")
      if show.isNone:
        return none(seq[string])
      if show.get():
        parts.add("--show-pointer")
      else:
        parts.add("--hide-pointer")
    var writeToDisk = true
    var copyToClipboard = true
    if payload.hasKey("write_to_disk"):
      let write = boolFromField(payload, "write_to_disk")
      if write.isNone:
        return none(seq[string])
      writeToDisk = write.get()
    if payload.hasKey("copy_to_clipboard"):
      let copy = boolFromField(payload, "copy_to_clipboard")
      if copy.isNone:
        return none(seq[string])
      copyToClipboard = copy.get()
    if not writeToDisk and not copyToClipboard:
      none(seq[string])
    else:
      if writeToDisk and not copyToClipboard:
        parts.add("--no-clipboard")
      elif not writeToDisk and copyToClipboard:
        parts.add("--clipboard-only")
      some(parts)

proc actionToMsg(action: string, payload: JsonNode): Option[Msg] =
  let parts = commandPartsForAction(action, payload)
  if parts.isNone:
    return none(Msg)
  parseCommandParts(parts.get())

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
    let msgOpt = actionToMsg(action, payload)
    if msgOpt.isNone:
      result.reply = errReply("unknown action or bad parameters: " & action)
      return
    result.messages.add(msgOpt.get())
    result.reply = ackReply()
  else:
    result.reply = errReply("unsupported triad request: " & request)
