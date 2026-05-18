import std/[options, tables]
import focus
import ../core/layout_selection_codec
import ../state/engine
import ../types/janet_layouts
import ../types/projection_values as rv
from ../types/runtime_values import Direction

proc projectionWindowId(model: Model, winId: WindowId): rv.ProjectionWindowId =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return rv.ProjectionWindowId(uint32(winOpt.get().externalId))
  0'u32

proc visibleTiledWindowOrder(model: Model, tagId: TagId): seq[WindowId] =
  for _, column in model.columnsOnTagWithId(tagId):
    for winId, win in model.windowsOnColumnWithId(column.id):
      if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
          not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId):
        result.add(winId)

proc moveFocusedWindowInOrder(model: var Model, delta: int32): bool =
  if delta notin [-1'i32, 1'i32]:
    return false
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false
  let windows = model.visibleTiledWindowOrder(tagId)
  let idx = windows.find(focused)
  if idx < 0:
    return false
  let targetIdx = idx + int(delta)
  if targetIdx < 0 or targetIdx >= windows.len:
    return false
  model.swapPlacedWindows(tagId, focused, tagId, windows[targetIdx])

proc customMovementContext(model: Model): Option[JanetLayoutContext] =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return none(JanetLayoutContext)
  let tag = tagOpt.get()
  let layoutId = tag.customLayoutId
  if layoutId.layoutIdString().len == 0:
    return none(JanetLayoutContext)

  var windows = initTable[rv.ProjectionWindowId, rv.ProjectedWindow]()
  var columns: seq[rv.ProjectedColumn] = @[]
  for _, column in model.columnsOnTagWithId(model.activeTag):
    var columnWindows: seq[rv.ProjectionWindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(column.id):
      if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
          not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId):
        let externalId = model.projectionWindowId(winId)
        columnWindows.add(externalId)
        windows[externalId] =
          rv.ProjectedWindow(id: externalId, title: win.title, appId: win.appId)
    if columnWindows.len > 0:
      columns.add(
        rv.ProjectedColumn(
          windows: columnWindows,
          widthProportion: column.widthProportion,
          scrollerSingleProportion: column.scrollerSingleProportion,
          isFullWidth: column.isFullWidth,
        )
      )

  some(
    JanetLayoutContext(
      layoutId: layoutId,
      screen: rv.Rect(),
      outerGap: model.outerGaps,
      innerGap: model.innerGaps,
      tag: rv.ProjectedTag(
        tagId: tag.slot,
        name: tag.name,
        layoutMode: tag.layoutMode,
        focusedWindow: model.projectionWindowId(tag.focusedWindow),
        columns: columns,
        masterCount: tag.masterCount,
        masterSplitRatio: tag.masterSplitRatio,
      ),
      windows: windows,
      spiral: model.spiral,
    )
  )

proc applyCustomLayoutMovement*(
    model: var Model, direction: Direction, movementEval: CustomLayoutMovementEval
): tuple[handled: bool, dirty: bool] =
  if movementEval == nil:
    return (false, false)
  let context = model.customMovementContext()
  if context.isNone:
    return (false, false)
  let movement = movementEval(context.get(), direction)
  if not movement.handled:
    return (false, false)
  if not movement.ok:
    return (true, false)
  case movement.op
  of JanetLayoutMovementOp.Noop:
    (true, false)
  of JanetLayoutMovementOp.MoveOrder:
    (true, model.moveFocusedWindowInOrder(movement.delta))
  of JanetLayoutMovementOp.None:
    (true, false)
