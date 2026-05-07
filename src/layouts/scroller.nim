import ../core/model

type
  Rect* = object
    x*, y*, w*, h*: int32

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

proc layoutScroller*(tag: TagState, screen: Rect, outerGap, innerGap: int32, 
                    focusCenter: bool, preferCenter: bool, centerMode: string): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  if tag.columns.len == 0:
    return instructions

  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap
  
  # Calculate virtual positions and find focused column
  var virtualX: seq[int32] = @[]
  var totalVirtualWidth: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i
    
    let colWidth = int32(float32(usableWidth) * col.widthProportion)
    virtualX.add(totalVirtualWidth)
    totalVirtualWidth += colWidth + innerGap

  # Calculate offset for centering
  var offset = tag.viewportXOffset
  
  if focusedColIdx != -1:
    let col = tag.columns[focusedColIdx]
    let colWidth = int32(float32(usableWidth) * col.widthProportion)
    let colCenterX = virtualX[focusedColIdx] + (colWidth div 2)
    let screenCenterX = usableWidth div 2
    
    if focusCenter or centerMode == "always":
      offset = float32(colCenterX - screenCenterX)
    elif preferCenter or centerMode == "on-overflow":
      # Only center if the column is out of view
      let colLeft = virtualX[focusedColIdx] - int32(offset)
      let colRight = colLeft + colWidth
      if colLeft < 0 or colRight > usableWidth:
        offset = float32(colCenterX - screenCenterX)

  # Final coordinate mapping
  for i, col in tag.columns:
    let colWidth = int32(float32(usableWidth) * col.widthProportion) - innerGap
    let currentX = screen.x + outerGap + virtualX[i] - int32(offset)

    if col.windows.len == 0:
      continue
      
    let numWindows = col.windows.len
    let totalInnerGaps = (numWindows - 1) * innerGap
    let usableColHeight = usableHeight - totalInnerGaps
    
    var currentY = screen.y + outerGap
    
    for winId in col.windows:
      # Vertical stacking within the column
      let winHeight = int32(usableColHeight div int32(numWindows))
      
      instructions.add(RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: currentX,
          y: currentY,
          w: colWidth,
          h: winHeight
        )
      ))
      
      currentY += winHeight + innerGap

  return instructions
