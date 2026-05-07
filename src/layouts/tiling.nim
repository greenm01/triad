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

  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap
  
  # Smart gaps for single window
  if n == 1:
    instructions.add(RenderInstruction(
      windowId: allWindows[0],
      geom: Rect(x: screen.x + outerGap, y: screen.y + outerGap, w: usableWidth, h: usableHeight)
    ))
    return instructions

  let mCount = min(n, tag.masterCount)
  let sCount = n - mCount
  
  let mw = if mCount > 0 and sCount > 0: 
             int32(float32(usableWidth) * tag.masterSplitRatio) 
           else: 
             usableWidth
             
  let sw = usableWidth - mw
  
  # Master area
  if mCount > 0:
    let mh = (usableHeight - (int32(mCount) - 1) * innerGap) div int32(mCount)
    var curY = screen.y + outerGap
    for i in 0 ..< mCount:
      instructions.add(RenderInstruction(
        windowId: allWindows[i],
        geom: Rect(x: screen.x + outerGap, y: curY, w: mw - (if sCount > 0: innerGap div 2 else: 0), h: mh)
      ))
      curY += mh + innerGap

  # Stack area
  if sCount > 0:
    let sh = (usableHeight - (int32(sCount) - 1) * innerGap) div int32(sCount)
    var curY = screen.y + outerGap
    let startX = screen.x + outerGap + mw + (innerGap div 2)
    for i in 0 ..< sCount:
      instructions.add(RenderInstruction(
        windowId: allWindows[mCount + i],
        geom: Rect(x: startX, y: curY, w: sw - (innerGap div 2), h: sh)
      ))
      curY += sh + innerGap

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
  
  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap
  
  let winW = (usableWidth - (cols - 1) * innerGap) div cols
  let winH = (usableHeight - (rows - 1) * innerGap) div rows
  
  for i in 0 ..< n:
    let col = int32(i) mod cols
    let row = int32(i) div cols
    
    instructions.add(RenderInstruction(
      windowId: allWindows[i],
      geom: Rect(
        x: screen.x + outerGap + col * (winW + innerGap),
        y: screen.y + outerGap + row * (winH + innerGap),
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

  let usableWidth = screen.w - 2 * outerGap
  let usableHeight = screen.h - 2 * outerGap

  for winId in allWindows:
    instructions.add(RenderInstruction(
      windowId: winId,
      geom: Rect(x: screen.x + outerGap, y: screen.y + outerGap, w: usableWidth, h: usableHeight)
    ))

  return instructions
