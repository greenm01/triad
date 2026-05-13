import std/[math, options]
import ../state/engine
import ../types/runtime_values as rv
import workspaces

type
  OverviewStyle* {.pure.} = enum
    MangoGrid
    NiriWorkspaces

  OverviewDropKind* {.pure.} = enum
    DropNone
    DropWorkspace
    DropDynamicGap

  OverviewDropTarget* = object
    kind*: OverviewDropKind
    slot*: uint32

const OverviewDragThreshold* = 8'i32

proc effectiveOverviewZoom*(model: Model): float32 =
  if model.overviewZoom > 0:
    clamp(model.overviewZoom, 0.0001'f32, 0.75'f32)
  else:
    DefaultOverviewZoom

proc overviewStyle*(model: Model): OverviewStyle =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome and
      tagOpt.get().layoutMode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}:
    OverviewStyle.NiriWorkspaces
  else:
    OverviewStyle.MangoGrid

proc overviewUsesWorkspacePreviews*(model: Model): bool =
  model.overviewActive and model.overviewStyle() == OverviewStyle.NiriWorkspaces

proc previewSlots*(model: Model): seq[uint32] =
  model.visibleWorkspaceSlots()

proc activePreviewIndex*(model: Model, slots: openArray[uint32]): int =
  let active = model.activeWorkspaceSlot()
  for idx, slot in slots:
    if slot == active:
      return idx
  if slots.len > 0: 0 else: -1

proc previewSize*(model: Model, screen: rv.Rect): tuple[w, h: int32] =
  let zoom = model.effectiveOverviewZoom()
  (
    max(1'i32, int32(round(float32(max(1'i32, screen.w)) * zoom))),
    max(1'i32, int32(round(float32(max(1'i32, screen.h)) * zoom))),
  )

proc workspacePreviewRect*(
    model: Model, screen: rv.Rect, slots: openArray[uint32], idx: int
): rv.Rect =
  let size = model.previewSize(screen)
  let activeIdx = model.activePreviewIndex(slots)
  if activeIdx < 0 or idx < 0:
    return rv.Rect()

  let gap = max(0'i32, model.overviewOuterGap)
  let baseX = screen.x + (screen.w - size.w) div 2
  let baseY = screen.y + (screen.h - size.h) div 2
  let y =
    baseY + int32(idx - activeIdx) * (size.h + gap) + int32(model.overviewScrollOffset)
  rv.Rect(x: baseX, y: y, w: size.w, h: size.h)

proc rectContains(rect: rv.Rect, x, y: int32): bool =
  x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h

proc nextDynamicDropSlot(model: Model): uint32 =
  let trailing = model.trailingWorkspaceSlot()
  if trailing != 0:
    return trailing
  result = model.defaultWorkspaceCount() + 1
  for slot in model.sortedSlots():
    if slot >= result:
      result = slot + 1
  if result > MaxTagBits:
    result = 0

proc overviewDropTargetAt*(
    model: Model, screen: rv.Rect, x, y: int32
): OverviewDropTarget =
  if not model.overviewUsesWorkspacePreviews():
    return OverviewDropTarget(kind: OverviewDropKind.DropNone)

  let slots = model.previewSlots()
  if slots.len == 0:
    return OverviewDropTarget(kind: OverviewDropKind.DropNone)

  var minY = high(int32)
  var maxY = low(int32)
  for idx, slot in slots:
    let rect = model.workspacePreviewRect(screen, slots, idx)
    minY = min(minY, rect.y)
    maxY = max(maxY, rect.y + rect.h)
    if rect.rectContains(x, y):
      return OverviewDropTarget(kind: OverviewDropKind.DropWorkspace, slot: slot)

  if y >= minY - max(0'i32, model.overviewOuterGap) and
      y <= maxY + max(0'i32, model.overviewOuterGap):
    let slot = model.nextDynamicDropSlot()
    if slot != 0:
      return OverviewDropTarget(kind: OverviewDropKind.DropDynamicGap, slot: slot)

  OverviewDropTarget(kind: OverviewDropKind.DropNone)
