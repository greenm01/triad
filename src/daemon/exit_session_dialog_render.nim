from ../types/runtime_values import Rect
import overlay_text_render
import pixel_buffer

export pixel_buffer

const
  DialogBg = 0xee111318'u32
  DialogRing = 0xffff3b30'u32
  DialogText = 0xfff4f7fb'u32
  DialogPaddingX = 42'i32
  DialogPaddingY = 34'i32
  DialogMinWidth = 420'i32
  DialogScreenMargin = 48'i32
  DialogTextStyle = OverlayTextStyle(sizePx: 18.0, color: DialogText)

proc exitSessionDialogPlacement*(screen: Rect, bufferW, bufferH: int32): Rect =
  result.w = bufferW
  result.h = bufferH
  result.x = screen.x + max(0'i32, (screen.w - bufferW) div 2)
  result.y = screen.y + max(0'i32, (screen.h - bufferH) div 2)

proc centeredTextX(text: string, style: OverlayTextStyle, width: int32): int32 =
  max(DialogPaddingX, (width - text.textWidth(style)) div 2)

proc renderExitSessionDialogBuffer*(screen: Rect): PixelBuffer =
  let
    firstLine = "Are you sure you want to exit Triad?"
    thirdLine = "Press ENTER to confirm."
    lineH = max(22'i32, DialogTextStyle.textHeight())
    textW =
      max(firstLine.textWidth(DialogTextStyle), thirdLine.textWidth(DialogTextStyle))
    maxW = max(DialogMinWidth, screen.w - DialogScreenMargin * 2)
    desiredW = max(DialogMinWidth, textW + DialogPaddingX * 2)
    width = min(maxW, desiredW)
    height = DialogPaddingY * 2 + lineH * 3

  result = initPixelBuffer(width, height, DialogBg)
  result.strokeRect(0, 0, width, height, 5, DialogRing)
  result.strokeRect(7, 7, width - 14, height - 14, 2, DialogRing)

  let
    y1 = DialogPaddingY
    y3 = DialogPaddingY + lineH * 2
  result.drawText(
    firstLine.centeredTextX(DialogTextStyle, width),
    y1,
    width - DialogPaddingX * 2,
    firstLine,
    DialogTextStyle,
  )
  result.drawText(
    thirdLine.centeredTextX(DialogTextStyle, width),
    y3,
    width - DialogPaddingX * 2,
    thirdLine,
    DialogTextStyle,
  )
