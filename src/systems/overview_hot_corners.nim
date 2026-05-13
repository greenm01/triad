import ../state/engine
from ../types/runtime_values import OverviewHotCornersConfig

proc enabled*(config: OverviewHotCornersConfig): bool =
  config.topLeft or config.topRight or config.bottomLeft or config.bottomRight

proc effectiveOverviewHotCornerSize*(model: Model): int32 =
  if model.overviewHotCorners.size > 0:
    clamp(model.overviewHotCorners.size, 1'i32, 1000'i32)
  else:
    DefaultOverviewHotCornerSize

proc pointInTopLeft(rect: Rect, size, x, y: int32): bool =
  x >= rect.x and x < rect.x + size and y >= rect.y and y < rect.y + size

proc pointInTopRight(rect: Rect, size, x, y: int32): bool =
  x >= rect.x + rect.w - size and x < rect.x + rect.w and y >= rect.y and
    y < rect.y + size

proc pointInBottomLeft(rect: Rect, size, x, y: int32): bool =
  x >= rect.x and x < rect.x + size and y >= rect.y + rect.h - size and
    y < rect.y + rect.h

proc pointInBottomRight(rect: Rect, size, x, y: int32): bool =
  x >= rect.x + rect.w - size and x < rect.x + rect.w and y >= rect.y + rect.h - size and
    y < rect.y + rect.h

proc overviewHotCornerAt*(model: Model, x, y: int32): bool =
  let corners = model.overviewHotCorners
  if not corners.enabled():
    return false

  let size = model.effectiveOverviewHotCornerSize()
  for _, output in model.outputsWithId():
    if output.w <= 0 or output.h <= 0:
      continue
    let rect = Rect(x: output.x, y: output.y, w: output.w, h: output.h)
    if corners.topLeft and rect.pointInTopLeft(size, x, y):
      return true
    if corners.topRight and rect.pointInTopRight(size, x, y):
      return true
    if corners.bottomLeft and rect.pointInBottomLeft(size, x, y):
      return true
    if corners.bottomRight and rect.pointInBottomRight(size, x, y):
      return true

  if model.outputsCount() == 0 and model.screenWidth > 0 and model.screenHeight > 0:
    let rect = Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)
    if corners.topLeft and rect.pointInTopLeft(size, x, y):
      return true
    if corners.topRight and rect.pointInTopRight(size, x, y):
      return true
    if corners.bottomLeft and rect.pointInBottomLeft(size, x, y):
      return true
    if corners.bottomRight and rect.pointInBottomRight(size, x, y):
      return true

  false
