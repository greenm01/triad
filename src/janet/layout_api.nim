import std/[algorithm, json, sets, strutils, tables]
import ../core/defaults
import ../core/layout_selection_codec
import ../types/janet_layouts
import ../types/projection_values as rv
from ../types/runtime_values import
  Direction, FrameNodeKind, FrameSplitOrientation, SpiralLayoutConfig
import ../utils/behavior_log
import binding

export janetLayoutId, layoutIdString

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

proc spiralConfigExpr(value: SpiralLayoutConfig): string =
  let
    ratio = if value.ratio > 0.0'f32: value.ratio else: DefaultSpiralRatio
    mainPaneRatio =
      if value.mainPaneRatio > 0.0'f32:
        value.mainPaneRatio
      else:
        DefaultSpiralMainPaneRatio
    mainPane =
      if value.mainPane in ["left", "top", "right", "bottom"]:
        value.mainPane
      else:
        DefaultSpiralMainPane
    clockwise = if value.clockwiseSet: value.clockwise else: DefaultSpiralClockwise
  "{:ratio " & $ratio & " :main-pane-ratio-set " & value.mainPaneRatioSet.boolValue() &
    " :main-pane-ratio " & $mainPaneRatio & " :main-pane " & mainPane.escaped() &
    " :clockwise " & clockwise.boolValue() & "}"

proc rectExpr(rect: rv.Rect): string =
  "{:x " & $rect.x & " :y " & $rect.y & " :w " & $rect.w & " :h " & $rect.h & "}"

proc columnExpr(column: rv.ProjectedColumn): string =
  var windows: seq[string] = @[]
  for winId in column.windows:
    windows.add($winId)
  "{:windows [" & windows.join(" ") & "] :width-proportion " & $column.widthProportion &
    " :scroller-single-proportion " & $column.scrollerSingleProportion & " :full-width " &
    column.isFullWidth.boolValue() & "}"

proc frameKindExpr(kind: FrameNodeKind): string =
  case kind
  of FrameNodeKind.Leaf: ":leaf"
  of FrameNodeKind.Split: ":split"

proc frameOrientationExpr(orientation: FrameSplitOrientation): string =
  case orientation
  of FrameSplitOrientation.Horizontal: ":horizontal"
  of FrameSplitOrientation.Vertical: ":vertical"

proc directionExpr(direction: Direction): string =
  case direction
  of Direction.DirLeft: ":left"
  of Direction.DirRight: ":right"
  of Direction.DirUp: ":up"
  of Direction.DirDown: ":down"

proc frameExpr(frame: rv.ProjectedFrame): string =
  var windows: seq[string] = @[]
  for winId in frame.windows:
    windows.add($winId)
  "{:id " & $frame.id & " :kind " & frame.kind.frameKindExpr() & " :parent " &
    $frame.parent & " :first-child " & $frame.firstChild & " :second-child " &
    $frame.secondChild & " :orientation " & frame.orientation.frameOrientationExpr() &
    " :ratio " & $frame.ratio & " :windows [" & windows.join(" ") & "] :active-window " &
    $frame.activeWindow & " :focused " & frame.focused.boolValue() & " :rect-set " &
    frame.rectSet.boolValue() & " :rect " & frame.rect.rectExpr() & "}"

proc bspNodeExpr(node: rv.ProjectedBspNode): string =
  "{:id " & $node.id & " :kind " & node.kind.frameKindExpr() & " :parent " & $node.parent &
    " :first-child " & $node.firstChild & " :second-child " & $node.secondChild &
    " :orientation " & node.orientation.frameOrientationExpr() & " :ratio " & $node.ratio &
    " :window " & $node.window & " :focused " & node.focused.boolValue() &
    " :preselect-direction " &
    (if node.hasPreselection: node.preselectDirection.directionExpr()
    else: "nil") & " :preselect-ratio " &
    (if node.hasPreselection: $node.preselectRatio else: "nil") & " :rect-set " &
    node.rectSet.boolValue() & " :rect " & node.rect.rectExpr() & "}"

