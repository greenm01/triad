import std/math
import grid_math
import ../types/runtime_values

proc flattenTag(tag: TagState): seq[WindowId] =
  for col in tag.columns:
    for win in col.windows:
      result.add(win)

proc focusedFirst(windows: seq[WindowId], focused: WindowId): seq[WindowId] =
  let focusedIdx = windows.find(focused)
  if focusedIdx <= 0:
    return windows
  result.add(windows[focusedIdx])
  for idx, win in windows:
    if idx != focusedIdx:
      result.add(win)

proc layoutMasterStack*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  # Flatten windows for tiling
  let allWindows = flattenTag(tag)

  let n = allWindows.len
  if n == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  # Smart gaps for single window
  if n == 1:
    instructions.add(
      RenderInstruction(
        windowId: allWindows[0],
        geom: Rect(
          x: screen.x + safeOuterGap,
          y: screen.y + safeOuterGap,
          w: usableWidth,
          h: usableHeight,
        ),
      )
    )
    return instructions

  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount

  let mw =
    if mCount > 0 and sCount > 0:
      int32(float32(usableWidth) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableWidth

  let sw = usableWidth - mw

  # Master area
  if mCount > 0:
    let mh =
      max(0'i32, (usableHeight - (int32(mCount) - 1) * safeInnerGap) div int32(mCount))
    var curY = screen.y + safeOuterGap
    for i in 0 ..< mCount:
      instructions.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(
            x: screen.x + safeOuterGap,
            y: curY,
            w: max(0'i32, mw - (if sCount > 0: safeInnerGap div 2 else: 0)),
            h: mh,
          ),
        )
      )
      curY += mh + safeInnerGap

  # Stack area
  if sCount > 0:
    let sh =
      max(0'i32, (usableHeight - (int32(sCount) - 1) * safeInnerGap) div int32(sCount))
    var curY = screen.y + safeOuterGap
    let startX = screen.x + safeOuterGap + mw + (safeInnerGap div 2)
    for i in 0 ..< sCount:
      instructions.add(
        RenderInstruction(
          windowId: allWindows[mCount + i],
          geom:
            Rect(x: startX, y: curY, w: max(0'i32, sw - (safeInnerGap div 2)), h: sh),
        )
      )
      curY += sh + safeInnerGap

  return instructions

proc layoutGrid*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  let allWindows = flattenTag(tag)

  let n = allWindows.len
  if n == 0:
    return instructions

  let dims = gridDimensions(n)
  let cols = int32(dims.cols)
  let rows = int32(dims.rows)

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  let winW = max(0'i32, (usableWidth - (cols - 1) * safeInnerGap) div cols)
  let winH = max(0'i32, (usableHeight - (rows - 1) * safeInnerGap) div rows)

  for i in 0 ..< n:
    let col = int32(i) mod cols
    let row = int32(i) div cols

    instructions.add(
      RenderInstruction(
        windowId: allWindows[i],
        geom: Rect(
          x: screen.x + safeOuterGap + col * (winW + safeInnerGap),
          y: screen.y + safeOuterGap + row * (winH + safeInnerGap),
          w: winW,
          h: winH,
        ),
      )
    )

  return instructions

proc layoutMonocle*(
    tag: TagState, screen: Rect, outerGap: int32
): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]

  # Only layout the focused window if it exists, otherwise all windows at full size
  # In Monocle, we usually stack all windows on top of each other.

  let allWindows = flattenTag(tag)

  let n = allWindows.len
  if n == 0:
    return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  for winId in allWindows:
    instructions.add(
      RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: screen.x + safeOuterGap,
          y: screen.y + safeOuterGap,
          w: usableWidth,
          h: usableHeight,
        ),
      )
    )

  return instructions

proc layoutDeck*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = tag.flattenTag().focusedFirst(tag.focusedWindow)
  let n = allWindows.len
  if n == 0:
    return @[]

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  let mw =
    if sCount > 0:
      int32(float32(usableWidth) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableWidth
  let stackW = max(0'i32, usableWidth - mw - (if sCount > 0: safeInnerGap else: 0))

  if mCount > 0:
    let mh =
      max(0'i32, (usableHeight - int32(mCount - 1) * safeInnerGap) div int32(mCount))
    var y = screen.y + safeOuterGap
    for i in 0 ..< mCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(x: screen.x + safeOuterGap, y: y, w: mw, h: mh),
        )
      )
      y += mh + safeInnerGap

  if sCount > 0:
    let stackX = screen.x + safeOuterGap + mw + safeInnerGap
    for i in mCount ..< n:
      result.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(x: stackX, y: screen.y + safeOuterGap, w: stackW, h: usableHeight),
        )
      )

proc layoutRightTile*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = flattenTag(tag)
  let n = allWindows.len
  if n == 0:
    return @[]

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  let mw =
    if sCount > 0:
      int32(float32(usableWidth) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableWidth
  let sw = max(0'i32, usableWidth - mw - (if sCount > 0: safeInnerGap else: 0))

  if sCount > 0:
    let sh =
      max(0'i32, (usableHeight - int32(sCount - 1) * safeInnerGap) div int32(sCount))
    var y = screen.y + safeOuterGap
    for i in 0 ..< sCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[mCount + i],
          geom: Rect(x: screen.x + safeOuterGap, y: y, w: sw, h: sh),
        )
      )
      y += sh + safeInnerGap

  let masterX = screen.x + safeOuterGap + (if sCount > 0: sw + safeInnerGap
  else: 0)
  if mCount > 0:
    let mh =
      max(0'i32, (usableHeight - int32(mCount - 1) * safeInnerGap) div int32(mCount))
    var y = screen.y + safeOuterGap
    for i in 0 ..< mCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[i], geom: Rect(x: masterX, y: y, w: mw, h: mh)
        )
      )
      y += mh + safeInnerGap

proc layoutCenterTile*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = flattenTag(tag)
  let n = allWindows.len
  if n == 0:
    return @[]

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  let sideCountLeft = sCount div 2
  let sideCountRight = sCount - sideCountLeft
  let masterW =
    if sCount > 0:
      int32(float32(usableWidth) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableWidth
  let sideTotal = max(
    0'i32,
    usableWidth - masterW - (if sideCountLeft > 0: safeInnerGap else: 0) -
      (if sideCountRight > 0: safeInnerGap else: 0),
  )
  let leftW =
    if sideCountLeft > 0 and sideCountRight > 0:
      sideTotal div 2
    elif sideCountLeft > 0:
      sideTotal
    else:
      0
  let rightW =
    if sideCountRight > 0:
      sideTotal - leftW
    else:
      0
  let masterX =
    screen.x + safeOuterGap + (if sideCountLeft > 0: leftW + safeInnerGap
    else: 0)

  proc addVerticalStack(
      outInstrs: var seq[RenderInstruction], ids: seq[WindowId], x, w: int32
  ) =
    if ids.len == 0:
      return
    let h =
      max(0'i32, (usableHeight - int32(ids.len - 1) * safeInnerGap) div int32(ids.len))
    var y = screen.y + safeOuterGap
    for winId in ids:
      outInstrs.add(
        RenderInstruction(windowId: winId, geom: Rect(x: x, y: y, w: w, h: h))
      )
      y += h + safeInnerGap

  var leftIds: seq[WindowId] = @[]
  var rightIds: seq[WindowId] = @[]
  for i in 0 ..< sCount:
    if i mod 2 == 0:
      leftIds.add(allWindows[mCount + i])
    else:
      rightIds.add(allWindows[mCount + i])

  addVerticalStack(result, leftIds, screen.x + safeOuterGap, leftW)
  if mCount > 0:
    let mh =
      max(0'i32, (usableHeight - int32(mCount - 1) * safeInnerGap) div int32(mCount))
    var y = screen.y + safeOuterGap
    for i in 0 ..< mCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[i], geom: Rect(x: masterX, y: y, w: masterW, h: mh)
        )
      )
      y += mh + safeInnerGap
  addVerticalStack(
    result,
    rightIds,
    masterX + masterW + (if sideCountRight > 0: safeInnerGap else: 0),
    rightW,
  )

proc layoutVerticalMasterStack*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = flattenTag(tag)
  let n = allWindows.len
  if n == 0:
    return @[]

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  let mh =
    if sCount > 0:
      int32(float32(usableHeight) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableHeight
  let sh = max(0'i32, usableHeight - mh - (if sCount > 0: safeInnerGap else: 0))

  if mCount > 0:
    let mw =
      max(0'i32, (usableWidth - int32(mCount - 1) * safeInnerGap) div int32(mCount))
    var x = screen.x + safeOuterGap
    for i in 0 ..< mCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(x: x, y: screen.y + safeOuterGap, w: mw, h: mh),
        )
      )
      x += mw + safeInnerGap

  if sCount > 0:
    let sw =
      max(0'i32, (usableWidth - int32(sCount - 1) * safeInnerGap) div int32(sCount))
    var x = screen.x + safeOuterGap
    let stackY = screen.y + safeOuterGap + mh + safeInnerGap
    for i in 0 ..< sCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[mCount + i], geom: Rect(x: x, y: stackY, w: sw, h: sh)
        )
      )
      x += sw + safeInnerGap

proc layoutVerticalDeck*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = tag.flattenTag().focusedFirst(tag.focusedWindow)
  let n = allWindows.len
  if n == 0:
    return @[]

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  let mh =
    if sCount > 0:
      int32(float32(usableHeight) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio)))
    else:
      usableHeight
  let stackH = max(0'i32, usableHeight - mh - (if sCount > 0: safeInnerGap else: 0))

  if mCount > 0:
    let mw =
      max(0'i32, (usableWidth - int32(mCount - 1) * safeInnerGap) div int32(mCount))
    var x = screen.x + safeOuterGap
    for i in 0 ..< mCount:
      result.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(x: x, y: screen.y + safeOuterGap, w: mw, h: mh),
        )
      )
      x += mw + safeInnerGap

  if sCount > 0:
    let stackY = screen.y + safeOuterGap + mh + safeInnerGap
    for i in mCount ..< n:
      result.add(
        RenderInstruction(
          windowId: allWindows[i],
          geom: Rect(x: screen.x + safeOuterGap, y: stackY, w: usableWidth, h: stackH),
        )
      )

proc layoutVerticalGrid*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let allWindows = flattenTag(tag)
  let n = allWindows.len
  if n == 0:
    return @[]

  let rows = int32(sqrt(float64(n)).ceil)
  let cols = int32((float64(n) / float64(rows)).ceil)
  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  let winW = max(0'i32, (usableWidth - (cols - 1) * safeInnerGap) div cols)
  let winH = max(0'i32, (usableHeight - (rows - 1) * safeInnerGap) div rows)

  for i in 0 ..< n:
    let row = int32(i) mod rows
    let col = int32(i) div rows
    result.add(
      RenderInstruction(
        windowId: allWindows[i],
        geom: Rect(
          x: screen.x + safeOuterGap + col * (winW + safeInnerGap),
          y: screen.y + safeOuterGap + row * (winH + safeInnerGap),
          w: winW,
          h: winH,
        ),
      )
    )

proc layoutTGMix*(
    tag: TagState, screen: Rect, outerGap, innerGap: int32
): seq[RenderInstruction] =
  let n = tag.flattenTag().len
  if n <= 3:
    layoutMasterStack(tag, screen, outerGap, innerGap)
  else:
    layoutGrid(tag, screen, outerGap, innerGap)
