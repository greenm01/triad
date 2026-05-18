import std/strutils
import ../types/projection_values
import overlay_text_render
import pixel_buffer

export pixel_buffer

const
  Transparent = 0x00000000'u32
  ActiveFocused = 0xff3f7fd5'u32
  ActiveUnfocused = 0xff303846'u32
  Inactive = 0xee161a22'u32
  Separator = 0xff0b0d12'u32
  TextActive = 0xffffffff'u32
  TextInactive = 0xffaab3c2'u32
  UnderlineFocused = 0xffffffff'u32
  UnderlineUnfocused = 0xff62a8ff'u32
  TabPaddingX = 7'i32
  TabGap = 1'i32
  UnderlineHeight = 2'i32
  TabTextStyleActive = OverlayTextStyle(sizePx: 12.0, color: TextActive)
  TabTextStyleInactive = OverlayTextStyle(sizePx: 12.0, color: TextInactive)

proc frameTabLabel(tab: ProjectedFrameTab): string =
  result = tab.title.strip()
  if result.len == 0:
    result = tab.appId.strip()
  if result.len == 0:
    result = "Window"

proc frameTabIndexAt*(bar: ProjectedFrameTabBar, x: int32): int =
  if bar.tabs.len == 0 or bar.geom.w <= 0 or x < 0:
    return -1
  let tabW = max(1'i32, bar.geom.w div int32(bar.tabs.len))
  min(bar.tabs.len - 1, int(x div tabW))

proc frameTabBarCacheKey*(bar: ProjectedFrameTabBar): string =
  result =
    $bar.frameId & ":" & $bar.windowId & ":" & $bar.geom.w & ":" & $bar.geom.h & ":" &
    $bar.focused
  for tab in bar.tabs:
    result.add("|")
    result.add($tab.windowId)
    result.add(":")
    result.add($tab.active)
    result.add(":")
    result.add(tab.frameTabLabel())

proc renderFrameTabBarBuffer*(bar: ProjectedFrameTabBar): PixelBuffer =
  let
    width = max(1'i32, bar.geom.w)
    height = max(1'i32, bar.geom.h)
    count = max(1, bar.tabs.len)
    tabW = max(1'i32, width div int32(count))
  result = initPixelBuffer(width, height, Transparent)
  if bar.tabs.len == 0:
    return

  for idx, tab in bar.tabs:
    let
      x = int32(idx) * tabW
      nextX =
        if idx == bar.tabs.high:
          width
        else:
          min(width, x + tabW)
      w = max(1'i32, nextX - x)
      fill =
        if tab.active and bar.focused:
          ActiveFocused
        elif tab.active:
          ActiveUnfocused
        else:
          Inactive
      textStyle = if tab.active: TabTextStyleActive else: TabTextStyleInactive
      label =
        tab.frameTabLabel().ellipsizeText(max(1'i32, w - TabPaddingX * 2), textStyle)
      textY = max(1'i32, (height - textStyle.textHeight()) div 2)

    result.fillRect(x, 0, w, height, fill)
    if idx > 0:
      result.fillRect(x, 0, TabGap, height, Separator)
    if tab.active:
      result.fillRect(
        x,
        max(0'i32, height - UnderlineHeight),
        w,
        UnderlineHeight,
        if bar.focused: UnderlineFocused else: UnderlineUnfocused,
      )
    result.drawText(
      x + TabPaddingX, textY, max(1'i32, w - TabPaddingX * 2), label, textStyle
    )
