import ../core/model, tables

proc layoutScroller*(tag: var TagState, windows: Table[WindowId, WindowData], screen: Rect, outerGap, innerGap: int32, 
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
    totalVirtualWidth += colWidth

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let col = tag.columns[focusedColIdx]
    let colWidth = int32(float32(usableWidth) * col.widthProportion)
    let colCenterX = virtualX[focusedColIdx] + (colWidth div 2)
    let screenCenterX = usableWidth div 2
    
    if focusCenter or centerMode == "always":
      tag.targetViewportXOffset = float32(colCenterX - screenCenterX)
    elif preferCenter or centerMode == "on-overflow":
      # Only center if the column is out of view
      let colLeft = virtualX[focusedColIdx] - int32(tag.targetViewportXOffset)
      let colRight = colLeft + colWidth
      if colLeft < 0 or colRight > usableWidth:
        tag.targetViewportXOffset = float32(colCenterX - screenCenterX)

  # Use current offset for rendering (interpolated in update.nim)
  let renderOffset = tag.currentViewportXOffset

  # Final coordinate mapping
  for i, col in tag.columns:
    let colWidth = int32(float32(usableWidth) * col.widthProportion) - innerGap
    let currentX = screen.x + outerGap + virtualX[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue
      
    let numWindows = col.windows.len
    let totalInnerGaps = (numWindows - 1) * innerGap
    let usableColHeight = usableHeight - totalInnerGaps
    
    # Calculate sum of proportions for normalization
    var totalHeightProp: float32 = 0.0
    for winId in col.windows:
      if windows.hasKey(winId):
        totalHeightProp += windows[winId].heightProportion
      else:
        totalHeightProp += 1.0

    var currentY = screen.y + outerGap
    
    for winId in col.windows:
      # Vertical stacking within the column
      let winProp = if windows.hasKey(winId): windows[winId].heightProportion else: 1.0
      let winHeight = int32(float32(usableColHeight) * (winProp / totalHeightProp))
      
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

proc layoutVerticalScroller*(tag: var TagState, windows: Table[WindowId, WindowData], screen: Rect, outerGap, innerGap: int32, 
                            focusCenter: bool, preferCenter: bool, centerMode: string): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  if tag.columns.len == 0:
    return instructions

  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap
  
  # Calculate virtual positions and find focused column
  var virtualY: seq[int32] = @[]
  var totalVirtualHeight: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i
    
    let colHeight = int32(float32(usableHeight) * col.widthProportion)
    virtualY.add(totalVirtualHeight)
    totalVirtualHeight += colHeight + innerGap

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let colHeight = int32(float32(usableHeight) * tag.columns[focusedColIdx].widthProportion)
    let colCenterY = virtualY[focusedColIdx] + (colHeight div 2)
    let screenCenterY = usableHeight div 2
    
    if focusCenter or centerMode == "always":
      tag.targetViewportYOffset = float32(colCenterY - screenCenterY)
    elif preferCenter or centerMode == "on-overflow":
      let colTop = virtualY[focusedColIdx] - int32(tag.targetViewportYOffset)
      let colBottom = colTop + colHeight
      if colTop < 0 or colBottom > usableHeight:
        tag.targetViewportYOffset = float32(colCenterY - screenCenterY)

  # Use current offset for rendering
  let renderOffset = tag.currentViewportYOffset

  # Final coordinate mapping
  for i, col in tag.columns:
    let colHeight = int32(float32(usableHeight) * col.widthProportion) - innerGap
    let currentY = screen.y + outerGap + virtualY[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue
      
    let numWindows = col.windows.len
    let totalInnerGaps = (numWindows - 1) * innerGap
    let usableColWidth = usableWidth - totalInnerGaps
    
    # Calculate sum of proportions for normalization
    var totalWidthProp: float32 = 0.0
    for winId in col.windows:
      if windows.hasKey(winId):
        totalWidthProp += windows[winId].widthProportion
      else:
        totalWidthProp += 1.0

    var currentX = screen.x + outerGap
    
    for winId in col.windows:
      # Horizontal stacking within the row
      let winProp = if windows.hasKey(winId): windows[winId].widthProportion else: 1.0
      let winWidth = int32(float32(usableColWidth) * (winProp / totalWidthProp))
      
      instructions.add(RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: currentX,
          y: currentY,
          w: winWidth,
          h: colHeight
        )
      ))
      
      currentX += winWidth + innerGap

  return instructions
