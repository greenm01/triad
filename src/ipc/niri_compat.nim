import algorithm, json, options, strutils, tables
import ../core/model
import ../core/model_utils
import ../core/msg

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

proc niriLayout(winId: WindowId; model: Model): JsonNode =
  var posX = 0.0
  var posY = 0.0
  var tileW = float(model.screenWidth)
  var tileH = float(model.screenHeight)
  var windowW = max(0, int(model.screenWidth))
  var windowH = max(0, int(model.screenHeight))

  for tag in model.tags.values:
    for colIdx, col in tag.columns:
      let winIdx = col.windows.find(winId)
      if winIdx != -1:
        posX = float(colIdx + 1)
        posY = float(winIdx + 1)

  if model.windows.hasKey(winId):
    let win = model.windows[winId]
    if win.actualW > 0:
      windowW = int(win.actualW)
    if win.actualH > 0:
      windowH = int(win.actualH)

  %*{
    "pos_in_scrolling_layout": [int(posX), int(posY)],
    "tile_size": [tileW, tileH],
    "window_size": [windowW, windowH],
    "tile_pos_in_workspace_view": [posX, posY],
    "window_offset_in_tile": [0.0, 0.0]
  }

proc windowWorkspaceId(model: Model; winId: WindowId): Option[uint32] =
  for tagId, tag in model.tags.pairs:
    if tag.containsWindow(winId):
      return some(tagId)
  none(uint32)

proc niriWindowJson*(model: Model; win: WindowData): JsonNode =
  let ws = model.windowWorkspaceId(win.id)
  let isFocused = ws.isSome and model.tags[ws.get()].focusedWindow == win.id
  result = %*{
    "id": win.id,
    "title": if win.title == "": newJNull() else: %win.title,
    "app_id": if win.appId == "": newJNull() else: %win.appId,
    "pid": newJNull(),
    "workspace_id": if ws.isSome: %ws.get() else: newJNull(),
    "is_focused": isFocused,
    "is_floating": win.isFloating,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "is_fullscreen": win.isFullscreen,
    "is_urgent": false,
    "layout": niriLayout(win.id, model),
    "focus_timestamp": newJNull()
  }

proc niriWorkspacesJson*(model: Model): JsonNode =
  var ids: seq[uint32] = @[]
  for tagId in model.tags.keys:
    ids.add(tagId)
  ids.sort()

  result = newJArray()
  for tagId in ids:
    let tag = model.tags[tagId]
    let windows = tag.flattenWindows()
    var outputName = if model.primaryOutput != 0: "river-" & $model.primaryOutput else: "triad-0"
    for outputId, outputTag in model.outputTags.pairs:
      if outputTag == tagId:
        outputName = "river-" & $outputId
        break
    result.add(%*{
      "id": tagId,
      "idx": tagId,
      "name": if tag.name == "": newJNull() else: %tag.name,
      "output": outputName,
      "is_urgent": false,
      "is_active": tagId == model.activeTag,
      "is_focused": tagId == model.activeTag,
      "active_window_id": if tag.focusedWindow != 0: %tag.focusedWindow else: newJNull(),
      "occupied": windows.len > 0
    })

proc niriWindowsJson*(model: Model): JsonNode =
  var ids: seq[WindowId] = @[]
  for winId in model.windows.keys:
    ids.add(winId)
  ids.sort()

  result = newJArray()
  for winId in ids:
    result.add(niriWindowJson(model, model.windows[winId]))

proc niriOutputsJson*(model: Model): JsonNode =
  result = newJObject()

  if model.outputs.len == 0:
    let w = max(0, int(model.screenWidth))
    let h = max(0, int(model.screenHeight))
    result["triad-0"] = %*{
      "name": "triad-0",
      "make": "Triad",
      "model": "River",
      "serial": newJNull(),
      "physical_size": newJNull(),
      "modes": [
        {"width": w, "height": h, "refresh_rate": 60000, "is_preferred": true}
      ],
      "current_mode": 0,
      "is_custom_mode": false,
      "vrr_supported": false,
      "vrr_enabled": false,
      "logical": {
        "x": 0,
        "y": 0,
        "width": w,
        "height": h,
        "scale": 1.0,
        "transform": "Normal"
      }
    }
    return

  var ids: seq[uint32] = @[]
  for id in model.outputs.keys:
    ids.add(id)
  ids.sort()

  for id in ids:
    let output = model.outputs[id]
    let name = "river-" & $id
    let w = max(0, int(output.w))
    let h = max(0, int(output.h))
    result[name] = %*{
      "name": name,
      "make": "Triad",
      "model": "River",
      "serial": newJNull(),
      "physical_size": newJNull(),
      "modes": [
        {"width": w, "height": h, "refresh_rate": 60000, "is_preferred": true}
      ],
      "current_mode": 0,
      "is_custom_mode": false,
      "vrr_supported": false,
      "vrr_enabled": false,
      "logical": {
        "x": int(output.x),
        "y": int(output.y),
        "width": w,
        "height": h,
        "scale": 1.0,
        "transform": "Normal"
      }
    }

proc niriKeyboardLayoutsJson*(): JsonNode =
  %*{"names": [], "current_idx": 0}

proc niriOverviewJson*(model: Model): JsonNode =
  %*{"is_open": model.overviewActive}

proc initialNiriEvents*(model: Model): seq[string] =
  @[
    $(%*{"WorkspacesChanged": {"workspaces": niriWorkspacesJson(model)}}),
    $(%*{"WindowsChanged": {"windows": niriWindowsJson(model)}}),
    $(%*{"OutputsChanged": {"outputs": niriOutputsJson(model)}}),
    $(%*{"OverviewOpenedOrClosed": {"is_open": model.overviewActive}}),
    $(%*{"KeyboardLayoutsChanged": {"keyboard_layouts": niriKeyboardLayoutsJson()}}),
    $(%*{"ConfigLoaded": {"failed": false}})
  ]

proc uintFromNode(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() > 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc nextTag(model: Model; direction: int): Option[uint32] =
  var ids: seq[uint32] = @[]
  for tagId in model.tags.keys:
    ids.add(tagId)
  ids.sort()
  if ids.len == 0:
    return none(uint32)

  let active = model.activeTagOrFallback()
  var idx = ids.find(active)
  if idx == -1:
    idx = 0
  let nextIdx = (idx + direction + ids.len) mod ids.len
  some(ids[nextIdx])

proc actionMessages(action: JsonNode; model: Model): tuple[handled: bool, messages: seq[Msg]] =
  if action.kind != JObject:
    return (false, @[])

  if action.hasKey("FocusWorkspace"):
    let payload = action["FocusWorkspace"]
    if payload.kind == JObject and payload.hasKey("reference"):
      let refNode = payload["reference"]
      if refNode.kind == JObject:
        if refNode.hasKey("Index"):
          let tag = uintFromNode(refNode["Index"])
          if tag.isSome: return (true, @[Msg(kind: CmdFocusTag, focusTag: tag.get())])
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

  elif action.hasKey("FocusColumnLeft"):
    return (true, @[Msg(kind: CmdFocusPrev)])

  elif action.hasKey("FocusColumnRight"):
    return (true, @[Msg(kind: CmdFocusNext)])

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

  elif action.hasKey("DoScreenTransition") or
      action.hasKey("PowerOffMonitors") or
      action.hasKey("PowerOnMonitors") or
      action.hasKey("SwitchLayout") or
      action.hasKey("Quit") or
      action.hasKey("Screenshot") or
      action.hasKey("ScreenshotScreen") or
      action.hasKey("ScreenshotWindow"):
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