proc windowExpr(window: rv.ProjectedWindow): string =
  "{:id " & $window.id & " :pid " & $window.pid & " :title " & window.title.escaped() &
    " :app-id " & window.appId.escaped() & " :width-proportion " &
    $window.widthProportion & " :height-proportion " & $window.heightProportion &
    " :floating " & window.isFloating.boolValue() & " :fullscreen " &
    window.isFullscreen.boolValue() & " :maximized " & window.isMaximized.boolValue() &
    " :minimized " & window.isMinimized.boolValue() & " :sticky " &
    window.isSticky.boolValue() & " :overlay " & window.isOverlay.boolValue() &
    " :unmanaged-global " & window.isUnmanagedGlobal.boolValue() & " :fullscreen-output " &
    $window.fullscreenOutput & " :parent-id " & $window.parentId & " :identifier " &
    window.identifier.escaped() & " :actual-w " & $window.actualW & " :actual-h " &
    $window.actualH & " :min-width " & $window.minWidth & " :min-height " &
    $window.minHeight & " :max-width " & $window.maxWidth & " :max-height " &
    $window.maxHeight & " :floating-geom " & window.floatingGeom.rectExpr() &
    " :keyboard-shortcuts-inhibit " & window.keyboardShortcutsInhibit.boolValue() &
    " :keyboard-shortcuts-inhibit-bypass " &
    window.keyboardShortcutsInhibitBypass.boolValue() & " :terminal " &
    window.isTerminal.boolValue() & " :allow-swallow " & window.allowSwallow.boolValue() &
    "}"

proc layoutContextSource*(context: JanetLayoutContext): string =
  var columns: seq[string] = @[]
  var frames: seq[string] = @[]
  var bspNodes: seq[string] = @[]
  var windows: seq[string] = @[]
  var windowIds: seq[rv.ProjectionWindowId] = @[]
  for id in context.windows.keys:
    windowIds.add(id)
  windowIds.sort()
  for column in context.tag.columns:
    columns.add(column.columnExpr())
  for frame in context.tag.frames:
    frames.add(frame.frameExpr())
  for node in context.tag.bspNodes:
    bspNodes.add(node.bspNodeExpr())
  for id in windowIds:
    windows.add(context.windows[id].windowExpr())

  """
(def triad/current-layout-context
  {:layout-id $1
   :screen $2
   :outer-gap $3
   :inner-gap $4
   :tag {:id $5
         :name $6
         :focused-window $7
         :target-viewport-x-offset $8
         :current-viewport-x-offset $9
         :target-viewport-y-offset $10
         :current-viewport-y-offset $11
         :master-count $12
         :master-split-ratio $13
         :columns [$14]
         :frames [$15]
         :bsp-nodes [$16]}
   :substrate $17
   :frames [$15]
   :bsp-nodes [$16]
   :windows [$18]
   :layout-options {:spiral $19}})
""" %
  [
    context.layoutId.layoutIdString().escaped(),
    context.screen.rectExpr(),
    $context.outerGap,
    $context.innerGap,
    $context.tag.tagId,
    context.tag.name.escaped(),
    $context.tag.focusedWindow,
    $context.tag.targetViewportXOffset,
    $context.tag.currentViewportXOffset,
    $context.tag.targetViewportYOffset,
    $context.tag.currentViewportYOffset,
    $context.tag.masterCount,
    $context.tag.masterSplitRatio,
    columns.join(" "),
    frames.join(" "),
    bspNodes.join(" "),
    if context.tag.bspNodes.len > 0:
      ":bsp"
    elif context.tag.frames.len > 0:
      ":frames"
    else:
      ":columns",
    windows.join(" "),
    context.spiral.spiralConfigExpr(),
  ]

proc extractedLayoutInstructions*(handle: JanetHandle): seq[JanetLayoutInstruction] =
  for idx in 0 ..< int(triadJanetLayoutInstructionCount(handle)):
    let targetKind =
      case int(triadJanetLayoutTargetKind(handle, cint(idx)))
      of 1: JanetLayoutTargetKind.Window
      of 2: JanetLayoutTargetKind.Frame
      of 3: JanetLayoutTargetKind.BspNode
      else: JanetLayoutTargetKind.None
    result.add(
      JanetLayoutInstruction(
        targetKind: targetKind,
        targetId: triadJanetLayoutTargetId(handle, cint(idx)),
        geom: rv.Rect(
          x: triadJanetLayoutX(handle, cint(idx)),
          y: triadJanetLayoutY(handle, cint(idx)),
          w: triadJanetLayoutW(handle, cint(idx)),
          h: triadJanetLayoutH(handle, cint(idx)),
        ),
      )
    )

