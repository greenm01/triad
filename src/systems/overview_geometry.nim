import std/[math, options]
import ../core/[layout_descriptor_codec, layout_selection_codec, native_layout_codec]
import ../state/engine
import ../types/core as core_types
import ../types/model as model_types
import ../types/projection_values as rv
import ../types/system_views
import workspaces

export system_views

const OverviewDragThreshold* = 8'i32
const NiriWorkspaceGapRatio = 0.1'f32

proc activePreviewIndexForOutput*(
  model: Model, outputId: OutputId, slots: openArray[uint32]
): int

proc workspacePreviewRectForOutput*(
  model: Model, screen: rv.Rect, slots: openArray[uint32], idx: int, outputId: OutputId
): rv.Rect

proc overviewWorkspaceSlotAtForOutput*(
  model: Model, outputId: OutputId, screen: rv.Rect, x, y: int32, extendedX = false
): uint32

proc overviewDropTargetAtForOutput*(
  model: Model, outputId: OutputId, screen: rv.Rect, x, y: int32
): OverviewDropTarget

proc effectiveOverviewZoom*(model: Model): float32 =
  if model.overviewZoom > 0:
    clamp(model.overviewZoom, 0.0001'f32, 0.75'f32)
  else:
    DefaultOverviewZoom

proc overviewStyle*(model: Model): OverviewStyle =
  OverviewStyle.WorkspaceStrip

proc overviewUsesWorkspacePreviews*(model: Model): bool =
  model.overviewActive

proc overviewOutput(model: Model): OutputId =
  if model.activeOutput != NullOutputId and model.outputData(model.activeOutput).isSome:
    return model.activeOutput
  let outputId = model.workspaceOutput(model.activeTag)
  if outputId != NullOutputId:
    return outputId
  model.primaryOutput

proc overviewScreenForOutput(model: Model, outputId: OutputId): rv.Rect =
  if outputId != NullOutputId:
    let outputOpt = model.outputData(outputId)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return rv.Rect(
          x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH
        )
      if output.w > 0 and output.h > 0:
        return rv.Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  rv.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc rectContains(rect: rv.Rect, x, y: int32): bool =
  x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h

proc yContains(rect: rv.Rect, y: int32): bool =
  y >= rect.y and y < rect.y + rect.h

proc overviewOutputAt*(model: Model, x, y: int32): OutputId =
  for outputId in model.sortedOutputIdsByExternal():
    if model.overviewScreenForOutput(outputId).rectContains(x, y):
      return outputId
  NullOutputId

proc activeWorkspaceSlotForOutput*(model: Model, outputId: OutputId): uint32 =
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    let tagId = outputOpt.get().currentTag
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome:
      return tagOpt.get().slot
  if outputId == model.overviewOutput():
    return model.activeWorkspaceSlot()
  0'u32

proc overviewSlotVisible(model: Model, slot: uint32, outputId: OutputId): bool =
  if slot == model.activeWorkspaceSlotForOutput(outputId):
    return true
  let tagId = model.tagForSlot(slot)
  if tagId == NullTagId:
    return false
  if outputId != NullOutputId and model.workspaceOutput(tagId) != outputId:
    return false
  model.tagHasNonStickyLiveWindows(tagId)

proc previewSlotsForOutput*(model: Model, outputId: OutputId): seq[uint32] =
  for slot in model.visibleWorkspaceSlots():
    if model.overviewSlotVisible(slot, outputId):
      result.add(slot)
  if result.len == 0:
    let active = model.activeWorkspaceSlotForOutput(outputId)
    if active != 0:
      result.add(active)

proc previewSlots*(model: Model): seq[uint32] =
  model.previewSlotsForOutput(model.overviewOutput())

proc activePreviewIndex*(model: Model, slots: openArray[uint32]): int =
  model.activePreviewIndexForOutput(model.overviewOutput(), slots)

proc activePreviewIndexForOutput*(
    model: Model, outputId: OutputId, slots: openArray[uint32]
): int =
  let active = model.activeWorkspaceSlotForOutput(outputId)
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

