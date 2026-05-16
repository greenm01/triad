from ../core/layout_mode_codec import layoutModeId
from ../types/core import Rect
from ../types/runtime_values import LayoutMode
import overlay_text_render
import pixel_buffer

export pixel_buffer

const
  ToastBg = 0xee111318'u32
  ToastText = 0xfff4f7fb'u32
  ToastPaddingX = 34'i32
  ToastPaddingY = 24'i32
  ToastMinWidth = 260'i32
  ToastScreenMargin = 48'i32
  ToastTextStyle = OverlayTextStyle(sizePx: 18.0, color: ToastText)

proc layoutSwitchToastPlacement*(screen: Rect, bufferW, bufferH: int32): Rect =
  result.w = bufferW
  result.h = bufferH
  result.x = screen.x + max(0'i32, (screen.w - bufferW) div 2)
  result.y = screen.y + max(0'i32, (screen.h - bufferH) div 2)

proc renderLayoutSwitchToastBuffer*(
    screen: Rect, layout: LayoutMode, ringWidth: int32, ringColor: uint32
): PixelBuffer =
  let
    line = "Layout: " & layout.layoutModeId()
    lineH = max(22'i32, ToastTextStyle.textHeight())
    maxW = max(ToastMinWidth, screen.w - ToastScreenMargin * 2)
    desiredW = max(ToastMinWidth, line.textWidth(ToastTextStyle) + ToastPaddingX * 2)
    width = min(maxW, desiredW)
    height = ToastPaddingY * 2 + lineH
    borderWidth = max(1'i32, min(max(0'i32, ringWidth), 64'i32))
    borderColor = rgbaColorToArgb(ringColor)

  result = initPixelBuffer(width, height, ToastBg)
  result.strokeRect(0, 0, width, height, borderWidth, borderColor)
  result.drawText(
    max(ToastPaddingX, (width - line.textWidth(ToastTextStyle)) div 2),
    ToastPaddingY,
    width - ToastPaddingX * 2,
    line,
    ToastTextStyle,
  )
