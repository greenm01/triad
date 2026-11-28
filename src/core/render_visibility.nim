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
    geom, screen: Rect, minVisibleThickness: int32, keepVisibleBorders = false
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

  var hiddenEdges = 0'u32
  if geom.x < screen.x:
    hiddenEdges = hiddenEdges or RenderEdgeLeft
  if geom.x + geom.w > screen.x + screen.w:
    hiddenEdges = hiddenEdges or RenderEdgeRight
  if geom.y < screen.y:
    hiddenEdges = hiddenEdges or RenderEdgeTop
  if geom.y + geom.h > screen.y + screen.h:
    hiddenEdges = hiddenEdges or RenderEdgeBottom

  if not keepVisibleBorders:
    # A tiled column cut by the screen edge shows no border rails on either side.
    if (hiddenEdges and (RenderEdgeLeft or RenderEdgeRight)) != 0:
      hiddenEdges = hiddenEdges or RenderEdgeLeft or RenderEdgeRight
    if (hiddenEdges and (RenderEdgeTop or RenderEdgeBottom)) != 0:
      hiddenEdges = hiddenEdges or RenderEdgeTop or RenderEdgeBottom

  result.borderEdges = RenderAllEdges and not hiddenEdges

proc renderClipBoxes*(
    visibility: RenderVisibility, borderWidth: int32
): RenderClipBoxes =
  # River places borders as if the content clip box starts at the window
  # origin, so a box offset past an off-screen left or top edge pulls the
  # right and bottom borders inward. Anchor the content box at the origin and
  # let the window clip box cut away the off-screen part.
  result.contentX = 0
  result.contentY = 0
  result.contentW = visibility.clipX + visibility.clipW
  result.contentH = visibility.clipY + visibility.clipH
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
