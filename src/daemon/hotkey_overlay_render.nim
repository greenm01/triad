from ../types/core import Rect
from ../types/runtime_values import HotkeyOverlayPosition, HotkeyOverlayRow
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
  HotkeyInterColumnGap = 32'i32
  HotkeyScreenMargin = 48'i32
  HotkeyBodyStyle = OverlayTextStyle(sizePx: 14.0, color: HotkeyText)
  HotkeyMutedStyle = OverlayTextStyle(sizePx: 14.0, color: HotkeyMuted)
  HotkeyTitleStyle = OverlayTextStyle(sizePx: 16.0, color: HotkeyTitle)

proc hotkeyOverlayPlacement*(
    screen: Rect, bufferW, bufferH: int32, position: HotkeyOverlayPosition
): Rect =
  result.w = bufferW
  result.h = bufferH
  result.x = screen.x + max(0'i32, (screen.w - bufferW) div 2)
  result.y =
    case position
    of HotkeyOverlayPosition.Top:
      screen.y + min(HotkeyScreenMargin, max(0'i32, screen.h - bufferH))
    of HotkeyOverlayPosition.Center:
      screen.y + max(0'i32, (screen.h - bufferH) div 2)
    of HotkeyOverlayPosition.Bottom:
      screen.y + max(0'i32, screen.h - bufferH - HotkeyScreenMargin)

proc rowCapacity(screen: Rect, titleHeight, rowH: int32): int =
  let availableH = max(240'i32, screen.h - 120'i32)
  max(1, int((availableH - HotkeyPadding * 3 - titleHeight) div (rowH + HotkeyRowGap)))

proc columnCount(rowCount, rowsPerColumn, requestedColumns: int): int =
  if rowCount <= 0:
    return 1
  max(1, min(requestedColumns, (rowCount + rowsPerColumn - 1) div rowsPerColumn))

proc renderHotkeyOverlayBuffer*(
    rows: seq[HotkeyOverlayRow], screen: Rect, columns: int32
): PixelBuffer =
  let
    title = "Important Hotkeys"
    titleMetrics = title.textMetrics(HotkeyTitleStyle)
    rowH = max(18'i32, HotkeyBodyStyle.textHeight())
    requestedColumns = max(1, min(4, int(columns)))
    rowsPerColumn = rowCapacity(screen, titleMetrics.height, rowH)
    sourceRows =
      if rows.len == 0:
        @[HotkeyOverlayRow(key: "", label: "No hotkeys configured")]
      else:
        rows[0 ..< min(rows.len, rowsPerColumn * requestedColumns)]
    actualColumns = columnCount(sourceRows.len, rowsPerColumn, requestedColumns)
    tallestColumnRows = min(rowsPerColumn, sourceRows.len)
  var
    keyW = "(not bound)".textWidth(HotkeyBodyStyle)
    labelW = 0'i32
  for row in sourceRows:
    keyW = max(keyW, row.key.textWidth(HotkeyBodyStyle))
    labelW = max(labelW, row.label.textWidth(HotkeyMutedStyle))

  let
    maxW = max(360'i32, int32(float(screen.w) * 0.9))
    columnW = keyW + HotkeyColumnGap + labelW
    desiredW =
      HotkeyPadding * 2 + int32(actualColumns) * columnW +
      int32(max(0, actualColumns - 1)) * HotkeyInterColumnGap
    width = min(maxW, max(360'i32, desiredW))
    height =
      HotkeyPadding * 3 + titleMetrics.height + int32(tallestColumnRows) * rowH +
      int32(max(0, tallestColumnRows - 1)) * HotkeyRowGap

  result = initPixelBuffer(width, height, HotkeyBg)
  result.strokeRect(0, 0, width, height, 4, HotkeyBorder)
  result.drawText(
    max(HotkeyPadding, (width - titleMetrics.width) div 2),
    HotkeyPadding,
    width - HotkeyPadding * 2,
    title,
    HotkeyTitleStyle,
  )

  let startY = HotkeyPadding * 2 + titleMetrics.height
  for idx, row in sourceRows:
    let
      column = idx div rowsPerColumn
      rowIdx = idx mod rowsPerColumn
      x = HotkeyPadding + int32(column) * (columnW + HotkeyInterColumnGap)
      y = startY + int32(rowIdx) * (rowH + HotkeyRowGap)
      labelX = x + keyW + HotkeyColumnGap
    result.fillRect(x - 8, y - 5, keyW + 16, rowH + 10, HotkeyKeyBg)
    result.drawText(x, y, keyW, row.key, HotkeyBodyStyle)
    result.drawText(
      labelX, y, width - labelX - HotkeyPadding, row.label, HotkeyMutedStyle
    )
