import ../types/runtime_values

proc rectContains(rect: Rect; x, y: int32): bool =
  x >= rect.x and y >= rect.y and
    x < rect.x + rect.w and y < rect.y + rect.h

proc overviewHitTest*(
    instructions: openArray[RenderInstruction]; x, y: int32): WindowId =
  if instructions.len == 0:
    return 0'u32
  for idx in countdown(instructions.len - 1, 0):
    let instr = instructions[idx]
    if instr.geom.rectContains(x, y):
      return instr.windowId
  0'u32
