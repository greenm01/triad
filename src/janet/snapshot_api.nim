import std/[options, strutils]
from ../types/core import Rect
import ../types/shell_snapshot
import ../types/runtime_values

proc escaped(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '\\':
      result.add("\\\\")
    of '"':
      result.add("\\\"")
    of '\n':
      result.add("\\n")
    of '\r':
      result.add("\\r")
    of '\t':
      result.add("\\t")
    else:
      result.add(ch)
  result.add("\"")

proc boolValue(value: bool): string =
  if value: "true" else: "false"

proc layoutName(mode: LayoutMode): string =
  case mode
  of LayoutMode.Scroller: "scroller"
  of LayoutMode.VerticalScroller: "vertical-scroller"
  of LayoutMode.MasterStack: "tile"
  of LayoutMode.Grid: "grid"
  of LayoutMode.Monocle: "monocle"
  of LayoutMode.Deck: "deck"
  of LayoutMode.CenterTile: "center-tile"
  of LayoutMode.RightTile: "right-tile"
  of LayoutMode.VerticalTile: "vertical-tile"
  of LayoutMode.VerticalGrid: "vertical-grid"
  of LayoutMode.VerticalDeck: "vertical-deck"
  of LayoutMode.TGMix: "tgmix"

proc rectExpr(rect: Rect): string =
  "{:x " & $rect.x & " :y " & $rect.y & " :w " & $rect.w & " :h " & $rect.h & "}"

proc columnExpr(column: ShellColumn): string =
  var windows: seq[string] = @[]
  for winId in column.windows:
    windows.add($winId)
  "{:idx " & $column.idx & " :width-proportion " & $column.widthProportion &
    " :scroller-single-proportion " & $column.scrollerSingleProportion & " :full-width " &
    column.isFullWidth.boolValue() & " :windows [" & windows.join(" ") & "]}"

proc workspaceExpr(workspace: ShellWorkspace): string =
  var columns: seq[string] = @[]
  for column in workspace.columns:
    columns.add(column.columnExpr())
  "{:tag-id " & $workspace.tagId & " :workspace-idx " & $workspace.workspaceIdx &
    " :name " & workspace.name.escaped() & " :layout-mode " &
    workspace.layoutMode.layoutName().escaped() & " :layout-id " &
    workspace.layoutId.escaped() & " :layout-kind " & workspace.layoutKind.escaped() &
    " :fallback-layout " & workspace.fallbackLayout.layoutName().escaped() & " :active " &
    workspace.isActive.boolValue() & " :output-visible " &
    workspace.isOutputVisible.boolValue() & " :focused-window " &
    $workspace.focusedWindow & " :occupied " & workspace.occupied.boolValue() &
    " :output-name " & workspace.outputName.escaped() & " :master-count " &
    $workspace.masterCount & " :master-split-ratio " & $workspace.masterSplitRatio &
    " :target-viewport-x-offset " & $workspace.targetViewportXOffset &
    " :current-viewport-x-offset " & $workspace.currentViewportXOffset &
    " :target-viewport-y-offset " & $workspace.targetViewportYOffset &
    " :current-viewport-y-offset " & $workspace.currentViewportYOffset & " :columns [" &
    columns.join(" ") & "]}"

proc janetWindowExpr*(window: ShellWindow): string =
  let tagId =
    if window.tagId.isSome:
      $window.tagId.get()
    else:
      "nil"
  "{:id " & $window.id & " :pid " & $window.pid & " :parent-id " & $window.parentId &
    " :title " & window.title.escaped() & " :app-id " & window.appId.escaped() &
    " :identifier " & window.identifier.escaped() & " :tag-id " & tagId &
    " :workspace-idx " & $window.workspaceIdx & " :output-name " &
    window.outputName.escaped() & " :col-idx " & $window.colIdx & " :win-idx " &
    $window.winIdx & " :focused " & window.isFocused.boolValue() & " :floating " &
    window.isFloating.boolValue() & " :fullscreen " & window.isFullscreen.boolValue() &
    " :maximized " & window.isMaximized.boolValue() & " :minimized " &
    window.isMinimized.boolValue() & " :sticky " & window.isSticky.boolValue() &
    " :overlay " & window.isOverlay.boolValue() & " :unmanaged-global " &
    window.isUnmanagedGlobal.boolValue() & " :fullscreen-output " &
    $window.fullscreenOutput & " :width-proportion " & $window.widthProportion &
    " :height-proportion " & $window.heightProportion & " :actual-w " & $window.actualW &
    " :actual-h " & $window.actualH & " :floating-geom " & window.floatingGeom.rectExpr() &
    " :keyboard-shortcuts-inhibit " & window.keyboardShortcutsInhibit.boolValue() &
    " :terminal " & window.isTerminal.boolValue() & " :allow-swallow " &
    window.allowSwallow.boolValue() & " :swallowed-by " & $window.swallowedBy &
    " :swallowing " & $window.swallowing & "}"

proc janetOutputExpr*(output: ShellOutput): string =
  "{:id " & $output.id & " :name " & output.name.escaped() & " :x " & $output.x & " :y " &
    $output.y & " :w " & $output.w & " :h " & $output.h & " :primary " &
    output.isPrimary.boolValue() & " :refresh-rate " & $output.refreshRate & "}"

proc janetSnapshotSource*(
    snapshot: ShellSnapshot, currentWindow = none(ShellWindow), currentEvent = "nil"
): string =
  var workspaces: seq[string] = @[]
  var windows: seq[string] = @[]
  var outputs: seq[string] = @[]
  var layoutCycle: seq[string] = @[]

  for workspace in snapshot.workspaces:
    workspaces.add(workspace.workspaceExpr())
  for window in snapshot.windows:
    windows.add(window.janetWindowExpr())
  for output in snapshot.outputs:
    outputs.add(output.janetOutputExpr())
  for mode in snapshot.layoutCycle:
    layoutCycle.add(mode.layoutName().escaped())
  let currentWindowExpr =
    if currentWindow.isSome:
      currentWindow.get().janetWindowExpr()
    else:
      "nil"

  result =
    """
(def triad/current-window $13)
(def triad/current-event $14)

(def triad/snapshot
  {:version $1
   :active-tag $2
   :active-workspace-idx $3
   :overview-active $4
   :overview-selected-window $5
   :active-scratchpad-window $6
   :session-locked $7
   :layer-focus-exclusive $8
   :layout-cycle [$9]
   :workspaces [$10]
   :windows [$11]
   :outputs [$12]})

(defn triad/active-tag-id [] (triad/snapshot :active-tag))

(defn triad/find-tag-by-name [name]
  (var found nil)
  (each workspace (triad/snapshot :workspaces)
    (when (= name (workspace :name))
      (set found workspace)))
  found)

(defn triad/workspace-by-tag [tag-id]
  (var found nil)
  (each workspace (triad/snapshot :workspaces)
    (when (= tag-id (workspace :tag-id))
      (set found workspace)))
  found)

(defn triad/workspace-by-index [workspace-idx]
  (var found nil)
  (each workspace (triad/snapshot :workspaces)
    (when (= workspace-idx (workspace :workspace-idx))
      (set found workspace)))
  found)

(defn triad/current-workspace []
  (triad/workspace-by-tag (triad/active-tag-id)))

(defn triad/output-by-name [name]
  (var found nil)
  (each output (triad/snapshot :outputs)
    (when (= name (output :name))
      (set found output)))
  found)

(defn triad/windows-on-tag [tag-id]
  (var found @[])
  (each window (triad/snapshot :windows)
    (when (= tag-id (window :tag-id))
      (array/push found window)))
  (tuple ;found))

(defn triad/windows-by-app-id [app-id]
  (var found @[])
  (each window (triad/snapshot :windows)
    (when (= app-id (window :app-id))
      (array/push found window)))
  (tuple ;found))

(defn triad/window-by-id [window-id]
  (var found nil)
  (each window (triad/snapshot :windows)
    (when (= window-id (window :id))
      (set found window)))
  found)

(defn triad/window-on-workspace? [window workspace]
  (or (= (window :workspace-idx) (workspace :workspace-idx))
      (= (window :tag-id) (workspace :tag-id))))

(defn triad/workspace-empty? [workspace ignored-window-id]
  (var occupied false)
  (each window (triad/snapshot :windows)
    (when (and (not= (window :id) ignored-window-id)
               (triad/window-on-workspace? window workspace))
      (set occupied true)))
  (not occupied))

(defn triad/first-empty-workspace [ignored-window-id]
  (var found nil)
  (each workspace (triad/snapshot :workspaces)
    (when (and (triad/workspace-empty? workspace ignored-window-id)
               (or (not found)
                   (< (workspace :workspace-idx) (found :workspace-idx))))
      (set found workspace)))
  found)
""" %
    [
      $snapshot.version,
      $snapshot.activeTag,
      $snapshot.activeWorkspaceIdx,
      snapshot.overviewActive.boolValue(),
      $snapshot.overviewSelectedWindow,
      $snapshot.activeScratchpadWindow,
      snapshot.sessionLocked.boolValue(),
      snapshot.layerFocusExclusive.boolValue(),
      layoutCycle.join(" "),
      workspaces.join(" "),
      windows.join(" "),
      outputs.join(" "),
      currentWindowExpr,
      currentEvent,
    ]
