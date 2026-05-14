import std/strutils
import ../systems/recent_windows
import ../types/model
import ../types/runtime_values as rv
import hotkey_overlay_render
import pixel_buffer

const
  Backdrop = 0xcc000000'u32
  TextColor = 0xffffffff'u32
  MutedTextColor = 0xffc8d0dc'u32
  PanelBg = 0xdd111318'u32
  PanelBorder = 0xff62a8ff'u32
  TextScale = 2'i32
  TitleGap = 14'i32
  PanelPadding = 12'i32

proc clippedTitle(title: string): string =
  let clean = title.strip()
  if clean.len <= 42:
    return clean
  clean[0 ..< 39] & "..."

proc scopeText(model: Model): string =
  case model.recentWindowsScope
  of RecentWindowScope.All: "Scope: All"
  of RecentWindowScope.Workspace: "Scope: Workspace"
  of RecentWindowScope.Output: "Scope: Output"

proc renderRecentWindowsOverlayBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Backdrop)
  if not model.recentWindowsVisible():
    return

  let previews = model.recentWindowPreviews(screen)
  let borderColor = model.recentWindows.highlight.activeColor
  let padding = model.recentWindows.highlight.padding
  for preview in previews:
    if preview.selected:
      result.strokeRect(
        preview.geom.x - screen.x - padding,
        preview.geom.y - screen.y - padding,
        preview.geom.w + padding * 2,
        preview.geom.h + padding * 2,
        3,
        borderColor,
      )
    let title = preview.title.clippedTitle()
    let titleW = textWidth(title, TextScale)
    let titleX = preview.geom.x - screen.x + max(0'i32, (preview.geom.w - titleW) div 2)
    result.drawText(
      titleX,
      preview.geom.y - screen.y + preview.geom.h + TitleGap,
      max(preview.geom.w, 1'i32),
      title,
      if preview.selected: TextColor else: MutedTextColor,
      TextScale,
    )

  let panel = model.scopeText()
  let panelW = textWidth(panel, TextScale) + PanelPadding * 2
  let panelH = 7'i32 * TextScale + PanelPadding * 2
  let panelX = max(0'i32, (screen.w - panelW) div 2)
  let panelY = screen.h - panelH - 32'i32
  result.fillRect(panelX, panelY, panelW, panelH, PanelBg)
  result.strokeRect(panelX, panelY, panelW, panelH, 2, PanelBorder)
  result.drawText(
    panelX + PanelPadding,
    panelY + PanelPadding,
    panelW - PanelPadding * 2,
    panel,
    TextColor,
    TextScale,
  )
