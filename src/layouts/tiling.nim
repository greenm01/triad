import ../core/model, math

proc layoutMasterStack*(tag: TagState, screen: Rect, outerGap, innerGap: int32): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  # Flatten windows for tiling
  var allWindows: seq[WindowId] = @[]
  for col in tag.columns:
    for win in col.windows:
      allWindows.add(win)
      
  let n = allWindows.len
  if n == 0: return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  
  # Smart gaps for single window
  if n == 1:
    instructions.add(RenderInstruction(
      windowId: allWindows[0],
      geom: Rect(x: screen.x + safeOuterGap, y: screen.y + safeOuterGap, w: usableWidth, h: usableHeight)
    ))
    return instructions

  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  
  let mw = if mCount > 0 and sCount > 0: 
             int32(float32(usableWidth) * min(0.95'f32, max(0.05'f32, tag.masterSplitRatio))) 
           else: 
             usableWidth
             
  let sw = usableWidth - mw
  
  # Master area
  if mCount > 0:
    let mh = max(0'i32, (usableHeight - (int32(mCount) - 1) * safeInnerGap) div int32(mCount))
    var curY = screen.y + safeOuterGap
    for i in 0 ..< mCount:
      instructions.add(RenderInstruction(
        windowId: allWindows[i],
        geom: Rect(x: screen.x + safeOuterGap, y: curY, w: max(0'i32, mw - (if sCount > 0: safeInnerGap div 2 else: 0)), h: mh)
      ))
      curY += mh + safeInnerGap

  # Stack area
  if sCount > 0:
    let sh = max(0'i32, (usableHeight - (int32(sCount) - 1) * safeInnerGap) div int32(sCount))
    var curY = screen.y + safeOuterGap
    let startX = screen.x + safeOuterGap + mw + (safeInnerGap div 2)
    for i in 0 ..< sCount:
      instructions.add(RenderInstruction(
        windowId: allWindows[mCount + i],
        geom: Rect(x: startX, y: curY, w: max(0'i32, sw - (safeInnerGap div 2)), h: sh)
      ))
      curY += sh + safeInnerGap

  return instructions

proc layoutGrid*(tag: TagState, screen: Rect, outerGap, innerGap: int32): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  var allWindows: seq[WindowId] = @[]
  for col in tag.columns:
    for win in col.windows:
      allWindows.add(win)
      
  let n = allWindows.len
  if n == 0: return instructions

  let cols = int32(sqrt(float64(n)).ceil)
  let rows = int32((float64(n) / float64(cols)).ceil)
  
  let safeOuterGap = max(0'i32, outerGap)
  let safeInnerGap = max(0'i32, innerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)
  
  let winW = max(0'i32, (usableWidth - (cols - 1) * safeInnerGap) div cols)
  let winH = max(0'i32, (usableHeight - (rows - 1) * safeInnerGap) div rows)
  
  for i in 0 ..< n:
    let col = int32(i) mod cols
    let row = int32(i) div cols
    
    instructions.add(RenderInstruction(
      windowId: allWindows[i],
      geom: Rect(
        x: screen.x + safeOuterGap + col * (winW + safeInnerGap),
        y: screen.y + safeOuterGap + row * (winH + safeInnerGap),
        w: winW,
        h: winH
      )
    ))

  return instructions

proc layoutMonocle*(tag: TagState, screen: Rect, outerGap: int32): seq[RenderInstruction] =
  var instructions: seq[RenderInstruction] = @[]
  
  # Only layout the focused window if it exists, otherwise all windows at full size
  # In Monocle, we usually stack all windows on top of each other.
  
  var allWindows: seq[WindowId] = @[]
  for col in tag.columns:
    for win in col.windows:
      allWindows.add(win)
      
  let n = allWindows.len
  if n == 0: return instructions

  let safeOuterGap = max(0'i32, outerGap)
  let usableWidth = max(0'i32, screen.w - 2 * safeOuterGap)
  let usableHeight = max(0'i32, screen.h - 2 * safeOuterGap)

  for winId in allWindows:
    instructions.add(RenderInstruction(
      windowId: winId,
      geom: Rect(x: screen.x + safeOuterGap, y: screen.y + safeOuterGap, w: usableWidth, h: usableHeight)
    ))

  return instructions
