import ../types/model as model_types
import ../types/projection_values as rv

const AnchorVisibilityTolerance* = 1'i32

proc fixedSizeWidth*(win: model_types.WindowData): int32 =
  if win.minWidth > 0 and win.maxWidth == win.minWidth: win.minWidth else: 0'i32

proc fixedSizeHeight*(win: model_types.WindowData): int32 =
  if win.minHeight > 0 and win.maxHeight == win.minHeight: win.minHeight else: 0'i32

proc hasFixedSizeHint*(win: model_types.WindowData): bool =
  win.minWidth > 0 and win.minHeight > 0 and
    (win.fixedSizeWidth() > 0 or win.fixedSizeHeight() > 0)

proc clientFixedSizeWidth*(win: model_types.WindowData): int32 =
  if win.clientMinWidth > 0 and win.clientMaxWidth == win.clientMinWidth:
    win.clientMinWidth
  else:
    0'i32

proc clientFixedSizeHeight*(win: model_types.WindowData): int32 =
  if win.clientMinHeight > 0 and win.clientMaxHeight == win.clientMinHeight:
    win.clientMinHeight
  else:
    0'i32

proc hasClientFixedSizeHint*(win: model_types.WindowData): bool =
  win.clientMinWidth > 0 and win.clientMinHeight > 0 and
    (win.clientFixedSizeWidth() > 0 or win.clientFixedSizeHeight() > 0)

proc applyFloatingSizeHints*(win: model_types.WindowData, geom: rv.Rect): rv.Rect =
  result = geom
  let fixedW = win.fixedSizeWidth()
  let fixedH = win.fixedSizeHeight()
  if fixedW > 0:
    result.w = fixedW
  elif win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if fixedH > 0:
    result.h = fixedH
  elif win.minHeight > 0:
    result.h = max(result.h, win.minHeight)

  if win.maxWidth > 0:
    result.w = min(result.w, win.maxWidth)
  if win.maxHeight > 0:
    result.h = min(result.h, win.maxHeight)

proc clampToScreen*(geom, screen: rv.Rect): rv.Rect =
  result = geom
  result.w = max(0'i32, result.w)
  result.h = max(0'i32, result.h)
  if screen.w > 0:
    result.w = min(result.w, screen.w)
    result.x = clamp(result.x, screen.x, screen.x + screen.w - result.w)
  if screen.h > 0:
    result.h = min(result.h, screen.h)
    result.y = clamp(result.y, screen.y, screen.y + screen.h - result.h)

proc intersects*(a, b: rv.Rect): bool =
  if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0:
    return false
  a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y

proc fullyWithin*(inner, outer: rv.Rect, tolerance = AnchorVisibilityTolerance): bool =
  if inner.w <= 0 or inner.h <= 0 or outer.w <= 0 or outer.h <= 0:
    return false
  inner.x >= outer.x - tolerance and inner.y >= outer.y - tolerance and
    inner.x + inner.w <= outer.x + outer.w + tolerance and
    inner.y + inner.h <= outer.y + outer.h + tolerance

proc centeredIn*(bounds, geom: rv.Rect): rv.Rect =
  result = geom
  result.x = bounds.x + (bounds.w - geom.w) div 2
  result.y = bounds.y + (bounds.h - geom.h) div 2

proc positionedByAnchor*(
    bounds, geom: rv.Rect, position: rv.WindowRuleFloatingPositionConfig
): rv.Rect =
  result = geom
  case position.relativeTo
  of rv.FloatingPositionAnchor.TopLeft:
    result.x = bounds.x + position.x
    result.y = bounds.y + position.y
  of rv.FloatingPositionAnchor.TopRight:
    result.x = bounds.x + bounds.w - geom.w - position.x
    result.y = bounds.y + position.y
  of rv.FloatingPositionAnchor.BottomLeft:
    result.x = bounds.x + position.x
    result.y = bounds.y + bounds.h - geom.h - position.y
  of rv.FloatingPositionAnchor.BottomRight:
    result.x = bounds.x + bounds.w - geom.w - position.x
    result.y = bounds.y + bounds.h - geom.h - position.y
  of rv.FloatingPositionAnchor.Top:
    result.x = bounds.x + (bounds.w - geom.w) div 2 + position.x
    result.y = bounds.y + position.y
  of rv.FloatingPositionAnchor.Bottom:
    result.x = bounds.x + (bounds.w - geom.w) div 2 + position.x
    result.y = bounds.y + bounds.h - geom.h - position.y
  of rv.FloatingPositionAnchor.Left:
    result.x = bounds.x + position.x
    result.y = bounds.y + (bounds.h - geom.h) div 2 + position.y
  of rv.FloatingPositionAnchor.Right:
    result.x = bounds.x + bounds.w - geom.w - position.x
    result.y = bounds.y + (bounds.h - geom.h) div 2 + position.y

proc anchoredFloatingGeom*(
    win: model_types.WindowData, parentGeom, fallbackGeom, screen: rv.Rect
): rv.Rect =
  result = fallbackGeom
  if win.parentAutoFloating:
    if parentGeom.w > 0:
      result.w = min(result.w, parentGeom.w)
    if parentGeom.h > 0:
      result.h = min(result.h, parentGeom.h)
  result = win.applyFloatingSizeHints(result)
  result = parentGeom.centeredIn(result)
  result = result.clampToScreen(screen)
