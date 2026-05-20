import std/[json, options]
import layout_descriptor_codec
import layout_mode_codec
import layout_selection_codec
import native_layout_codec
import ../types/shell_snapshot
from ../types/runtime_values import
  Direction, FrameNodeKind, FrameSplitOrientation, LayoutMode, LayoutSelectionKind,
  LayoutSource, SplitTreeNodeMode, WindowRuleIdleInhibitMode

export shell_snapshot

proc nullableString(value: string): JsonNode =
  if value.len == 0:
    newJNull()
  else:
    %value

proc triadSupportedLayoutsJson*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for mode in LayoutMode:
    if mode.layoutSource() == LayoutSource.Core:
      result.add(
        %*{
          "kind": "builtin",
          "id": layoutModeId(mode),
          "ordinal": ord(mode),
          "runtime_kind": mode.layoutKind().layoutKindId(),
          "layout_source": mode.layoutSource().layoutSourceId(),
        }
      )
  for layout in snapshot.customLayouts:
    let id = layout.id.layoutIdString()
    result.add(
      %*{
        "kind": "custom",
        "id": id,
        "fallback_layout": layout.fallback.selectionFallbackId(),
        "runtime_kind": id.layoutKindForId().layoutKindId(),
        "layout_source": id.layoutSourceForId().layoutSourceId(),
      }
    )
  for layout in snapshot.nativeLayouts:
    let id = layout.id.nativeLayoutIdString()
    result.add(
      %*{
        "kind": "native",
        "id": id,
        "fallback_layout": layout.fallback.selectionFallbackId(),
        "runtime_kind": id.layoutKindForId().layoutKindId(),
        "layout_source": id.layoutSourceForId().layoutSourceId(),
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
          "fallback_layout": selection.selectionFallbackId(),
        }
      )
    of LayoutSelectionKind.Native:
      result.add(
        %*{
          "kind": "native",
          "id": selection.nativeId.nativeLayoutIdString(),
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

proc frameNodeKindId(kind: FrameNodeKind): string =
  case kind
  of FrameNodeKind.Leaf: "leaf"
  of FrameNodeKind.Split: "split"

proc frameSplitOrientationId(orientation: FrameSplitOrientation): string =
  case orientation
  of FrameSplitOrientation.Horizontal: "horizontal"
  of FrameSplitOrientation.Vertical: "vertical"

proc directionId(direction: Direction): string =
  case direction
  of Direction.DirLeft: "left"
  of Direction.DirRight: "right"
  of Direction.DirUp: "up"
  of Direction.DirDown: "down"

proc splitTreeNodeModeId(mode: SplitTreeNodeMode): string =
  case mode
  of SplitTreeNodeMode.SplitH: "split-h"
  of SplitTreeNodeMode.SplitV: "split-v"
  of SplitTreeNodeMode.Stacking: "stacking"
  of SplitTreeNodeMode.Tabbed: "tabbed"

proc triadFrameJson(frame: ShellFrame): JsonNode =
  let windows = newJArray()
  for winId in frame.windows:
    windows.add(%winId)
  %*{
    "id": frame.id,
    "kind": frame.kind.frameNodeKindId(),
    "parent":
      if frame.parent == 0:
        newJNull()
      else:
        %frame.parent,
    "first_child":
      if frame.firstChild == 0:
        newJNull()
      else:
        %frame.firstChild,
    "second_child":
      if frame.secondChild == 0:
        newJNull()
      else:
        %frame.secondChild,
    "orientation": frame.orientation.frameSplitOrientationId(),
    "ratio": frame.ratio,
    "windows": windows,
    "active_window_id":
      if frame.activeWindow == 0:
        newJNull()
      else:
        %frame.activeWindow,
    "focused": frame.focused,
  }

proc triadBspNodeJson(node: ShellBspNode): JsonNode =
  %*{
    "id": node.id,
    "kind": node.kind.frameNodeKindId(),
    "parent":
      if node.parent == 0:
        newJNull()
      else:
        %node.parent,
    "first_child":
      if node.firstChild == 0:
        newJNull()
      else:
        %node.firstChild,
    "second_child":
      if node.secondChild == 0:
        newJNull()
      else:
        %node.secondChild,
    "orientation": node.orientation.frameSplitOrientationId(),
    "ratio": node.ratio,
    "window_id":
      if node.window == 0:
        newJNull()
      else:
        %node.window,
    "focused": node.focused,
    "preselect_direction":
      if node.hasPreselection:
        %node.preselectDirection.directionId()
      else:
        newJNull(),
    "preselect_ratio":
      if node.hasPreselection:
        %node.preselectRatio
      else:
        newJNull(),
  }

proc triadSplitNodeJson(node: ShellSplitNode): JsonNode =
  let children = newJArray()
  for child in node.children:
    children.add(%child)
  %*{
    "id": node.id,
    "kind": node.kind.frameNodeKindId(),
    "parent":
      if node.parent == 0:
        newJNull()
      else:
        %node.parent,
    "children": children,
    "mode": node.mode.splitTreeNodeModeId(),
    "last_split_mode": node.lastSplitMode.splitTreeNodeModeId(),
    "weight": node.weight,
    "window_id":
      if node.window == 0:
        newJNull()
      else:
        %node.window,
    "focused": node.focused,
  }

proc triadWorkspaceLayoutJson*(workspace: ShellWorkspace): JsonNode =
  let columns = newJArray()
  for col in workspace.columns:
    columns.add(triadColumnJson(col))
  let frames = newJArray()
  for frame in workspace.frames:
    frames.add(triadFrameJson(frame))
  let bspNodes = newJArray()
  for node in workspace.bspNodes:
    bspNodes.add(triadBspNodeJson(node))
  let splitNodes = newJArray()
  for node in workspace.splitNodes:
    splitNodes.add(triadSplitNodeJson(node))

  %*{
    "tag_id": workspace.tagId,
    "workspace_idx": workspace.workspaceIdx,
    "name": nullableString(workspace.name),
    "output": nullableString(workspace.outputName),
    "layout": workspace.layoutId,
    "layout_kind": workspace.layoutKind,
    "runtime_kind": workspace.runtimeLayoutKind,
    "layout_source": workspace.layoutSource,
    "fallback_layout": workspace.fallbackLayout,
    "is_active": workspace.isActive,
    "is_output_visible": workspace.isOutputVisible,
    "occupied": workspace.occupied,
    "focused_window_id":
      if workspace.focusedWindow == 0:
        newJNull()
      else:
        %workspace.focusedWindow,
    "columns": columns,
    "frames": frames,
    "bsp_nodes": bspNodes,
    "split_nodes": splitNodes,
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
    "keyboard_layouts": snapshot.keyboardLayoutNames,
    "current_keyboard_layout_idx": snapshot.keyboardLayoutIndex,
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
