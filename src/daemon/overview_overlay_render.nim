import ../state/engine
import ../systems/[overview_geometry, workspaces]
import ../types/model
import ../types/runtime_values as rv
import pixel_buffer

const
  Transparent = 0x00000000'u32
  EmptyWorkspaceFill = 0xcc000000'u32

proc emptyWorkspaceFrameThickness*(model: Model): int32 =
  max(2'i32, min(max(0'i32, model.borderWidth), 8'i32))

proc overviewWorkspaceSlotEmpty(model: Model, slot: uint32): bool =
  let tagId = model.tagForSlot(slot)
  tagId == NullTagId or not model.tagHasLiveWindows(tagId)

proc overviewOverlayCacheKey*(model: Model, screen: rv.Rect): string =
  result =
    $screen.x & ":" & $screen.y & ":" & $screen.w & ":" & $screen.h & ":" &
    $model.activeWorkspaceSlot() & ":" & $model.effectiveOverviewZoom() & ":" &
    $model.borderWidth & ":" & $model.focusedBorderColor & ":" &
    $model.unfocusedBorderColor
  for slot in model.previewSlots():
    result.add(":")
    result.add($slot)
    result.add(if model.overviewWorkspaceSlotEmpty(slot): "e" else: "o")

proc renderOverviewOverlayBuffer*(model: Model, screen: rv.Rect): PixelBuffer =
  result = initPixelBuffer(max(1'i32, screen.w), max(1'i32, screen.h), Transparent)
  if not model.overviewActive:
    return

  let slots = model.previewSlots()
  let active = model.activeWorkspaceSlot()
  let thickness = model.emptyWorkspaceFrameThickness()
  for idx, slot in slots:
    if not model.overviewWorkspaceSlotEmpty(slot):
      continue

    let rect = model.workspacePreviewRect(screen, slots, idx)
    let color =
      if slot == active:
        rgbaColorToArgb(model.focusedBorderColor)
      else:
        rgbaColorToArgb(model.unfocusedBorderColor)
    result.fillRect(
      rect.x - screen.x, rect.y - screen.y, rect.w, rect.h, EmptyWorkspaceFill
    )
    result.strokeRect(
      rect.x - screen.x, rect.y - screen.y, rect.w, rect.h, thickness, color
    )