proc tiledWindowIds(context: JanetLayoutContext): HashSet[rv.ProjectionWindowId] =
  for column in context.tag.columns:
    for winId in column.windows:
      result.incl(winId)

proc frameSubstrateActive(context: JanetLayoutContext): bool =
  context.tag.frames.len > 0

proc bspSubstrateActive(context: JanetLayoutContext): bool =
  context.tag.bspNodes.len > 0

proc leafFrameIds(context: JanetLayoutContext): HashSet[uint32] =
  for frame in context.tag.frames:
    if frame.kind == FrameNodeKind.Leaf:
      result.incl(frame.id)

proc activeFrameWindowIds(context: JanetLayoutContext): HashSet[rv.ProjectionWindowId] =
  for frame in context.tag.frames:
    if frame.kind == FrameNodeKind.Leaf and frame.activeWindow != 0 and
        frame.windows.find(frame.activeWindow) != -1 and
        context.windows.hasKey(frame.activeWindow):
      result.incl(frame.activeWindow)

proc leafBspNodeIds(context: JanetLayoutContext): HashSet[uint32] =
  for node in context.tag.bspNodes:
    if node.kind == FrameNodeKind.Leaf:
      result.incl(node.id)

proc activeBspWindowIds(context: JanetLayoutContext): HashSet[rv.ProjectionWindowId] =
  for node in context.tag.bspNodes:
    if node.kind == FrameNodeKind.Leaf and node.window != 0 and
        context.windows.hasKey(node.window):
      let win = context.windows[node.window]
      if not win.isFloating and not win.isMinimized and not win.isUnmanagedGlobal:
        result.incl(node.window)

proc activeWindowForFrame(
    context: JanetLayoutContext, frameId: uint32
): rv.ProjectionWindowId =
  for frame in context.tag.frames:
    if frame.id == frameId and frame.kind == FrameNodeKind.Leaf and
        frame.activeWindow != 0 and frame.windows.find(frame.activeWindow) != -1 and
        context.windows.hasKey(frame.activeWindow):
      return frame.activeWindow
  0'u32

proc activeWindowForBspNode(
    context: JanetLayoutContext, nodeId: uint32
): rv.ProjectionWindowId =
  for node in context.tag.bspNodes:
    if node.id == nodeId and node.kind == FrameNodeKind.Leaf and node.window != 0 and
        context.windows.hasKey(node.window):
      let win = context.windows[node.window]
      if not win.isFloating and not win.isMinimized and not win.isUnmanagedGlobal:
        return node.window
  0'u32

