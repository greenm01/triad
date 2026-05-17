import std/[algorithm, json, sets, strutils, tables]
import ../types/janet_layouts
import ../types/projection_values as rv
import ../utils/behavior_log
import binding

proc janetLayoutId*(value: string): JanetLayoutId =
  JanetLayoutId(value)

proc layoutIdString*(layoutId: JanetLayoutId): string =
  string(layoutId)

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

proc rectExpr(rect: rv.Rect): string =
  "{:x " & $rect.x & " :y " & $rect.y & " :w " & $rect.w & " :h " & $rect.h & "}"

proc columnExpr(column: rv.ProjectedColumn): string =
  var windows: seq[string] = @[]
  for winId in column.windows:
    windows.add($winId)
  "{:windows [" & windows.join(" ") & "] :width-proportion " & $column.widthProportion &
    " :scroller-single-proportion " & $column.scrollerSingleProportion & " :full-width " &
    column.isFullWidth.boolValue() & "}"

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
  var windows: seq[string] = @[]
  var windowIds: seq[rv.ProjectionWindowId] = @[]
  for id in context.windows.keys:
    windowIds.add(id)
  windowIds.sort()
  for column in context.tag.columns:
    columns.add(column.columnExpr())
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
         :columns [$14]}
   :windows [$15]})
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
    windows.join(" "),
  ]

proc extractedLayoutInstructions*(handle: JanetHandle): seq[rv.RenderInstruction] =
  for idx in 0 ..< int(triadJanetLayoutInstructionCount(handle)):
    result.add(
      rv.RenderInstruction(
        windowId: rv.ProjectionWindowId(triadJanetLayoutWindowId(handle, cint(idx))),
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

proc validateLayoutInstructions*(
    context: JanetLayoutContext, instructions: openArray[rv.RenderInstruction]
): tuple[ok: bool, error: string] =
  let expected = context.tiledWindowIds()
  var seen = initHashSet[rv.ProjectionWindowId]()
  for instr in instructions:
    if instr.windowId notin expected:
      return (false, "instruction references unknown tiled window " & $instr.windowId)
    if instr.windowId in seen:
      return (false, "instruction references duplicate window " & $instr.windowId)
    if instr.geom.w <= 0 or instr.geom.h <= 0:
      return
        (false, "instruction has non-positive geometry for window " & $instr.windowId)
    seen.incl(instr.windowId)

  for winId in expected:
    if winId notin seen:
      return (false, "layout omitted tiled window " & $winId)
  (true, "")

proc layoutBehaviorPayload*(evalResult: JanetLayoutEvalResult): JsonNode =
  %*{
    "layout_id": evalResult.layoutId.layoutIdString(),
    "path": evalResult.path,
    "outcome": $evalResult.outcome,
    "error": evalResult.error,
    "fallback_reason": evalResult.fallbackReason,
    "duration_ms": evalResult.durationMs,
    "input_windows": evalResult.inputWindowCount,
    "instructions": evalResult.instructionCount,
  }

proc logLayoutEval*(result: JanetLayoutEvalResult) =
  writeBehaviorEvent("janet_layout_eval", result.layoutBehaviorPayload())
