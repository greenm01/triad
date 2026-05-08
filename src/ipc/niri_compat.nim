import json, options, strutils, tables
import ../core/model
import ../core/model_utils
import ../core/msg
import ../core/niri_state

type
  NiriIpcResult* = object
    handled*: bool
    subscribe*: bool
    reply*: string
    initialEvents*: seq[string]
    messages*: seq[Msg]

proc okReply(payload: JsonNode): string =
  $(%*{"Ok": payload})

proc errReply(message: string): string =
  $(%*{"Err": message})

proc uintFromNode(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() > 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc boolFromNode(node: JsonNode; fallback = false): bool =
  try:
    if node.kind == JBool:
      return node.getBool()
  except CatchableError:
    discard
  fallback

proc stringFromField(node: JsonNode; field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc boolFromField(node: JsonNode; field: string; fallback = false): bool =
  if node.kind == JObject and node.hasKey(field):
    boolFromNode(node[field], fallback)
  else:
    fallback

proc nextTag(model: Model; direction: int): Option[uint32] =
  let ids = model.visibleWorkspaceIds()
  if ids.len == 0:
    return none(uint32)

  let active = model.activeTagOrFallback()
  var idx = ids.find(active)
  if idx == -1:
    idx = 0
  if direction < 0:
    return some(ids[max(0, idx - 1)])
  if idx < ids.len - 1:
    return some(ids[idx + 1])
  some(ids[^1])

proc actionMessages(action: JsonNode; model: Model): tuple[handled: bool, messages: seq[Msg]] =
  if action.kind != JObject:
    return (false, @[])

  if action.hasKey("FocusWorkspace"):
    let payload = action["FocusWorkspace"]
    if payload.kind == JObject and payload.hasKey("reference"):
      let refNode = payload["reference"]
      if refNode.kind == JObject:
        if refNode.hasKey("Index"):
          let index = uintFromNode(refNode["Index"])
          if index.isSome:
            return (true, @[Msg(kind: CmdFocusWorkspaceIndex, workspaceIndex: index.get())])
        elif refNode.hasKey("Id"):
          let tag = uintFromNode(refNode["Id"])
          if tag.isSome: return (true, @[Msg(kind: CmdFocusTag, focusTag: tag.get())])

  elif action.hasKey("FocusWorkspaceDown"):
    let tag = nextTag(model, 1)
    if tag.isSome: return (true, @[Msg(kind: CmdFocusTag, focusTag: tag.get())])

  elif action.hasKey("FocusWorkspaceUp"):
    let tag = nextTag(model, -1)
    if tag.isSome: return (true, @[Msg(kind: CmdFocusTag, focusTag: tag.get())])

  elif action.hasKey("ToggleOverview"):
    return (true, @[Msg(kind: CmdToggleOverview)])

  elif action.hasKey("OpenOverview"):
    return (true, @[Msg(kind: CmdOpenOverview)])

  elif action.hasKey("CloseOverview"):
    return (true, @[Msg(kind: CmdCloseOverview)])

  elif action.hasKey("FocusColumnLeft"):
    return (true, @[Msg(kind: CmdFocusDirection, direction: DirLeft)])

  elif action.hasKey("FocusColumnRight"):
    return (true, @[Msg(kind: CmdFocusDirection, direction: DirRight)])

  elif action.hasKey("FocusColumnFirst"):
    return (true, @[Msg(kind: CmdFocusColumnFirst)])

  elif action.hasKey("FocusColumnLast"):
    return (true, @[Msg(kind: CmdFocusColumnLast)])

  elif action.hasKey("FocusWindowUp"):
    return (true, @[Msg(kind: CmdFocusDirection, direction: DirUp)])

  elif action.hasKey("FocusWindowDown"):
    return (true, @[Msg(kind: CmdFocusDirection, direction: DirDown)])

  elif action.hasKey("FocusWindowOrWorkspaceUp"):
    return (true, @[Msg(kind: CmdFocusWindowOrWorkspaceUp)])

  elif action.hasKey("FocusWindowOrWorkspaceDown"):
    return (true, @[Msg(kind: CmdFocusWindowOrWorkspaceDown)])

  elif action.hasKey("MoveColumnLeft"):
    return (true, @[Msg(kind: CmdMoveColumnLeft)])

  elif action.hasKey("MoveColumnRight"):
    return (true, @[Msg(kind: CmdMoveColumnRight)])

  elif action.hasKey("MoveColumnToFirst"):
    return (true, @[Msg(kind: CmdMoveColumnToFirst)])

  elif action.hasKey("MoveColumnToLast"):
    return (true, @[Msg(kind: CmdMoveColumnToLast)])

  elif action.hasKey("MoveWindowUp"):
    return (true, @[Msg(kind: CmdMoveWindowUp)])

  elif action.hasKey("MoveWindowDown"):
    return (true, @[Msg(kind: CmdMoveWindowDown)])

  elif action.hasKey("MoveWindowUpOrToWorkspaceUp"):
    return (true, @[Msg(kind: CmdMoveWindowUpOrToWorkspaceUp)])

  elif action.hasKey("MoveWindowDownOrToWorkspaceDown"):
    return (true, @[Msg(kind: CmdMoveWindowDownOrToWorkspaceDown)])

  elif action.hasKey("MoveWindowLeft"):
    return (true, @[Msg(kind: CmdMoveWindowLeft)])

  elif action.hasKey("MoveWindowRight"):
    return (true, @[Msg(kind: CmdMoveWindowRight)])

  elif action.hasKey("FocusWindow"):
    let payload = action["FocusWindow"]
    if payload.kind == JObject and payload.hasKey("id") and payload["id"].kind != JNull:
      let win = uintFromNode(payload["id"])
      if win.isSome: return (true, @[Msg(kind: CmdFocusWindowById, focusWindowId: WindowId(win.get()))])

  elif action.hasKey("CloseWindow"):
    let payload = action["CloseWindow"]
    if payload.kind == JObject and payload.hasKey("id") and payload["id"].kind != JNull:
      let win = uintFromNode(payload["id"])
      if win.isSome: return (true, @[Msg(kind: CmdCloseWindowById, closeWindowId: WindowId(win.get()))])
    return (true, @[Msg(kind: CmdCloseWindow)])

  elif action.hasKey("SwitchLayout"):
    return (true, @[Msg(kind: CmdSwitchLayout)])

  elif action.hasKey("SetWorkspaceName"):
    let payload = action["SetWorkspaceName"]
    return (true, @[Msg(kind: CmdRenameTag, newName: stringFromField(payload, "name"))])

  elif action.hasKey("UnsetWorkspaceName"):
    return (true, @[Msg(kind: CmdRenameTag, newName: "")])

  elif action.hasKey("FullscreenWindow"):
    return (true, @[Msg(kind: CmdToggleFullscreen)])

  elif action.hasKey("ToggleWindowFloating"):
    return (true, @[Msg(kind: CmdToggleFloating)])

  elif action.hasKey("Screenshot"):
    let payload = action["Screenshot"]
    return (true, @[Msg(
      kind: CmdScreenshot,
      screenshotKind: ShotRegion,
      screenshotPath: stringFromField(payload, "path"),
      screenshotShowPointer: boolFromField(payload, "show_pointer", boolFromField(payload, "show-pointer"))
    )])

  elif action.hasKey("ScreenshotScreen"):
    let payload = action["ScreenshotScreen"]
    return (true, @[Msg(
      kind: CmdScreenshot,
      screenshotKind: ShotScreen,
      screenshotPath: stringFromField(payload, "path"),
      screenshotShowPointer: boolFromField(payload, "show_pointer", boolFromField(payload, "show-pointer"))
    )])

  elif action.hasKey("ScreenshotWindow"):
    let payload = action["ScreenshotWindow"]
    return (true, @[Msg(
      kind: CmdScreenshot,
      screenshotKind: ShotWindow,
      screenshotPath: stringFromField(payload, "path"),
      screenshotShowPointer: boolFromField(payload, "show_pointer", boolFromField(payload, "show-pointer"))
    )])

  elif action.hasKey("DoScreenTransition") or
      action.hasKey("PowerOffMonitors") or
      action.hasKey("PowerOnMonitors") or
      action.hasKey("Quit") or
      action.hasKey("MoveWorkspaceToIndex") or
      action.hasKey("MaximizeColumn") or
      action.hasKey("CenterColumn") or
      action.hasKey("CenterVisibleColumns") or
      action.hasKey("SwitchPresetColumnWidth") or
      action.hasKey("SwitchPresetWindowHeight") or
      action.hasKey("ToggleColumnTabbedDisplay") or
      action.hasKey("ToggleKeyboardShortcutsInhibit"):
    return (true, @[])

  (false, @[])

proc handleNiriRequest*(line: string; model: Model): NiriIpcResult =
  result.handled = false
  let stripped = line.strip()
  if stripped.len == 0 or (stripped[0] != '{' and stripped[0] != '"'):
    return

  var request: JsonNode
  try:
    request = parseJson(stripped)
  except CatchableError as e:
    result.handled = true
    result.reply = errReply("invalid JSON request: " & e.msg)
    return

  result.handled = true

  if request.kind == JString:
    case request.getStr()
    of "Outputs":
      result.reply = okReply(%*{"Outputs": niriOutputsJson(model)})
    of "Workspaces":
      result.reply = okReply(%*{"Workspaces": niriWorkspacesJson(model)})
    of "Windows":
      result.reply = okReply(%*{"Windows": niriWindowsJson(model)})
    of "FocusedWindow":
      let focused = model.focusedOnActiveTag()
      if focused != 0 and model.windows.hasKey(focused):
        result.reply = okReply(%*{"FocusedWindow": niriWindowJson(model, model.windows[focused])})
      else:
        result.reply = okReply(%*{"FocusedWindow": newJNull()})
    of "OverviewState":
      result.reply = okReply(%*{"OverviewState": niriOverviewJson(model)})
    of "KeyboardLayouts":
      result.reply = okReply(%*{"KeyboardLayouts": niriKeyboardLayoutsJson()})
    of "EventStream":
      result.subscribe = true
      result.reply = okReply(%*{"Handled": {}})
      result.initialEvents = initialNiriEvents(model)
    else:
      result.reply = errReply("unsupported niri request: " & request.getStr())
    return

  if request.kind == JObject and request.hasKey("Action"):
    let action = actionMessages(request["Action"], model)
    result.messages = action.messages
    if action.handled:
      result.reply = okReply(%*{"Handled": {}})
    else:
      result.reply = errReply("unsupported niri action")
    return

  result.reply = errReply("unsupported niri request")
