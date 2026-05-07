import ../core/model

type
  Rect* = object
    x*, y*, w*, h*: int32

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

proc layoutScroller*(tag: TagState, screen: Rect, outerGap, innerGap: int32): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  if tag.columns.len == 0:
    return instructions

  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap
  
  var currentX = screen.x + outerGap - int32(tag.viewportXOffset)

  for col in tag.columns:
    let colWidth = int32(float32(usableWidth) * col.widthProportion) - innerGap
    
    if col.windows.len == 0:
      continue
      
    # Vertical stacking within the column (arrange_stack in Mango)
    let numWindows = col.windows.len
    let totalInnerGaps = (numWindows - 1) * innerGap
    let usableColHeight = usableHeight - totalInnerGaps
    
    var currentY = screen.y + outerGap
    
    for winId in col.windows:
      # For now, equal height proportions if not specified
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
      
    currentX += colWidth + innerGap

  return instructions
