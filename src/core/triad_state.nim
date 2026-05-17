import std/[json, options]
import layout_mode_codec
import layout_selection_codec
import ../types/shell_snapshot
from ../types/runtime_values import
  LayoutMode, LayoutSelectionKind, WindowRuleIdleInhibitMode

export shell_snapshot

proc nullableString(value: string): JsonNode =
  if value.len == 0:
    newJNull()
  else:
    %value

proc triadSupportedLayoutsJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for mode in LayoutMode:
    result.add(%*{"kind": "builtin", "id": layoutModeId(mode), "ordinal": ord(mode)})
  for layout in snapshot.customLayouts:
    result.add(
      %*{
        "kind": "custom",
        "id": layout.id.layoutIdString(),
        "fallback_layout": layoutModeId(layout.fallback),
      }
    )

proc triadLayoutCycleJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  if snapshot.layoutCycleSelections.len > 0:
    for selection in snapshot.layoutCycleSelections:
      result.add(%selection.selectionId())
  else:
    for mode in snapshot.layoutCycle:
      result.add(%layoutModeId(mode))

proc triadLayoutCycleEntriesJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for selection in snapshot.layoutCycleSelections:
    case selection.kind
    of LayoutSelectionKind.Builtin:
      result.add(%*{"kind": "builtin", "id": layoutModeId(selection.builtin)})
    of LayoutSelectionKind.Custom:
      result.add(
        %*{
          "kind": "custom",
          "id": selection.customId.layoutIdString(),
          "fallback_layout": layoutModeId(selection.builtin),
        }
      )

proc triadColumnJson(col: ShellColumn): JsonNode =
  let windows = newJArray()
  for winId in col.windows:
    windows.add(%winId)
  %*{
    "idx": col.idx,
    "width_proportion": col.widthProportion,
    "scroller_single_proportion": col.scrollerSingleProportion,
    "is_full_width": col.isFullWidth,
    "windows": windows,
  }

proc triadWorkspaceLayoutJson*(workspace: ShellWorkspace): JsonNode =
  let columns = newJArray()
  for col in workspace.columns:
    columns.add(triadColumnJson(col))

  %*{
    "tag_id": workspace.tagId,
    "workspace_idx": workspace.workspaceIdx,
    "name": nullableString(workspace.name),
    "layout": workspace.layoutId,
    "layout_kind": workspace.layoutKind,
    "fallback_layout": layoutModeId(workspace.fallbackLayout),
    "is_active": workspace.isActive,
    "focused_window_id":
      if workspace.focusedWindow == 0:
        newJNull()
      else:
        %workspace.focusedWindow,
    "columns": columns,
    "master_count": workspace.masterCount,
    "master_split_ratio": workspace.masterSplitRatio,
    "viewport": {
      "target_x": workspace.targetViewportXOffset,
      "current_x": workspace.currentViewportXOffset,
      "target_y": workspace.targetViewportYOffset,
      "current_y": workspace.currentViewportYOffset,
    },
  }

proc triadLayoutStateJson*(snapshot: ShellSnapshot): JsonNode =
  let workspaces = newJArray()
  for workspace in snapshot.workspaces:
    workspaces.add(triadWorkspaceLayoutJson(workspace))

  %*{
    "version": snapshot.version,
    "layouts": triadSupportedLayoutsJson(snapshot),
    "layout_cycle": triadLayoutCycleJson(snapshot),
    "layout_cycle_entries": triadLayoutCycleEntriesJson(snapshot),
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "workspaces": workspaces,
  }

proc triadOutputJson(output: ShellOutput): JsonNode =
  %*{
    "id": output.id,
    "name": output.name,
    "is_primary": output.isPrimary,
    "refresh_rate": output.refreshRate,
    "geometry": {"x": output.x, "y": output.y, "width": output.w, "height": output.h},
  }

proc idleInhibitModeId(mode: WindowRuleIdleInhibitMode): string =
  case mode
  of WindowRuleIdleInhibitMode.IdleInhibitNone: "none"
  of WindowRuleIdleInhibitMode.IdleInhibitFocused: "focused"
  of WindowRuleIdleInhibitMode.IdleInhibitVisible: "visible"

proc triadWindowJson(win: ShellWindow): JsonNode =
  %*{
    "id": win.id,
    "pid":
      if win.pid <= 0:
        newJNull()
      else:
        %win.pid,
    "parent_id":
      if win.parentId == 0:
        newJNull()
      else:
        %win.parentId,
    "title": nullableString(win.title),
    "app_id": nullableString(win.appId),
    "tag_id":
      if win.tagId.isSome:
        %win.tagId.get()
      else:
        newJNull(),
    "workspace_idx":
      if win.workspaceIdx == 0:
        newJNull()
      else:
        %win.workspaceIdx,
    "output": nullableString(win.outputName),
    "position": {
      "column_idx":
        if win.colIdx == 0:
          newJNull()
        else:
          %win.colIdx,
      "window_idx":
        if win.winIdx == 0:
          newJNull()
        else:
          %win.winIdx,
    },
    "is_focused": win.isFocused,
    "is_floating": win.isFloating,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "is_sticky": win.isSticky,
    "is_overlay": win.isOverlay,
    "is_unmanaged_global": win.isUnmanagedGlobal,
    "is_fullscreen": win.isFullscreen,
    "fullscreen_output":
      if win.fullscreenOutput == 0:
        newJNull()
      else:
        %win.fullscreenOutput,
    "width_proportion": win.widthProportion,
    "height_proportion": win.heightProportion,
    "actual_size": {"width": win.actualW, "height": win.actualH},
    "floating_geometry": {
      "x": win.floatingGeom.x,
      "y": win.floatingGeom.y,
      "width": win.floatingGeom.w,
      "height": win.floatingGeom.h,
    },
    "keyboard_shortcuts_inhibit": win.keyboardShortcutsInhibit,
    "idle_inhibit": idleInhibitModeId(win.idleInhibitMode),
    "is_terminal": win.isTerminal,
    "allow_swallow": win.allowSwallow,
    "swallowed_by":
      if win.swallowedBy == 0:
        newJNull()
      else:
        %win.swallowedBy,
    "swallowing":
      if win.swallowing == 0:
        newJNull()
      else:
        %win.swallowing,
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
      "selected_window_id":
        if snapshot.overviewSelectedWindow == 0:
          newJNull()
        else:
          %snapshot.overviewSelectedWindow,
    },
    "layout": triadLayoutStateJson(snapshot),
    "outputs": outputs,
    "windows": windows,
  }

proc triadLayoutStateChangedEvent*(snapshot: ShellSnapshot): string =
  $(
    %*{
      "triad": {
        "version": TriadIpcVersion,
        "event": "layout-state-changed",
        "state": triadLayoutStateJson(snapshot),
      }
    }
  )

proc triadStateChangedEvent*(snapshot: ShellSnapshot): string =
  $(
    %*{
      "triad": {
        "version": TriadIpcVersion,
        "event": "state-changed",
        "state": triadStateJson(snapshot),
      }
    }
  )
