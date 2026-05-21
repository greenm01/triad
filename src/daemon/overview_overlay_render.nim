import ../state/engine
import ../systems/overview_geometry
import ../types/model
import ../types/projection_values as rv
import overlay_text_render
import pixel_buffer

const
  Transparent = 0x00000000'u32
  EmptyWorkspaceFill = 0xcc000000'u32
  HiddenBadgeFill = 0xdd000000'u32
  HiddenBadgeText = 0xffffffff'u32
  ScrollIndicatorColor = 0x55ffffff'u32
  ScrollIndicatorThickness = 2'i32

proc overviewOverlayCacheKeyForOutput*(
  model: Model, outputId: OutputId, screen: rv.Rect
): string

proc drawOverviewOverlayBufferForOutput*(
  model: Model, outputId: OutputId, screen: rv.Rect, buf: var PixelBuffer
)

proc emptyWorkspaceFrameThickness*(model: Model): int32 =
  max(2'i32, min(max(0'i32, model.borderWidth), 8'i32))

proc overviewWorkspaceSlotEmpty(model: Model, slot: uint32): bool =
  let tagId = model.tagForSlot(slot)
  tagId == NullTagId or not model.tagHasLiveWindows(tagId)

proc overviewOverlayCacheKey*(model: Model, screen: rv.Rect): string =
  model.overviewOverlayCacheKeyForOutput(model.activeOutput, screen)

proc overviewOverlayCacheKeyForOutput*(
    model: Model, outputId: OutputId, screen: rv.Rect
): string =
  result =
    $screen.x & ":" & $screen.y & ":" & $screen.w & ":" & $screen.h & ":" &
    $uint32(outputId) & ":" & $model.activeWorkspaceSlotForOutput(outputId) & ":" &
    $model.effectiveOverviewZoom() & ":" & $model.overviewScrollerIndicators & ":" &
    $model.borderWidth & ":" & $model.focusedBorderColor & ":" &
    $model.unfocusedBorderColor
  for slot in model.previewSlotsForOutput(outputId):
    result.add(":")
    result.add($slot)
    result.add(if model.overviewWorkspaceSlotEmpty(slot): "e" else: "o")
  let slots = model.previewSlotsForOutput(outputId)
  for idx, slot in slots:
    let badge = model.overviewHiddenCountBadgeForOutput(outputId, screen, slots, idx)
    let indicator = model.overviewScrollIndicatorForOutput(outputId, screen, slots, idx)
    result.add(":b")
    result.add($slot)
    result.add("=")
    result.add($badge.count)
    result.add("@")
    result.add($badge.rect.x)
    result.add(",")
    result.add($badge.rect.y)
    result.add(",")
    result.add($badge.rect.w)
    result.add(",")
    result.add($badge.rect.h)
    result.add(":s")
    result.add($slot)
    result.add("=")
    result.add($indicator.axis)
    result.add(",")
    result.add($indicator.before)
    result.add(",")
    result.add($indicator.after)

proc drawHiddenCountBadge(
    buf: var PixelBuffer, screen: rv.Rect, badge: OverviewHiddenCountBadge
) =
  if badge.count <= 0 or badge.rect.w <= 0 or badge.rect.h <= 0:
    return

  let text = $badge.count
  let size = float32(max(10'i32, min(18'i32, badge.rect.h div 7)))
  let style = OverlayTextStyle(sizePx: size, color: HiddenBadgeText)
  let metrics = text.textMetrics(style)
  let padX = max(4'i32, int32(size) div 3)
  let padY = max(2'i32, int32(size) div 6)
  let badgeW = max(18'i32, metrics.width + 2 * padX)
  let badgeH = max(18'i32, metrics.height + 2 * padY)
  let margin = max(4'i32, int32(size) div 3)
  let x = badge.rect.x + badge.rect.w - badgeW - margin
  let y = badge.rect.y + margin

  buf.fillRect(x - screen.x, y - screen.y, badgeW, badgeH, HiddenBadgeFill)
  buf.drawText(
    x - screen.x + padX,
    y - screen.y + max(0'i32, (badgeH - metrics.height) div 2),
    badgeW - 2 * padX,
    text,
    style,
  )

proc drawScrollIndicator(
    buf: var PixelBuffer, screen: rv.Rect, indicator: OverviewScrollIndicator
) =
  if not indicator.before and not indicator.after:
    return
  if indicator.rect.w <= 0 or indicator.rect.h <= 0:
    return

  let thickness =
    min(ScrollIndicatorThickness, max(1'i32, min(indicator.rect.w, indicator.rect.h)))
  case indicator.axis
  of OverviewScrollAxis.Horizontal:
    if indicator.before:
      buf.fillRect(
        indicator.rect.x - screen.x,
        indicator.rect.y - screen.y,
        thickness,
        indicator.rect.h,
        ScrollIndicatorColor,
      )
    if indicator.after:
      buf.fillRect(
        indicator.rect.x + indicator.rect.w - thickness - screen.x,
        indicator.rect.y - screen.y,
        thickness,
        indicator.rect.h,
        ScrollIndicatorColor,
      )
  of OverviewScrollAxis.Vertical:
    if indicator.before:
      buf.fillRect(
        indicator.rect.x - screen.x,
        indicator.rect.y - screen.y,
        indicator.rect.w,
        thickness,
        ScrollIndicatorColor,
      )
    if indicator.after:
      buf.fillRect(
        indicator.rect.x - screen.x,
        indicator.rect.y + indicator.rect.h - thickness - screen.y,
        indicator.rect.w,
        thickness,
        ScrollIndicatorColor,
      )

proc drawOverviewOverlayBuffer*(model: Model, screen: rv.Rect, buf: var PixelBuffer) =
  model.drawOverviewOverlayBufferForOutput(model.activeOutput, screen, buf)

proc drawOverviewOverlayBufferForOutput*(
    model: Model, outputId: OutputId, screen: rv.Rect, buf: var PixelBuffer
) =
  if not model.overviewActive:
    return

  let slots = model.previewSlotsForOutput(outputId)
  let active = model.activeWorkspaceSlotForOutput(outputId)
  let thickness = model.emptyWorkspaceFrameThickness()
  for idx, slot in slots:
    if not model.overviewWorkspaceSlotEmpty(slot):
      continue

    let rect = model.workspacePreviewRectForOutput(screen, slots, idx, outputId)
    let color =
      if slot == active:
        rgbaColorToArgb(model.focusedBorderColor)
      else:
        rgbaColorToArgb(model.unfocusedBorderColor)
    buf.fillRect(
      rect.x - screen.x, rect.y - screen.y, rect.w, rect.h, EmptyWorkspaceFill
    )
    buf.strokeRect(
      rect.x - screen.x, rect.y - screen.y, rect.w, rect.h, thickness, color
    )

  if model.overviewScrollerIndicators:
    for idx, _ in slots:
      buf.drawScrollIndicator(
        screen, model.overviewScrollIndicatorForOutput(outputId, screen, slots, idx)
      )
  for idx, _ in slots:
    buf.drawHiddenCountBadge(
      screen, model.overviewHiddenCountBadgeForOutput(outputId, screen, slots, idx)
    )

proc renderOverviewOverlayBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Transparent)
  model.drawOverviewOverlayBuffer(screen, result)

proc renderOverviewOverlayBufferForOutput*(
    model: Model, outputId: OutputId, screen: rv.Rect
): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Transparent)
  model.drawOverviewOverlayBufferForOutput(outputId, screen, result)
