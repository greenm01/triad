import std/[json, options]
import layout_mode_codec
import ../types/shell_snapshot
from ../types/runtime_values import LayoutMode

export shell_snapshot

proc nullableString(value: string): JsonNode =
  if value.len == 0: newJNull() else: %value

proc triadSupportedLayoutsJson*(): JsonNode =
  result = newJArray()
  for mode in LayoutMode:
    result.add(%*{"id": layoutModeId(mode), "ordinal": ord(mode)})

proc triadLayoutCycleJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for mode in snapshot.layoutCycle:
    result.add(%layoutModeId(mode))

proc triadColumnJson(col: ShellColumn): JsonNode =
  let windows = newJArray()
  for winId in col.windows:
    windows.add(%winId)
  %*{
    "idx": col.idx,
    "width_proportion": col.widthProportion,
    "is_full_width": col.isFullWidth,
    "windows": windows
  }

proc triadWorkspaceLayoutJson*(workspace: ShellWorkspace): JsonNode =
  let columns = newJArray()
  for col in workspace.columns:
    columns.add(triadColumnJson(col))

  %*{
    "tag_id": workspace.tagId,
    "workspace_idx": workspace.workspaceIdx,
    "name": nullableString(workspace.name),
    "layout": layoutModeId(workspace.layoutMode),
    "is_active": workspace.isActive,
    "focused_window_id": if workspace.focusedWindow == 0: newJNull(
        ) else: %workspace.focusedWindow,
    "columns": columns,
    "master_count": workspace.masterCount,
    "master_split_ratio": workspace.masterSplitRatio,
    "viewport": {
      "target_x": workspace.targetViewportXOffset,
      "current_x": workspace.currentViewportXOffset,
      "target_y": workspace.targetViewportYOffset,
      "current_y": workspace.currentViewportYOffset
    }
  }

proc triadLayoutStateJson*(snapshot: ShellSnapshot): JsonNode =
  let workspaces = newJArray()
  for workspace in snapshot.workspaces:
    workspaces.add(triadWorkspaceLayoutJson(workspace))

  %*{
    "version": snapshot.version,
    "layouts": triadSupportedLayoutsJson(),
    "layout_cycle": triadLayoutCycleJson(snapshot),
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "workspaces": workspaces
  }

proc triadOutputJson(output: ShellOutput): JsonNode =
  %*{
    "id": output.id,
    "name": output.name,
    "is_primary": output.isPrimary,
    "geometry": {
      "x": output.x,
      "y": output.y,
      "width": output.w,
      "height": output.h
    }
  }

proc triadWindowJson(win: ShellWindow): JsonNode =
  %*{
    "id": win.id,
    "parent_id": if win.parentId == 0: newJNull() else: %win.parentId,
    "title": nullableString(win.title),
    "app_id": nullableString(win.appId),
    "tag_id": if win.tagId.isSome: %win.tagId.get() else: newJNull(),
    "workspace_idx": if win.workspaceIdx == 0: newJNull(
        ) else: %win.workspaceIdx,
    "output": nullableString(win.outputName),
    "position": {
      "column_idx": if win.colIdx == 0: newJNull() else: %win.colIdx,
      "window_idx": if win.winIdx == 0: newJNull() else: %win.winIdx
    },
    "is_focused": win.isFocused,
    "is_floating": win.isFloating,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "is_fullscreen": win.isFullscreen,
    "fullscreen_output": if win.fullscreenOutput == 0: newJNull(
        ) else: %win.fullscreenOutput,
    "width_proportion": win.widthProportion,
    "height_proportion": win.heightProportion,
    "actual_size": {
      "width": win.actualW,
      "height": win.actualH
    },
    "floating_geometry": {
      "x": win.floatingGeom.x,
      "y": win.floatingGeom.y,
      "width": win.floatingGeom.w,
      "height": win.floatingGeom.h
    },
    "keyboard_shortcuts_inhibit": win.keyboardShortcutsInhibit
  }

proc triadStateJson*(snapshot: ShellSnapshot): JsonNode =
  let outputs = newJArray()
  for output in snapshot.outputs:
    outputs.add(triadOutputJson(output))

  let windows = newJArray()
  for win in snapshot.windows:
    windows.add(triadWindowJson(win))

  %*{
    "version": snapshot.version,
    "overview": {
      "is_open": snapshot.overviewActive,
      "selected_window_id": if snapshot.overviewSelectedWindow == 0:
        newJNull() else: %snapshot.overviewSelectedWindow
    },
    "layout": triadLayoutStateJson(snapshot),
    "outputs": outputs,
    "windows": windows
  }

proc triadLayoutStateChangedEvent*(snapshot: ShellSnapshot): string =
  $(%*{
    "triad": {
      "version": TriadIpcVersion,
      "event": "layout-state-changed",
      "state": triadLayoutStateJson(snapshot)
    }
  })

proc triadStateChangedEvent*(snapshot: ShellSnapshot): string =
  $(%*{
    "triad": {
      "version": TriadIpcVersion,
      "event": "state-changed",
      "state": triadStateJson(snapshot)
    }
  })
