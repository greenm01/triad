import ../systems/recent_windows
import ../types/model
import ../types/runtime_values as rv
import overlay_text_render
import pixel_buffer

const
  Backdrop = 0xcc000000'u32
  Transparent = 0x00000000'u32
  TextColor = 0xffffffff'u32
  MutedTextColor = 0xffc8d0dc'u32
  PanelBg = 0xdd111318'u32
  PanelBorder = 0xff62a8ff'u32
  TitleGap = 14'i32
  PanelPadding = 12'i32
  SelectedBorderWidth = 2'i32
  SelectedFillAlpha = 0x55'u32
  TitleStyle = OverlayTextStyle(sizePx: 14.0, color: TextColor)
  MutedTitleStyle = OverlayTextStyle(sizePx: 14.0, color: MutedTextColor)
  PanelStyle = OverlayTextStyle(sizePx: 14.0, color: TextColor)

proc scopeText(model: Model): string =
  case model.recentWindowsScope
  of RecentWindowScope.All: "Scope: All"
  of RecentWindowScope.Workspace: "Scope: Workspace"
  of RecentWindowScope.Output: "Scope: Output"

proc rgbaWithAlpha(value, alpha: uint32): uint32 =
  (value and 0xffffff00'u32) or min(alpha, value and 0xff'u32)

proc fillSelectedChrome(
    buf: var PixelBuffer,
    preview: RecentWindowPreview,
    screen: rv.Rect,
    padding: int32,
    color: uint32,
) =
  if padding <= 0:
    return
  let titleH = TitleStyle.textHeight()
  let x = preview.geom.x - screen.x - padding
  let y = preview.geom.y - screen.y - padding
  let w = preview.geom.w + padding * 2
  let h = preview.geom.h + padding * 2 + TitleGap + titleH
  buf.fillRect(x, y, w, padding, color)
  buf.fillRect(x, y + padding + preview.geom.h, w, h - padding - preview.geom.h, color)
  buf.fillRect(x, y + padding, padding, preview.geom.h, color)
  buf.fillRect(
    x + padding + preview.geom.w, y + padding, padding, preview.geom.h, color
  )

proc renderRecentWindowsBackdropBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Backdrop)

proc renderRecentWindowsChromeBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Transparent)
  if not model.recentWindowsVisible():
    return

  let previews = model.recentWindowPreviews(screen)
  let borderColor = rgbaColorToArgb(model.recentWindows.highlight.activeColor)
  let selectedFillColor = rgbaColorToArgb(
    model.recentWindows.highlight.activeColor.rgbaWithAlpha(SelectedFillAlpha)
  )
  let padding = max(0'i32, model.recentWindows.highlight.padding)
  for preview in previews:
    if preview.selected:
      result.fillSelectedChrome(preview, screen, padding, selectedFillColor)
      result.strokeRect(
        preview.geom.x - screen.x - padding,
        preview.geom.y - screen.y - padding,
        preview.geom.w + padding * 2,
        preview.geom.h + padding * 2 + TitleGap + TitleStyle.textHeight(),
        SelectedBorderWidth,
        borderColor,
      )
    let style = if preview.selected: TitleStyle else: MutedTitleStyle
    let title = preview.title.ellipsizeText(preview.geom.w, style)
    let titleW = title.textWidth(style)
    let titleX = preview.geom.x - screen.x + max(0'i32, (preview.geom.w - titleW) div 2)
    result.drawText(
      titleX,
      preview.geom.y - screen.y + preview.geom.h + TitleGap,
      max(preview.geom.w, 1'i32),
      title,
      style,
    )

  let panel = model.scopeText()
  let panelW = panel.textWidth(PanelStyle) + PanelPadding * 2
  let panelH = PanelStyle.textHeight() + PanelPadding * 2
  let panelX = max(0'i32, (screen.w - panelW) div 2)
  let panelY = PanelPadding * 2
  result.fillRect(panelX, panelY, panelW, panelH, PanelBg)
  result.strokeRect(panelX, panelY, panelW, panelH, 2, PanelBorder)
  result.drawText(
    panelX + PanelPadding,
    panelY + PanelPadding,
    panelW - PanelPadding * 2,
    panel,
    PanelStyle,
  )

proc renderRecentWindowsOverlayBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  model.renderRecentWindowsChromeBuffer(screen)
