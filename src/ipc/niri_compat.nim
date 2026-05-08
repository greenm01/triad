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

proc niriOutputName(model: Model; outputId: uint32): string =
  if outputId != 0 and model.outputs.hasKey(outputId):
    let output = model.outputs[outputId]
    if output.name.len > 0:
      return output.name
  if outputId != 0:
    return "river-" & $outputId
  "triad-0"

proc niriWorkspaceOutputName(model: Model; tagId: uint32): string =
  var outputId = model.primaryOutput
  for candidateId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      outputId = candidateId
      break
  model.niriOutputName(outputId)

proc niriWindowJson*(model: Model; win: WindowData): JsonNode =
  let ws = model.windowWorkspaceId(win.id)
  let isFocused = ws.isSome and model.tags[ws.get()].focusedWindow == win.id
  let output =
    if ws.isSome and model.tags.hasKey(ws.get()):
      model.niriWorkspaceOutputName(ws.get())
    else:
      ""
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
    "output": if output == "": newJNull() else: %output,
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
    let outputName = model.niriWorkspaceOutputName(tagId)
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
      "connected": true,
      "make": "Triad",
      "model": "River",
      "serial": newJNull(),
      "physical_size": {"width": 0, "height": 0},
      "physical_width": 0,
      "physical_height": 0,
      "modes": [
        {"width": w, "height": h, "refresh_rate": 60000, "is_preferred": true}
      ],
      "current_mode": 0,
      "is_custom_mode": false,
      "vrr_supported": false,
      "vrr_enabled": false,
      "refresh_rate": 60000,
      "x": 0,
      "y": 0,
      "width": w,
      "height": h,
      "scale": 1.0,
      "transform": "Normal",
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
    let name = model.niriOutputName(id)
    let w = max(0, int(output.w))
    let h = max(0, int(output.h))
    result[name] = %*{
      "name": name,
      "connected": true,
      "make": "Triad",
      "model": "River",
      "serial": newJNull(),
      "physical_size": {"width": 0, "height": 0},
      "physical_width": 0,
      "physical_height": 0,
      "modes": [
        {"width": w, "height": h, "refresh_rate": 60000, "is_preferred": true}
      ],
      "current_mode": 0,
      "is_custom_mode": false,
      "vrr_supported": false,
      "vrr_enabled": false,
      "refresh_rate": 60000,
      "x": int(output.x),
      "y": int(output.y),
      "width": w,
      "height": h,
      "scale": 1.0,
      "transform": "Normal",
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
