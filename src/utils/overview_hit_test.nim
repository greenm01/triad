import ../types/projection_values

proc rectContains(rect: Rect, x, y: int32): bool =
  x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h

proc rectIntersection(a, b: Rect): Rect =
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.w, b.x + b.w)
  let y2 = min(a.y + a.h, b.y + b.h)
  Rect(x: x1, y: y1, w: max(0'i32, x2 - x1), h: max(0'i32, y2 - y1))

proc overviewHitTest*(
    instructions: openArray[RenderInstruction], x, y: int32
): ProjectionWindowId =
  if instructions.len == 0:
    return 0'u32
  for idx in countdown(instructions.len - 1, 0):
    let instr = instructions[idx]
    let hitRect =
      if instr.clipSet:
        rectIntersection(instr.geom, instr.clip)
      else:
        instr.geom
    if hitRect.rectContains(x, y):
      return instr.windowId
  0'u32
