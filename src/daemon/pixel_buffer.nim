type PixelBuffer* = object
  width*: int32
  height*: int32
  pixels*: seq[uint32]

proc rgbaColorToArgb*(value: uint32): uint32 =
  let r = (value shr 24) and 0xff
  let g = (value shr 16) and 0xff
  let b = (value shr 8) and 0xff
  let a = value and 0xff
  (a shl 24) or (r shl 16) or (g shl 8) or b

proc initPixelBuffer*(width, height: int32, color: uint32): PixelBuffer =
  result.width = max(1'i32, width)
  result.height = max(1'i32, height)
  result.pixels = newSeq[uint32](int(result.width * result.height))
  for i in 0 ..< result.pixels.len:
    result.pixels[i] = color

proc putPixel*(buf: var PixelBuffer, x, y: int32, color: uint32) =
  if x < 0 or y < 0 or x >= buf.width or y >= buf.height:
    return
  buf.pixels[int(y * buf.width + x)] = color

proc fillRect*(buf: var PixelBuffer, x, y, w, h: int32, color: uint32) =
  if w <= 0 or h <= 0:
    return
  for py in y ..< y + h:
    for px in x ..< x + w:
      buf.putPixel(px, py, color)

proc strokeRect*(buf: var PixelBuffer, x, y, w, h, thickness: int32, color: uint32) =
  if w <= 0 or h <= 0 or thickness <= 0:
    return
  let line = min(thickness, max(1'i32, min(w, h)))
  buf.fillRect(x, y, w, line, color)
  buf.fillRect(x, y + h - line, w, line, color)
  buf.fillRect(x, y, line, h, color)
  buf.fillRect(x + w - line, y, line, h, color)

proc argbBytes*(pixels: seq[uint32]): string =
  result = newString(pixels.len * 4)
  var i = 0
  for pixel in pixels:
    result[i] = char(pixel and 0xff'u32)
    result[i + 1] = char((pixel shr 8) and 0xff'u32)
    result[i + 2] = char((pixel shr 16) and 0xff'u32)
    result[i + 3] = char((pixel shr 24) and 0xff'u32)
    i += 4
