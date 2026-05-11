import strutils
from ../types/runtime_values import HotkeyOverlayRow, Rect

type
  PixelBuffer* = object
    width*: int32
    height*: int32
    pixels*: seq[uint32]

const
  HotkeyBg = 0xdd111318'u32
  HotkeyBorder = 0xff62a8ff'u32
  HotkeyText = 0xfff4f7fb'u32
  HotkeyMuted = 0xffaab3c2'u32
  HotkeyKeyBg = 0xff262a33'u32
  HotkeyTitle = 0xffffffff'u32
  HotkeyFontScale = 3'i32
  HotkeyPadding = 24'i32
  HotkeyRowGap = 10'i32
  HotkeyColumnGap = 28'i32

proc initPixelBuffer(width, height: int32; color: uint32): PixelBuffer =
  result.width = max(1'i32, width)
  result.height = max(1'i32, height)
  result.pixels = newSeq[uint32](int(result.width * result.height))
  for i in 0 ..< result.pixels.len:
    result.pixels[i] = color

proc putPixel(buf: var PixelBuffer; x, y: int32; color: uint32) =
  if x < 0 or y < 0 or x >= buf.width or y >= buf.height:
    return
  buf.pixels[int(y * buf.width + x)] = color

proc fillRect(
    buf: var PixelBuffer; x, y, w, h: int32; color: uint32) =
  for py in y ..< y + h:
    for px in x ..< x + w:
      buf.putPixel(px, py, color)

proc strokeRect(
    buf: var PixelBuffer; x, y, w, h, thickness: int32; color: uint32) =
  buf.fillRect(x, y, w, thickness, color)
  buf.fillRect(x, y + h - thickness, w, thickness, color)
  buf.fillRect(x, y, thickness, h, color)
  buf.fillRect(x + w - thickness, y, thickness, h, color)

proc glyphRows(ch: char): array[7, string] =
  case ch
  of 'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"]
  of 'B': ["11110", "10001", "10001", "11110", "10001", "10001", "11110"]
  of 'C': ["01111", "10000", "10000", "10000", "10000", "10000", "01111"]
  of 'D': ["11110", "10001", "10001", "10001", "10001", "10001", "11110"]
  of 'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"]
  of 'F': ["11111", "10000", "10000", "11110", "10000", "10000", "10000"]
  of 'G': ["01111", "10000", "10000", "10111", "10001", "10001", "01111"]
  of 'H': ["10001", "10001", "10001", "11111", "10001", "10001", "10001"]
  of 'I': ["11111", "00100", "00100", "00100", "00100", "00100", "11111"]
  of 'J': ["00111", "00010", "00010", "00010", "10010", "10010", "01100"]
  of 'K': ["10001", "10010", "10100", "11000", "10100", "10010", "10001"]
  of 'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"]
  of 'M': ["10001", "11011", "10101", "10101", "10001", "10001", "10001"]
  of 'N': ["10001", "11001", "10101", "10011", "10001", "10001", "10001"]
  of 'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"]
  of 'P': ["11110", "10001", "10001", "11110", "10000", "10000", "10000"]
  of 'Q': ["01110", "10001", "10001", "10001", "10101", "10010", "01101"]
  of 'R': ["11110", "10001", "10001", "11110", "10100", "10010", "10001"]
  of 'S': ["01111", "10000", "10000", "01110", "00001", "00001", "11110"]
  of 'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"]
  of 'U': ["10001", "10001", "10001", "10001", "10001", "10001", "01110"]
  of 'V': ["10001", "10001", "10001", "10001", "10001", "01010", "00100"]
  of 'W': ["10001", "10001", "10001", "10101", "10101", "10101", "01010"]
  of 'X': ["10001", "10001", "01010", "00100", "01010", "10001", "10001"]
  of 'Y': ["10001", "10001", "01010", "00100", "00100", "00100", "00100"]
  of 'Z': ["11111", "00001", "00010", "00100", "01000", "10000", "11111"]
  of '0': ["01110", "10001", "10011", "10101", "11001", "10001", "01110"]
  of '1': ["00100", "01100", "00100", "00100", "00100", "00100", "01110"]
  of '2': ["01110", "10001", "00001", "00010", "00100", "01000", "11111"]
  of '3': ["11110", "00001", "00001", "01110", "00001", "00001", "11110"]
  of '4': ["00010", "00110", "01010", "10010", "11111", "00010", "00010"]
  of '5': ["11111", "10000", "10000", "11110", "00001", "00001", "11110"]
  of '6': ["01110", "10000", "10000", "11110", "10001", "10001", "01110"]
  of '7': ["11111", "00001", "00010", "00100", "01000", "01000", "01000"]
  of '8': ["01110", "10001", "10001", "01110", "10001", "10001", "01110"]
  of '9': ["01110", "10001", "10001", "01111", "00001", "00001", "01110"]
  of '+': ["00000", "00100", "00100", "11111", "00100", "00100", "00000"]
  of '-': ["00000", "00000", "00000", "11111", "00000", "00000", "00000"]
  of '/': ["00001", "00001", "00010", "00100", "01000", "10000", "10000"]
  of '?': ["01110", "10001", "00001", "00010", "00100", "00000", "00100"]
  of ':': ["00000", "00100", "00100", "00000", "00100", "00100", "00000"]
  of '.': ["00000", "00000", "00000", "00000", "00000", "01100", "01100"]
  of ',': ["00000", "00000", "00000", "00000", "00100", "00100", "01000"]
  of '_': ["00000", "00000", "00000", "00000", "00000", "00000", "11111"]
  of ' ': ["00000", "00000", "00000", "00000", "00000", "00000", "00000"]
  else: ["01110", "10001", "00001", "00010", "00100", "00000", "00100"]

proc drawChar(
    buf: var PixelBuffer; x, y: int32; ch: char; color: uint32;
    scale = HotkeyFontScale) =
  let glyph = glyphRows(ch.toUpperAscii())
  for gy, row in glyph:
    for gx, bit in row:
      if bit == '1':
        buf.fillRect(x + int32(gx) * scale, y + int32(gy) * scale,
          scale, scale, color)

proc drawText(
    buf: var PixelBuffer; x, y, maxW: int32; text: string; color: uint32;
    scale = HotkeyFontScale) =
  var dx = x
  let advance = 6'i32 * scale
  for ch in text:
    if dx + 5'i32 * scale > x + maxW:
      return
    buf.drawChar(dx, y, ch, color, scale)
    dx += advance

proc textWidth*(text: string; scale = HotkeyFontScale): int32 =
  int32(text.len) * 6'i32 * scale

proc argbBytes*(pixels: seq[uint32]): string =
  result = newString(pixels.len * 4)
  var i = 0
  for pixel in pixels:
    result[i] = char(pixel and 0xff'u32)
    result[i + 1] = char((pixel shr 8) and 0xff'u32)
    result[i + 2] = char((pixel shr 16) and 0xff'u32)
    result[i + 3] = char((pixel shr 24) and 0xff'u32)
    i += 4

proc renderHotkeyOverlayBuffer*(
    rows: seq[HotkeyOverlayRow]; screen: Rect): PixelBuffer =
  let title = "Important Hotkeys"
  let rowH = 7'i32 * HotkeyFontScale
  var keyW = textWidth("(not bound)")
  var labelW = 0'i32
  for row in rows:
    keyW = max(keyW, textWidth(row.key))
    labelW = max(labelW, textWidth(row.label))
  let maxW = max(360'i32, int32(float(screen.w) * 0.9))
  let desiredW = HotkeyPadding * 2 + keyW + HotkeyColumnGap + labelW
  let width = min(maxW, max(360'i32, desiredW))
  let visibleRows =
    if rows.len == 0: 1
    else: min(rows.len, max(1, int((max(240'i32, screen.h - 120'i32) -
      HotkeyPadding * 3 - rowH) div (rowH + HotkeyRowGap))))
  let height = HotkeyPadding * 3 + rowH +
    int32(visibleRows) * rowH + int32(max(0, visibleRows - 1)) * HotkeyRowGap
  result = initPixelBuffer(width, height, HotkeyBg)
  result.strokeRect(0, 0, width, height, 4, HotkeyBorder)
  result.drawText((width - textWidth(title)) div 2, HotkeyPadding,
    width - HotkeyPadding * 2, title, HotkeyTitle)
  var y = HotkeyPadding * 2 + rowH
  let labelX = HotkeyPadding + keyW + HotkeyColumnGap
  let rowsToDraw =
    if rows.len == 0:
      @[HotkeyOverlayRow(key: "", label: "No hotkeys configured")]
    else:
      rows[0 ..< visibleRows]
  for row in rowsToDraw:
    result.fillRect(HotkeyPadding - 8, y - 5, keyW + 16,
      rowH + 10, HotkeyKeyBg)
    result.drawText(HotkeyPadding, y, keyW, row.key, HotkeyText)
    result.drawText(labelX, y, width - labelX - HotkeyPadding,
      row.label, HotkeyMuted)
    y += rowH + HotkeyRowGap
