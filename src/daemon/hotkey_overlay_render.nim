from ../types/runtime_values import HotkeyOverlayRow, Rect
import overlay_text_render
import pixel_buffer

export pixel_buffer

const
  HotkeyBg = 0xdd111318'u32
  HotkeyBorder = 0xff62a8ff'u32
  HotkeyText = 0xfff4f7fb'u32
  HotkeyMuted = 0xffaab3c2'u32
  HotkeyKeyBg = 0xff262a33'u32
  HotkeyTitle = 0xffffffff'u32
  HotkeyPadding = 24'i32
  HotkeyRowGap = 10'i32
  HotkeyColumnGap = 28'i32
  HotkeyBodyStyle = OverlayTextStyle(sizePx: 14.0, color: HotkeyText)
  HotkeyMutedStyle = OverlayTextStyle(sizePx: 14.0, color: HotkeyMuted)
  HotkeyTitleStyle = OverlayTextStyle(sizePx: 16.0, color: HotkeyTitle)

proc renderHotkeyOverlayBuffer*(
    rows: seq[HotkeyOverlayRow], screen: Rect
): PixelBuffer =
  let
    title = "Important Hotkeys"
    titleMetrics = title.textMetrics(HotkeyTitleStyle)
    rowH = max(18'i32, HotkeyBodyStyle.textHeight())
  var
    keyW = "(not bound)".textWidth(HotkeyBodyStyle)
    labelW = 0'i32
  for row in rows:
    keyW = max(keyW, row.key.textWidth(HotkeyBodyStyle))
    labelW = max(labelW, row.label.textWidth(HotkeyMutedStyle))

  let
    maxW = max(360'i32, int32(float(screen.w) * 0.9))
    desiredW = HotkeyPadding * 2 + keyW + HotkeyColumnGap + labelW
    width = min(maxW, max(360'i32, desiredW))
    availableH = max(240'i32, screen.h - 120'i32)
    visibleRows =
      if rows.len == 0:
        1
      else:
        min(
          rows.len,
          max(
            1,
            int(
              (availableH - HotkeyPadding * 3 - titleMetrics.height) div
                (rowH + HotkeyRowGap)
            ),
          ),
        )
    height =
      HotkeyPadding * 3 + titleMetrics.height + int32(visibleRows) * rowH +
      int32(max(0, visibleRows - 1)) * HotkeyRowGap

  result = initPixelBuffer(width, height, HotkeyBg)
  result.strokeRect(0, 0, width, height, 4, HotkeyBorder)
  result.drawText(
    max(HotkeyPadding, (width - titleMetrics.width) div 2),
    HotkeyPadding,
    width - HotkeyPadding * 2,
    title,
    HotkeyTitleStyle,
  )

  var y = HotkeyPadding * 2 + titleMetrics.height
  let
    labelX = HotkeyPadding + keyW + HotkeyColumnGap
    rowsToDraw =
      if rows.len == 0:
        @[HotkeyOverlayRow(key: "", label: "No hotkeys configured")]
      else:
        rows[0 ..< visibleRows]
  for row in rowsToDraw:
    result.fillRect(HotkeyPadding - 8, y - 5, keyW + 16, rowH + 10, HotkeyKeyBg)
    result.drawText(HotkeyPadding, y, keyW, row.key, HotkeyBodyStyle)
    result.drawText(
      labelX, y, width - labelX - HotkeyPadding, row.label, HotkeyMutedStyle
    )
    y += rowH + HotkeyRowGap
