import math

proc gridDimensions*(count: int): tuple[cols, rows: int] =
  if count <= 0:
    return (0, 0)
  result.cols = int(ceil(sqrt(float64(count))))
  result.rows = int(ceil(float64(count) / float64(result.cols)))

proc gridIndexByDelta*(
    index, count, deltaCol, deltaRow: int): int =
  if index < 0 or index >= count or count <= 0:
    return -1

  let dims = gridDimensions(count)
  let col = index mod dims.cols
  let row = index div dims.cols
  let targetCol = col + deltaCol
  let targetRow = row + deltaRow

  if targetCol < 0 or targetCol >= dims.cols or targetRow < 0 or
      targetRow >= dims.rows:
    return -1

  result = targetRow * dims.cols + targetCol
  if result >= count:
    if deltaRow != 0:
      result = count - 1
    else:
      return -1