proc validateLayoutInstructions*(
    context: JanetLayoutContext, instructions: openArray[JanetLayoutInstruction]
): tuple[
  ok: bool,
  error: string,
  outputTargetKind: JanetLayoutTargetKind,
  instructions: seq[rv.RenderInstruction],
] =
  if instructions.len == 0:
    if context.frameSubstrateActive():
      let expectedFrames = context.leafFrameIds()
      for frameId in expectedFrames:
        return
          (false, "layout omitted frame " & $frameId, JanetLayoutTargetKind.None, @[])
    elif context.bspSubstrateActive():
      let expectedNodes = context.leafBspNodeIds()
      for nodeId in expectedNodes:
        return
          (false, "layout omitted BSP node " & $nodeId, JanetLayoutTargetKind.None, @[])
    else:
      let expectedWindows = context.tiledWindowIds()
      for winId in expectedWindows:
        return (
          false,
          "layout omitted tiled window " & $winId,
          JanetLayoutTargetKind.None,
          @[],
        )
    return (true, "", JanetLayoutTargetKind.None, @[])

  let targetKind = instructions[0].targetKind
  if targetKind == JanetLayoutTargetKind.None:
    return (false, "layout instruction has no target", targetKind, @[])
  for instr in instructions:
    if instr.targetKind != targetKind:
      return (false, "layout mixed target instruction kinds", targetKind, @[])
    if instr.geom.w <= 0 or instr.geom.h <= 0:
      return (
        false,
        "instruction has non-positive geometry for target " & $instr.targetId,
        targetKind,
        @[],
      )

  case targetKind
  of JanetLayoutTargetKind.Window:
    let expected =
      if context.frameSubstrateActive():
        context.activeFrameWindowIds()
      elif context.bspSubstrateActive():
        context.activeBspWindowIds()
      else:
        context.tiledWindowIds()
    var seen = initHashSet[rv.ProjectionWindowId]()
    for instr in instructions:
      let winId = rv.ProjectionWindowId(instr.targetId)
      if winId notin expected:
        return (
          false,
          "instruction references unknown tiled window " & $winId,
          targetKind,
          @[],
        )
      if winId in seen:
        return
          (false, "instruction references duplicate window " & $winId, targetKind, @[])
      seen.incl(winId)
      result.instructions.add(rv.RenderInstruction(windowId: winId, geom: instr.geom))
    for winId in expected:
      if winId notin seen:
        return (false, "layout omitted tiled window " & $winId, targetKind, @[])
  of JanetLayoutTargetKind.Frame:
    if not context.frameSubstrateActive():
      return (false, "frame instructions require native frame data", targetKind, @[])
    let expected = context.leafFrameIds()
    var seen = initHashSet[uint32]()
    for instr in instructions:
      let frameId = instr.targetId
      if frameId notin expected:
        return (
          false,
          "instruction references unknown leaf frame " & $frameId,
          targetKind,
          @[],
        )
      if frameId in seen:
        return
          (false, "instruction references duplicate frame " & $frameId, targetKind, @[])
      seen.incl(frameId)
      let active = context.activeWindowForFrame(frameId)
      if active != 0:
        result.instructions.add(
          rv.RenderInstruction(windowId: active, geom: instr.geom)
        )
    for frameId in expected:
      if frameId notin seen:
        return (false, "layout omitted frame " & $frameId, targetKind, @[])
  of JanetLayoutTargetKind.BspNode:
    if not context.bspSubstrateActive():
      return (false, "BSP node instructions require native BSP data", targetKind, @[])
    let expected = context.leafBspNodeIds()
    var seen = initHashSet[uint32]()
    for instr in instructions:
      let nodeId = instr.targetId
      if nodeId notin expected:
        return (
          false,
          "instruction references unknown leaf BSP node " & $nodeId,
          targetKind,
          @[],
        )
      if nodeId in seen:
        return (
          false, "instruction references duplicate BSP node " & $nodeId, targetKind, @[]
        )
      seen.incl(nodeId)
      let active = context.activeWindowForBspNode(nodeId)
      if active != 0:
        result.instructions.add(
          rv.RenderInstruction(windowId: active, geom: instr.geom)
        )
    for nodeId in expected:
      if nodeId notin seen:
        return (false, "layout omitted BSP node " & $nodeId, targetKind, @[])
  of JanetLayoutTargetKind.None:
    discard

  result.ok = true
  result.outputTargetKind = targetKind

proc layoutBehaviorPayload*(evalResult: JanetLayoutEvalResult): JsonNode =
  %*{
    "layout_id": evalResult.layoutId.layoutIdString(),
    "path": evalResult.path,
    "outcome": $evalResult.outcome,
    "error": evalResult.error,
    "fallback_reason": evalResult.fallbackReason,
    "duration_ms": evalResult.durationMs,
    "substrate":
      if evalResult.inputBspNodeCount > 0:
        "bsp"
      elif evalResult.inputFrameCount > 0:
        "frames"
      else:
        "columns",
    "output_target": $evalResult.outputTargetKind,
    "input_windows": evalResult.inputWindowCount,
    "input_frames": evalResult.inputFrameCount,
    "input_bsp_nodes": evalResult.inputBspNodeCount,
    "instructions": evalResult.instructionCount,
  }

proc logLayoutEval*(result: JanetLayoutEvalResult) =
  writeBehaviorEvent("janet_layout_eval", result.layoutBehaviorPayload())
