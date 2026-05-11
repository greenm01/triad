import std/[json, options]
import app_identity
import ../types/shell_snapshot

proc niriLayout*(win: ShellWindow; snapshot: ShellSnapshot): JsonNode =
  var tileW = 0.0
  var tileH = 0.0
  for output in snapshot.outputs:
    if output.name == win.outputName:
      tileW = float(output.w)
      tileH = float(output.h)
      break
  if tileW == 0.0 and snapshot.outputs.len > 0:
    tileW = float(snapshot.outputs[0].w)
    tileH = float(snapshot.outputs[0].h)
  let windowW =
    if win.actualW > 0:
      int(win.actualW)
    else:
      int(tileW)
  let windowH =
    if win.actualH > 0:
      int(win.actualH)
    else:
      int(tileH)
  let posX = float(win.colIdx)
  let posY = float(win.winIdx)

  %*{
    "pos_in_scrolling_layout": [int(posX), int(posY)],
    "tile_size": [tileW, tileH],
    "window_size": [windowW, windowH],
    "tile_pos_in_workspace_view": [posX, posY],
    "window_offset_in_tile": [0.0, 0.0]
  }

proc niriWindowJson*(snapshot: ShellSnapshot; win: ShellWindow): JsonNode =
  let compatId = compatAppId(win.appId)
  result = %*{
    "id": win.id,
    "title": if win.title == "": newJNull() else: %win.title,
    "app_id": if compatId == "": newJNull() else: %compatId,
    "pid": newJNull(),
    "workspace_id": if win.tagId.isSome: %win.tagId.get() else: newJNull(),
    "is_focused": win.isFocused,
    "is_floating": win.isFloating,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "is_fullscreen": win.isFullscreen,
    "is_urgent": false,
    "output": if win.outputName == "": newJNull() else: %win.outputName,
    "layout": niriLayout(win, snapshot),
    "focus_timestamp": newJNull()
  }
  if win.appId.len > 0 and compatId != win.appId:
    result["raw_app_id"] = %win.appId

proc niriWorkspacesJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for workspace in snapshot.workspaces:
    result.add(%*{
      "id": workspace.tagId,
      "idx": workspace.workspaceIdx,
      "name": if workspace.name == "": newJNull() else: %workspace.name,
      "output": workspace.outputName,
      "is_urgent": false,
      "is_active": workspace.isActive,
      "is_focused": workspace.isActive,
      "active_window_id": if workspace.focusedWindow !=
          0: %workspace.focusedWindow else: newJNull(),
      "occupied": workspace.occupied
    })

proc niriWindowsJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for win in snapshot.windows:
    result.add(niriWindowJson(snapshot, win))

proc niriOutputJson(output: ShellOutput): JsonNode =
  let w = max(0, int(output.w))
  let h = max(0, int(output.h))
  %*{
    "name": output.name,
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

proc niriOutputsJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJObject()
  for output in snapshot.outputs:
    result[output.name] = niriOutputJson(output)

proc niriKeyboardLayoutsJson*(): JsonNode =
  %*{"names": [], "current_idx": 0}

proc niriOverviewJson*(snapshot: ShellSnapshot): JsonNode =
  %*{"is_open": snapshot.overviewActive}

proc initialNiriEvents*(snapshot: ShellSnapshot): seq[string] =
  @[
    $(%*{"WorkspacesChanged": {"workspaces": niriWorkspacesJson(snapshot)}}),
    $(%*{"WindowsChanged": {"windows": niriWindowsJson(snapshot)}}),
    $(%*{"OutputsChanged": {"outputs": niriOutputsJson(snapshot)}}),
    $(%*{"OverviewOpenedOrClosed": {"is_open": snapshot.overviewActive}}),
    $(%*{"KeyboardLayoutsChanged": {"keyboard_layouts": niriKeyboardLayoutsJson()}}),
    $(%*{"ConfigLoaded": {"failed": false}})
  ]
