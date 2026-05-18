import std/strutils
import ../core/defaults
import ../types/projection_values
import overlay_text_render
import pixel_buffer

export pixel_buffer

const
  Transparent = 0x00000000'u32
  Separator = 0xff0b0d12'u32
  TextActive = 0xffffffff'u32
  TextInactive = 0xffaab3c2'u32
  TabPaddingX = 7'i32
  TabGap = 1'i32
  UnderlineHeight = 2'i32
  TabTextStyleActive = OverlayTextStyle(sizePx: 12.0, color: TextActive)
  TabTextStyleInactive = OverlayTextStyle(sizePx: 12.0, color: TextInactive)

proc frameTabArgb(value, fallback: uint32): uint32 =
  rgbaColorToArgb(if value != 0: value else: fallback)

proc drawFrameTabRing(buf: var PixelBuffer, thickness: int32, color: uint32) =
  if thickness <= 0 or color == 0:
    return
  let line = min(thickness, max(1'i32, min(buf.width, buf.height)))
  buf.fillRect(0, 0, buf.width, line, color)
  buf.fillRect(0, 0, line, buf.height, color)
  buf.fillRect(buf.width - line, 0, line, buf.height, color)

proc drawFrameRectRing(buf: var PixelBuffer, thickness: int32, color: uint32) =
  if thickness <= 0 or color == 0:
    return
  let line = min(thickness, max(1'i32, min(buf.width, buf.height)))
  buf.fillRect(0, 0, buf.width, line, color)
  buf.fillRect(0, buf.height - line, buf.width, line, color)
  buf.fillRect(0, 0, line, buf.height, color)
  buf.fillRect(buf.width - line, 0, line, buf.height, color)

proc frameTabLabel(tab: ProjectedFrameTab): string =
  result = tab.title.strip()
  if result.len == 0:
    result = tab.appId.strip()
  if result.len == 0:
    result = "Window"

proc frameTabIndexAt*(bar: ProjectedFrameTabBar, x: int32): int =
  let
    ringInset = max(0'i32, bar.ringWidth)
    contentW = max(1'i32, bar.geom.w - ringInset * 2)
    contentX = x - ringInset
  if bar.tabs.len == 0 or bar.geom.w <= 0 or contentX < 0 or contentX >= contentW:
    return -1
  let tabW = max(1'i32, contentW div int32(bar.tabs.len))
  min(bar.tabs.len - 1, int(contentX div tabW))

proc frameTabBarCacheKey*(bar: ProjectedFrameTabBar): string =
  result =
    "tab-v2:" & $bar.frameId & ":" & $bar.windowId & ":" & $bar.geom.w & ":" &
    $bar.geom.h & ":" & $bar.focused
  for tab in bar.tabs:
    result.add("|")
    result.add($tab.windowId)
    result.add(":")
    result.add($tab.active)
    result.add(":")
    result.add(tab.frameTabLabel())
  result.add(
    ":" & $bar.frameTabs.activeColor & ":" & $bar.frameTabs.activeUnfocusedColor & ":" &
      $bar.frameTabs.inactiveColor & ":" & $bar.frameTabs.activeLineColor & ":" &
      $bar.frameTabs.activeUnfocusedLineColor & ":" & $bar.ringWidth & ":" &
      $bar.ringColor
  )

proc renderFrameTabBarBuffer*(bar: ProjectedFrameTabBar): PixelBuffer =
  let
    ringInset = max(0'i32, bar.ringWidth)
    width = max(1'i32, bar.geom.w)
    contentW = max(1'i32, width - ringInset * 2)
    tabH = max(1'i32, bar.geom.h)
    height = max(1'i32, tabH + ringInset)
    count = max(1, bar.tabs.len)
    tabW = max(1'i32, contentW div int32(count))
    activeFocused = bar.frameTabs.activeColor.frameTabArgb(DefaultFrameTabActiveColor)
    activeUnfocused = bar.frameTabs.activeUnfocusedColor.frameTabArgb(
      DefaultFrameTabActiveUnfocusedColor
    )
    inactive = bar.frameTabs.inactiveColor.frameTabArgb(DefaultFrameTabInactiveColor)
    underlineFocused =
      bar.frameTabs.activeLineColor.frameTabArgb(DefaultFrameTabActiveLineColor)
    underlineUnfocused = bar.frameTabs.activeUnfocusedLineColor.frameTabArgb(
      DefaultFrameTabActiveUnfocusedLineColor
    )
  result = initPixelBuffer(width, height, Transparent)
  if bar.tabs.len == 0:
    return

  for idx, tab in bar.tabs:
    let
      x = int32(idx) * tabW
      contentX = ringInset + x
      nextX =
        if idx == bar.tabs.high:
          ringInset + contentW
        else:
          min(ringInset + contentW, contentX + tabW)
      w = max(1'i32, nextX - contentX)
      fill =
        if tab.active and bar.focused:
          activeFocused
        elif tab.active:
          activeUnfocused
        else:
          inactive
      textStyle = if tab.active: TabTextStyleActive else: TabTextStyleInactive
      label =
        tab.frameTabLabel().ellipsizeText(max(1'i32, w - TabPaddingX * 2), textStyle)
      textY = ringInset + max(1'i32, (tabH - textStyle.textHeight()) div 2)

    result.fillRect(contentX, ringInset, w, tabH, fill)
    if idx > 0:
      result.fillRect(contentX, ringInset, TabGap, tabH, Separator)
    if tab.active:
      result.fillRect(
        contentX,
        ringInset + max(0'i32, tabH - UnderlineHeight),
        w,
        UnderlineHeight,
        if bar.focused: underlineFocused else: underlineUnfocused,
      )
    result.drawText(
      contentX + TabPaddingX, textY, max(1'i32, w - TabPaddingX * 2), label, textStyle
    )
  result.drawFrameTabRing(bar.ringWidth, rgbaColorToArgb(bar.ringColor))

proc frameEmptyChromeCacheKey*(frame: ProjectedFrameEmptyChrome): string =
  result =
    "empty-v2:" & $frame.frameId & ":" & $frame.geom.w & ":" & $frame.geom.h & ":" &
    $frame.focused & ":" & $frame.ringWidth & ":" & $frame.ringColor
  result.add(":" & $frame.backgroundColor)

proc renderFrameEmptyChromeBuffer*(frame: ProjectedFrameEmptyChrome): PixelBuffer =
  result = initPixelBuffer(
    max(1'i32, frame.geom.w),
    max(1'i32, frame.geom.h),
    frame.backgroundColor.frameTabArgb(DefaultFrameEmptyBackgroundColor),
  )
  result.drawFrameRectRing(frame.ringWidth, rgbaColorToArgb(frame.ringColor))
