import algorithm, json, options, tables
import app_identity
import model
import model_utils

proc niriLayout*(winId: WindowId; model: Model): JsonNode =
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

proc windowWorkspaceId*(model: Model; winId: WindowId): Option[uint32] =
  for tagId, tag in model.tags.pairs:
    if tag.containsWindow(winId):
      return some(tagId)
  none(uint32)

proc niriOutputName*(model: Model; outputId: uint32): string =
  if outputId != 0 and model.outputs.hasKey(outputId):
    let output = model.outputs[outputId]
    if output.name.len > 0:
      return output.name
  if outputId != 0:
    return "river-" & $outputId
  "triad-0"

proc niriWorkspaceOutputName*(model: Model; tagId: uint32): string =
  var outputId = model.primaryOutput
  for candidateId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      outputId = candidateId
      break
  model.niriOutputName(outputId)

proc niriWindowJson*(model: Model; win: WindowData): JsonNode =
  let ws = model.windowWorkspaceId(win.id)
  let isFocused = ws.isSome and model.tags[ws.get()].focusedWindow == win.id
  let compatId = compatAppId(win.appId)
  let output =
    if ws.isSome and model.tags.hasKey(ws.get()):
      model.niriWorkspaceOutputName(ws.get())
    else:
      ""
  result = %*{
    "id": win.id,
    "title": if win.title == "": newJNull() else: %win.title,
    "app_id": if compatId == "": newJNull() else: %compatId,
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
  if win.appId.len > 0 and compatId != win.appId:
    result["raw_app_id"] = %win.appId

proc niriWorkspacesJson*(model: Model): JsonNode =
  let ids = model.visibleWorkspaceIds()

  result = newJArray()
  for idx, tagId in ids:
    let tag = model.tags[tagId]
    let windows = tag.flattenWindows()
    let outputName = model.niriWorkspaceOutputName(tagId)
    result.add(%*{
      "id": tagId,
      "idx": idx + 1,
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
