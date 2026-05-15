from ../types/core import Rect

const
  RenderEdgeTop* = 1'u32
  RenderEdgeBottom* = 2'u32
  RenderEdgeLeft* = 4'u32
  RenderEdgeRight* = 8'u32
  RenderAllEdges* =
    RenderEdgeTop or RenderEdgeBottom or RenderEdgeLeft or RenderEdgeRight

type
  RenderVisibility* = object
    visible*: bool
    clipX*, clipY*, clipW*, clipH*: int32
    borderEdges*: uint32
    clipped*: bool

  RenderClipBoxes* = object
    windowX*, windowY*, windowW*, windowH*: int32
    contentX*, contentY*, contentW*, contentH*: int32

proc hasRenderEdge(edges, edge: uint32): bool =
  (edges and edge) != 0

proc renderVisibility*(
    geom, screen: Rect, minVisibleThickness: int32
): RenderVisibility =
  let
    left = max(geom.x, screen.x)
    top = max(geom.y, screen.y)
    right = min(geom.x + geom.w, screen.x + screen.w)
    bottom = min(geom.y + geom.h, screen.y + screen.h)
    visibleW = max(0'i32, right - left)
    visibleH = max(0'i32, bottom - top)

  result.clipX = max(0'i32, screen.x - geom.x)
  result.clipY = max(0'i32, screen.y - geom.y)
  result.clipW = visibleW
  result.clipH = visibleH

  if visibleW <= 0 or visibleH <= 0:
    result.visible = false
    result.borderEdges = 0
    return

  result.clipped =
    result.clipX > 0 or result.clipY > 0 or result.clipW < geom.w or
    result.clipH < geom.h

  if result.clipped and
      (visibleW <= minVisibleThickness or visibleH <= minVisibleThickness):
    result.visible = false
    result.borderEdges = 0
    return

  result.visible = true
  result.borderEdges = RenderAllEdges

  let clippedHorizontally = geom.x < screen.x or geom.x + geom.w > screen.x + screen.w
  let clippedVertically = geom.y < screen.y or geom.y + geom.h > screen.y + screen.h

  if clippedHorizontally:
    result.borderEdges = result.borderEdges and not (RenderEdgeLeft or RenderEdgeRight)
  if clippedVertically:
    result.borderEdges = result.borderEdges and not (RenderEdgeTop or RenderEdgeBottom)

proc renderClipBoxes*(
    visibility: RenderVisibility, borderWidth: int32
): RenderClipBoxes =
  result.contentX = visibility.clipX
  result.contentY = visibility.clipY
  result.contentW = visibility.clipW
  result.contentH = visibility.clipH
  if not visibility.visible:
    return

  let border = max(0'i32, borderWidth)
  let leftPad =
    if visibility.borderEdges.hasRenderEdge(RenderEdgeLeft): border else: 0'i32
  let rightPad =
    if visibility.borderEdges.hasRenderEdge(RenderEdgeRight): border else: 0'i32
  let topPad =
    if visibility.borderEdges.hasRenderEdge(RenderEdgeTop): border else: 0'i32
  let bottomPad =
    if visibility.borderEdges.hasRenderEdge(RenderEdgeBottom): border else: 0'i32

  result.windowX = visibility.clipX - leftPad
  result.windowY = visibility.clipY - topPad
  result.windowW = max(0'i32, visibility.clipW + leftPad + rightPad)
  result.windowH = max(0'i32, visibility.clipH + topPad + bottomPad)
