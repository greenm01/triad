import std/tables
import ../types/runtime_values

proc clampProportion(value: float32; lo = 0.05'f32; hi = 1.0'f32): float32 =
  clamp(value, lo, hi)

proc layoutScroller*(tag: var TagState; windows: Table[WindowId, WindowData]; screen: Rect; outerGap, innerGap: int32;
                    focusCenter: bool; preferCenter: bool;
                        centerMode: string): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  if tag.columns.len == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  # Calculate virtual positions and find focused column
  var virtualX: seq[int32] = @[]
  var totalVirtualWidth: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i

    let colWidth = int32(float32(usableWidth) * clampProportion(
        col.widthProportion))
    virtualX.add(totalVirtualWidth)
    totalVirtualWidth += colWidth

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let col = tag.columns[focusedColIdx]
    let colWidth = int32(float32(usableWidth) * clampProportion(
        col.widthProportion))
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
    let colWidth = max(0'i32, int32(float32(usableWidth) * clampProportion(
        col.widthProportion)) - safeInnerGap)
    let currentX = screen.x + safeOuterGap + virtualX[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue

    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColHeight = max(0'i32, usableHeight - totalInnerGaps)

    # Calculate sum of proportions for normalization
    var totalHeightProp: float32 = 0.0
    for winId in col.windows:
      if windows.hasKey(winId):
        totalHeightProp += clampProportion(windows[winId].heightProportion)
      else:
        totalHeightProp += 1.0
    if totalHeightProp <= 0:
      totalHeightProp = 1.0

    var currentY = screen.y + safeOuterGap

    for winId in col.windows:
      # Vertical stacking within the column
      let winProp = if windows.hasKey(winId): clampProportion(windows[
          winId].heightProportion) else: 1.0'f32
      let winHeight = max(0'i32, int32(float32(usableColHeight) * (winProp /
          totalHeightProp)))

      instructions.add(RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: currentX,
          y: currentY,
          w: colWidth,
          h: winHeight
        )
      ))

      currentY += winHeight + safeInnerGap

  return instructions

proc layoutVerticalScroller*(tag: var TagState; windows: Table[WindowId, WindowData]; screen: Rect; outerGap, innerGap: int32;
                            focusCenter: bool; preferCenter: bool;
                                centerMode: string): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  if tag.columns.len == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  # Calculate virtual positions and find focused column
  var virtualY: seq[int32] = @[]
  var totalVirtualHeight: int32 = 0
  var focusedColIdx = -1

  for i, col in tag.columns:
    if col.windows.contains(tag.focusedWindow):
      focusedColIdx = i

    let colHeight = int32(float32(usableHeight) * clampProportion(
        col.widthProportion))
    virtualY.add(totalVirtualHeight)
    totalVirtualHeight += colHeight + safeInnerGap

  # Calculate target offset for centering
  if focusedColIdx != -1:
    let colHeight = int32(float32(usableHeight) * clampProportion(tag.columns[
        focusedColIdx].widthProportion))
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
    let colHeight = max(0'i32, int32(float32(usableHeight) * clampProportion(
        col.widthProportion)) - safeInnerGap)
    let currentY = screen.y + safeOuterGap + virtualY[i] - int32(renderOffset)

    if col.windows.len == 0:
      continue

    let numWindows = col.windows.len
    let totalInnerGaps = int32(numWindows - 1) * safeInnerGap
    let usableColWidth = max(0'i32, usableWidth - totalInnerGaps)

    # Calculate sum of proportions for normalization
    var totalWidthProp: float32 = 0.0
    for winId in col.windows:
      if windows.hasKey(winId):
        totalWidthProp += clampProportion(windows[winId].widthProportion)
      else:
        totalWidthProp += 1.0
    if totalWidthProp <= 0:
      totalWidthProp = 1.0

    var currentX = screen.x + safeOuterGap

    for winId in col.windows:
      # Horizontal stacking within the row
      let winProp = if windows.hasKey(winId): clampProportion(windows[
          winId].widthProportion) else: 1.0'f32
      let winWidth = max(0'i32, int32(float32(usableColWidth) * (winProp /
          totalWidthProp)))

      instructions.add(RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: currentX,
          y: currentY,
          w: winWidth,
          h: colHeight
        )
      ))

      currentX += winWidth + safeInnerGap

  return instructions
