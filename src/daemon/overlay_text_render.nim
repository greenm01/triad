import std/[math, os, osproc, strutils, tables]
import pixie
import overlay_bitmap_text_render
import pixel_buffer

type
  OverlayTextStyle* = object
    sizePx*: float32
    color*: uint32

  OverlayTextMetrics* = object
    width*: int32
    height*: int32

const FallbackFonts = [
  "/usr/share/fonts/noto/NotoSans-Regular.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf",
  "/usr/share/fonts/dejavu/DejaVuSans.ttf",
  "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
  "/usr/share/fonts/liberation2/LiberationSans-Regular.ttf",
]

var
  fontDiscoveryDone = false
  cachedTypefacePath = ""
  cachedTypeface: Typeface
  cachedFonts: Table[(string, int32, uint32), Font]

proc normalizedSize(style: OverlayTextStyle): int32 =
  max(1'i32, int32(round(style.sizePx)))

proc fcMatchSansPath(): string =
  if findExe("fc-match").len == 0:
    return ""
  try:
    execProcess("fc-match -f '%{file}\\n' sans").strip()
  except OSError:
    ""

proc defaultTypefacePath(): string =
  let matched = fcMatchSansPath()
  if matched.len > 0 and fileExists(matched):
    return matched
  for path in FallbackFonts:
    if fileExists(path):
      return path
  ""

proc overlayTypeface(): Typeface =
  if fontDiscoveryDone:
    return cachedTypeface
  fontDiscoveryDone = true
  cachedTypefacePath = defaultTypefacePath()
  if cachedTypefacePath.len == 0:
    return nil
  try:
    cachedTypeface = readTypeface(cachedTypefacePath)
  except PixieError:
    cachedTypeface = nil
  cachedTypeface

proc argbToPixieColor(colorValue: uint32): Color =
  let
    a = float32((colorValue shr 24) and 0xff) / 255.0'f32
    r = float32((colorValue shr 16) and 0xff) / 255.0'f32
    g = float32((colorValue shr 8) and 0xff) / 255.0'f32
    b = float32(colorValue and 0xff) / 255.0'f32
  color(r, g, b, a)

proc overlayFont(style: OverlayTextStyle): Font =
  let typeface = overlayTypeface()
  if typeface == nil:
    return nil
  let key = (cachedTypefacePath, style.normalizedSize(), style.color)
  if cachedFonts.hasKey(key):
    return cachedFonts[key]
  result = newFont(typeface)
  result.size = float32(style.normalizedSize())
  result.paint = newPaint(SolidPaint)
  result.paint.color = argbToPixieColor(style.color)
  cachedFonts[key] = result

proc textMetrics*(text: string, style: OverlayTextStyle): OverlayTextMetrics =
  let font = overlayFont(style)
  if font == nil:
    return OverlayTextMetrics(width: bitmapTextWidth(text), height: bitmapTextHeight())
  let bounds = font.layoutBounds(text)
  OverlayTextMetrics(
    width: max(1'i32, int32(ceil(bounds.x))), height: max(1'i32, int32(ceil(bounds.y)))
  )

proc textWidth*(text: string, style: OverlayTextStyle): int32 =
  text.textMetrics(style).width

proc textHeight*(style: OverlayTextStyle): int32 =
  "Mg".textMetrics(style).height

proc overlayTextAvailable*(): bool =
  overlayTypeface() != nil

proc blendPremulSourceOverArgb(dst, srcR, srcG, srcB, srcA: uint32): uint32 =
  if srcA == 0:
    return dst
  if srcA == 255:
    return (0xff'u32 shl 24) or (srcR shl 16) or (srcG shl 8) or srcB

  let
    dstA = (dst shr 24) and 0xff
    dstR = (dst shr 16) and 0xff
    dstG = (dst shr 8) and 0xff
    dstB = dst and 0xff
    invA = 255'u32 - srcA
    dstPremulR = (dstR * dstA + 127'u32) div 255'u32
    dstPremulG = (dstG * dstA + 127'u32) div 255'u32
    dstPremulB = (dstB * dstA + 127'u32) div 255'u32
    outA = srcA + (dstA * invA + 127'u32) div 255'u32
    outPremulR = srcR + (dstPremulR * invA + 127'u32) div 255'u32
    outPremulG = srcG + (dstPremulG * invA + 127'u32) div 255'u32
    outPremulB = srcB + (dstPremulB * invA + 127'u32) div 255'u32

  (outA shl 24) or (outPremulR shl 16) or (outPremulG shl 8) or outPremulB

proc blitTextImage(buf: var PixelBuffer, x, y: int32, image: Image) =
  for py in 0 ..< image.height:
    let dstY = y + int32(py)
    if dstY < 0 or dstY >= buf.height:
      continue
    for px in 0 ..< image.width:
      let dstX = x + int32(px)
      if dstX < 0 or dstX >= buf.width:
        continue
      let src = image[px, py]
      if src.a == 0:
        continue
      buf.putPixel(
        dstX,
        dstY,
        blendPremulSourceOverArgb(
          buf.pixelAt(dstX, dstY),
          uint32(src.r),
          uint32(src.g),
          uint32(src.b),
          uint32(src.a),
        ),
      )

proc drawText*(
    buf: var PixelBuffer, x, y, maxW: int32, text: string, style: OverlayTextStyle
) =
  if text.len == 0 or maxW <= 0:
    return
  let font = overlayFont(style)
  if font == nil:
    buf.drawBitmapText(x, y, maxW, text, style.color)
    return

  let metrics = text.textMetrics(style)
  let imageW = max(1'i32, min(maxW, metrics.width + 2'i32))
  let imageH = max(1'i32, metrics.height + 2'i32)
  try:
    let image = newImage(int(imageW), int(imageH))
    let arrangement =
      font.typeset(text, bounds = vec2(float32(imageW), float32(imageH)), wrap = false)
    image.fillText(arrangement)
    buf.blitTextImage(x, y, image)
  except PixieError:
    buf.drawBitmapText(x, y, maxW, text, style.color)

proc ellipsizeText*(text: string, maxW: int32, style: OverlayTextStyle): string =
  result = text.strip()
  if maxW <= 0 or result.len == 0 or result.textWidth(style) <= maxW:
    return

  const Ellipsis = "..."
  while result.len > 0 and (result & Ellipsis).textWidth(style) > maxW:
    result.setLen(result.len - 1)
  if result.len == 0:
    return ""
  result = result & Ellipsis