proc workspacePreviewGap*(model: Model, screen: rv.Rect): int32 =
  int32(
    round(
      float32(max(1'i32, screen.h)) * NiriWorkspaceGapRatio *
        model.effectiveOverviewZoom()
    )
  )

proc workspacePreviewRect*(
    model: Model, screen: rv.Rect, slots: openArray[uint32], idx: int
): rv.Rect =
  model.workspacePreviewRectForOutput(screen, slots, idx, model.overviewOutput())

proc workspacePreviewRectForOutput*(
    model: Model,
    screen: rv.Rect,
    slots: openArray[uint32],
    idx: int,
    outputId: OutputId,
): rv.Rect =
  let size = model.previewSize(screen)
  let activeIdx = model.activePreviewIndexForOutput(outputId, slots)
  if activeIdx < 0 or idx < 0:
    return rv.Rect()

  let gap = model.workspacePreviewGap(screen)
  let baseX = screen.x + (screen.w - size.w) div 2
  let baseY = screen.y + (screen.h - size.h) div 2
  let y = baseY + int32(idx - activeIdx) * (size.h + gap)
  rv.Rect(x: baseX, y: y, w: size.w, h: size.h)

proc overviewClampProportion(value: float32): float32 =
  clamp(value, 0.05'f32, 1.0'f32)

proc overviewScaledGap(model: Model, gap: int32): int32 =
  int32(round(float32(max(0'i32, gap)) * model.effectiveOverviewZoom()))

proc previewUsableRect(model: Model, preview: rv.Rect): rv.Rect =
  let outerGap = model.overviewScaledGap(model.outerGaps)
  rv.Rect(
    x: preview.x + outerGap,
    y: preview.y + outerGap,
    w: max(0'i32, preview.w - 2 * outerGap),
    h: max(0'i32, preview.h - 2 * outerGap),
  )

proc overviewTiledWindowVisible(
    model: Model, winId: core_types.WindowId, win: model_types.WindowData
): bool =
  win.windowAdmitted() and not win.isFloating and not win.isMinimized and
    not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId)

proc overviewTiledWindowCount(model: Model, tagId: TagId): int =
  for columnId, _ in model.columnsOnTagWithId(tagId):
    for winId, win in model.windowsOnColumnWithId(columnId):
      if model.overviewTiledWindowVisible(winId, win):
        inc result

proc overviewVisibleColumnProportions(
    model: Model, tagId: TagId
): seq[tuple[widthProportion, scrollerSingleProportion: float32, fullWidth: bool]] =
  if model.overviewActive:
    for winId in model.overviewFindableWindowIds(tagId):
      let winOpt = model.windowData(winId)
      if winOpt.isSome:
        result.add(
          (
            widthProportion: winOpt.get().widthProportion,
            scrollerSingleProportion: 0.0'f32,
            fullWidth: false,
          )
        )
    return

  for columnId, column in model.columnsOnTagWithId(tagId):
    var visibleWindows = 0
    for winId, win in model.windowsOnColumnWithId(columnId):
      if model.overviewTiledWindowVisible(winId, win):
        inc visibleWindows
    if visibleWindows > 0:
      result.add(
        (
          widthProportion: column.widthProportion,
          scrollerSingleProportion: column.scrollerSingleProportion,
          fullWidth: column.isFullWidth,
        )
      )

proc effectiveOverviewColumnProportion(
    column: tuple[widthProportion, scrollerSingleProportion: float32, fullWidth: bool]
): float32 =
  if column.fullWidth:
    1.0'f32
  else:
    overviewClampProportion(column.widthProportion)

proc overviewSelectedLayoutMode(tag: TagData): Option[rv.LayoutMode] =
  let customId = tag.customLayoutId.layoutIdString()
  if customId.len > 0:
    return layoutModeForBundledId(customId)
  if tag.nativeLayoutId.nativeLayoutIdString().len > 0:
    return none(rv.LayoutMode)
  some(tag.layoutMode)

proc overviewHiddenCountBadgeForOutput*(
    model: Model,
    outputId: OutputId,
    screen: rv.Rect,
    slots: openArray[uint32],
    idx: int,
): OverviewHiddenCountBadge =
  if model.overviewActive:
    return
  if idx < 0 or idx >= slots.len:
    return
  let slot = slots[idx]
  let tagId = model.tagForSlot(slot)
  if tagId == NullTagId:
    return
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return

  let tag = tagOpt.get()
  let modeOpt = overviewSelectedLayoutMode(tag)
  if modeOpt.isNone:
    return
  let mode = modeOpt.get()
  let windowCount = model.overviewTiledWindowCount(tagId)
  if windowCount <= 1:
    return

  let preview = model.workspacePreviewRectForOutput(screen, slots, idx, outputId)
  let usable = model.previewUsableRect(preview)
  let innerGap = model.overviewScaledGap(model.innerGaps)
  let masterCount = min(windowCount, max(1, tag.masterCount))

  result.slot = slot
  case mode
  of rv.LayoutMode.Monocle:
    result.count = windowCount - 1
    result.rect = usable
  of rv.LayoutMode.Deck:
    let stackCount = windowCount - masterCount
    if stackCount <= 1:
      return OverviewHiddenCountBadge()
    let masterWidth =
      int32(float32(usable.w) * clamp(tag.masterSplitRatio, 0.05'f32, 0.95'f32))
    result.count = stackCount - 1
    result.rect = rv.Rect(
      x: usable.x + masterWidth + innerGap,
      y: usable.y,
      w: max(0'i32, usable.w - masterWidth - innerGap),
      h: usable.h,
    )
  of rv.LayoutMode.VerticalDeck:
    let stackCount = windowCount - masterCount
    if stackCount <= 1:
      return OverviewHiddenCountBadge()
    let masterHeight =
      int32(float32(usable.h) * clamp(tag.masterSplitRatio, 0.05'f32, 0.95'f32))
    result.count = stackCount - 1
    result.rect = rv.Rect(
      x: usable.x,
      y: usable.y + masterHeight + innerGap,
      w: usable.w,
      h: max(0'i32, usable.h - masterHeight - innerGap),
    )
  else:
    result = OverviewHiddenCountBadge()

proc overviewHiddenCountBadge*(
    model: Model, screen: rv.Rect, slots: openArray[uint32], idx: int
): OverviewHiddenCountBadge =
  model.overviewHiddenCountBadgeForOutput(model.overviewOutput(), screen, slots, idx)

proc overviewScrollIndicatorForOutput*(
    model: Model,
    outputId: OutputId,
    screen: rv.Rect,
    slots: openArray[uint32],
    idx: int,
): OverviewScrollIndicator =
  if idx < 0 or idx >= slots.len:
    return
  let slot = slots[idx]
  let tagId = model.tagForSlot(slot)
  if tagId == NullTagId:
    return
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return

  let tag = tagOpt.get()
  let mode =
    if model.overviewActive:
      if tag.customLayoutId.layoutIdString().len == 0 and
          tag.nativeLayoutId.nativeLayoutIdString().len == 0 and
          tag.layoutMode in {rv.LayoutMode.Scroller, rv.LayoutMode.VerticalScroller}:
        tag.layoutMode
      else:
        rv.LayoutMode.Scroller
    else:
      let modeOpt = overviewSelectedLayoutMode(tag)
      if modeOpt.isNone:
        return
      modeOpt.get()
  if mode notin {rv.LayoutMode.Scroller, rv.LayoutMode.VerticalScroller}:
    return

  let columns = model.overviewVisibleColumnProportions(tagId)
  if columns.len <= 1 and
      (columns.len == 0 or columns[0].scrollerSingleProportion > 0.0'f32):
    return

  let preview = model.workspacePreviewRectForOutput(screen, slots, idx, outputId)
  let usable = model.previewUsableRect(preview)
  let innerGap = model.overviewScaledGap(model.innerGaps)

  result.slot = slot
  result.rect = preview
  case mode
  of rv.LayoutMode.Scroller:
    var totalWidth = 0'i32
    for column in columns:
      totalWidth += int32(
        float32(usable.w) * column.effectiveOverviewColumnProportion()
      )
    let offset = int32(round(tag.currentViewportXOffset))
    result.axis = OverviewScrollAxis.Horizontal
    result.before = offset > 0
    result.after = totalWidth - offset > usable.w + innerGap
    if not result.before and not result.after:
      result = OverviewScrollIndicator()
  of rv.LayoutMode.VerticalScroller:
    var totalHeight = 0'i32
    for column in columns:
      totalHeight +=
        int32(float32(usable.h) * column.effectiveOverviewColumnProportion()) + innerGap
    let offset = int32(round(tag.currentViewportYOffset))
    result.axis = OverviewScrollAxis.Vertical
    result.before = offset > 0
    result.after = totalHeight - offset > usable.h + innerGap
    if not result.before and not result.after:
      result = OverviewScrollIndicator()
  else:
    result = OverviewScrollIndicator()

proc overviewScrollIndicator*(
    model: Model, screen: rv.Rect, slots: openArray[uint32], idx: int
): OverviewScrollIndicator =
  model.overviewScrollIndicatorForOutput(model.overviewOutput(), screen, slots, idx)

proc overviewWorkspaceSlotAt*(
    model: Model, screen: rv.Rect, x, y: int32, extendedX = false
): uint32 =
  model.overviewWorkspaceSlotAtForOutput(
    model.overviewOutputAt(x, y), screen, x, y, extendedX
  )

proc overviewWorkspaceSlotAtForOutput*(
    model: Model, outputId: OutputId, screen: rv.Rect, x, y: int32, extendedX = false
): uint32 =
  if not model.overviewActive:
    return 0

  let slots = model.previewSlotsForOutput(outputId)
  for idx, slot in slots:
    let rect = model.workspacePreviewRectForOutput(screen, slots, idx, outputId)
    if extendedX:
      if x >= screen.x and x < screen.x + screen.w and rect.yContains(y):
        return slot
    elif rect.rectContains(x, y):
      return slot
  0

proc nextDynamicDropSlot(model: Model, outputId: OutputId): uint32 =
  let trailing = model.trailingWorkspaceSlot(outputId)
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
  let outputId = model.overviewOutputAt(x, y)
  model.overviewDropTargetAtForOutput(outputId, screen, x, y)

proc overviewDropTargetAtForOutput*(
    model: Model, outputId: OutputId, screen: rv.Rect, x, y: int32
): OverviewDropTarget =
  if not model.overviewActive:
    return OverviewDropTarget(kind: OverviewDropKind.DropNone)

  let slots = model.previewSlotsForOutput(outputId)
  if slots.len == 0:
    return OverviewDropTarget(kind: OverviewDropKind.DropNone)

  var minY = high(int32)
  var maxY = low(int32)
  for idx, slot in slots:
    let rect = model.workspacePreviewRectForOutput(screen, slots, idx, outputId)
    minY = min(minY, rect.y)
    maxY = max(maxY, rect.y + rect.h)
    if x >= screen.x and x < screen.x + screen.w and rect.yContains(y):
      return OverviewDropTarget(
        kind: OverviewDropKind.DropWorkspace, outputId: outputId, slot: slot
      )

  let gap = model.workspacePreviewGap(screen)
  if x >= screen.x and x < screen.x + screen.w and y >= minY - gap and y <= maxY + gap:
    let slot = model.nextDynamicDropSlot(outputId)
    if slot != 0:
      return OverviewDropTarget(
        kind: OverviewDropKind.DropDynamicGap, outputId: outputId, slot: slot
      )

  OverviewDropTarget(kind: OverviewDropKind.DropNone)
