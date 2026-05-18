import std/options
import focus, workspaces
import ../core/layout_mode_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../state/engine
import ../types/janet_layouts
from ../types/runtime_values import
  Direction, FrameSplitOrientation, JanetLayoutId, LayoutMode, LayoutSelection,
  LayoutSelectionKind, NativeLayoutId
import layout_movement

proc resetLayoutViewport(model: var Model, tagId: TagId): bool =
  result = model.setTagViewportTarget(tagId, 0.0'f32, 0.0'f32) or result
  result = model.setTagViewportCurrent(tagId, 0.0'f32, 0.0'f32) or result
  result = model.clearTagViewportRetarget(tagId) or result
  result = model.clearTagViewportSnap(tagId) or result

proc resetNonScrollerViewport(model: var Model, tagId: TagId, mode: LayoutMode): bool =
  if mode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}:
    return false
  model.resetLayoutViewport(tagId)

proc coreLayoutMode(mode: LayoutMode): bool =
  mode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc usesCoreScrollerLayout(tag: TagData): bool =
  tag.customLayoutId.layoutIdString().len == 0 and
    tag.nativeLayoutId.nativeLayoutIdString().len == 0 and
    tag.layoutMode.coreLayoutMode()

proc setCommandLayout(model: var Model, tagId: TagId, mode: LayoutMode): bool =
  result = model.setTagLayout(tagId, mode)
  if result:
    result = model.resetNonScrollerViewport(tagId, mode) or result

proc setCommandCustomLayout(
    model: var Model, tagId: TagId, id: JanetLayoutId, fallback: LayoutSelection
): bool =
  result = model.setTagCustomLayout(tagId, id, fallback)
  if result:
    if fallback.kind == LayoutSelectionKind.Native:
      if fallback.nativeId.nativeLayoutIdString() == FrameTreeLayoutId:
        discard model.syncTagFramesFromPlacement(tagId)
      elif fallback.nativeId.nativeLayoutIdString() == BspTreeLayoutId:
        discard model.syncTagBspFromPlacement(tagId)
    result = model.resetLayoutViewport(tagId) or result

proc setCommandNativeLayout(
    model: var Model, tagId: TagId, id: NativeLayoutId, fallback: LayoutMode
): bool =
  result = model.setTagNativeLayout(tagId, id, fallback)
  if result:
    if id.nativeLayoutIdString() == FrameTreeLayoutId:
      discard model.syncTagFramesFromPlacement(tagId)
    elif id.nativeLayoutIdString() == BspTreeLayoutId:
      discard model.syncTagBspFromPlacement(tagId)
    result = model.resetLayoutViewport(tagId) or result

proc focusedPosition(
    model: var Model
): tuple[
  found: bool, tagId: TagId, winId: WindowId, columnId: ColumnId, colIdx, winIdx: int
] =
  let tagId = model.ensureActiveWorkspace()
  let winId = model.focusedOnActiveTag()
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, tagId, winId, NullColumnId, -1, -1)
  let placement = placementOpt.get()
  let colIdx = int(model.columnIndexForTag(tagId, placement.columnId)) - 1
  if colIdx < 0:
    return (false, tagId, winId, NullColumnId, -1, -1)
  (true, tagId, winId, placement.columnId, colIdx, int(placement.windowIdx) - 1)

proc removeWindowFromAllTagsAndRefreshFocus*(model: var Model, winId: WindowId): bool =
  let slots = model.sortedSlots()
  for slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId != NullTagId and model.removeWindowFromTag(tagId, winId):
      discard model.recomputeVisibleFocus(tagId)
      result = true

proc addPlacedWindowColumn*(
    model: var Model,
    tagId: TagId,
    winId: WindowId,
    index = high(int),
    widthProportion = 0.0'f32,
    isFullWidth = false,
    scrollerSingleProportion = 0.0'f32,
): ColumnId =
  let width =
    if widthProportion > 0.0'f32:
      widthProportion
    else:
      model.defaultColumnWidth()
  result =
    model.insertColumn(tagId, index, width, isFullWidth, scrollerSingleProportion)
  discard model.moveWindowToColumn(tagId, winId, result, 0)

proc sourceWorkspaceFallbackFocus*(model: var Model, tagId: TagId): WindowId =
  if tagId == NullTagId:
    return NullWindowId
  if model.focusMostRecentWindowOnTag(tagId):
    return model.focusedOnActiveTag()
  model.recomputeVisibleFocus(tagId)

proc layoutTargetTag(model: var Model, slot: uint32): TagId =
  result =
    if slot == 0:
      model.ensureActiveWorkspace()
    else:
      model.tagForSlot(slot)

proc layoutTargetAcceptsChange(model: Model, slot: uint32, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  if slot > model.defaultWorkspaceCount() and slot != model.activeWorkspaceSlot() and
      not model.tagHasNonStickyLiveWindows(tagId):
    return false
  true

proc setLayoutForSlot*(model: var Model, slot: uint32, mode: LayoutMode): bool =
  let tagId = model.layoutTargetTag(slot)
  if not model.layoutTargetAcceptsChange(slot, tagId):
    return false
  if not mode.coreLayoutMode():
    let id = janetLayoutId(mode.layoutModeId())
    let custom = model.customLayoutConfig(id)
    if custom.isNone:
      return false
    return model.setCommandCustomLayout(tagId, id, custom.get().fallback)
  model.setCommandLayout(tagId, mode)

proc setCustomLayoutForSlot*(model: var Model, slot: uint32, id: JanetLayoutId): bool =
  let custom = model.customLayoutConfig(id)
  if custom.isNone:
    return false
  let tagId = model.layoutTargetTag(slot)
  if not model.layoutTargetAcceptsChange(slot, tagId):
    return false
  model.setCommandCustomLayout(tagId, id, custom.get().fallback)

proc setNativeLayoutForSlot*(model: var Model, slot: uint32, id: NativeLayoutId): bool =
  let native = parseNativeLayoutId(id.nativeLayoutIdString())
  if native.isNone:
    return false
  let tagId = model.layoutTargetTag(slot)
  if not model.layoutTargetAcceptsChange(slot, tagId):
    return false
  model.setCommandNativeLayout(tagId, id, native.get().fallback.builtin)

proc tagLayoutSelection(tag: TagData): LayoutSelection =
  if tag.customLayoutId.layoutIdString().len > 0:
    let fallback =
      if tag.nativeLayoutId.nativeLayoutIdString().len > 0:
        nativeSelection(tag.nativeLayoutId, tag.layoutMode)
      else:
        builtinSelection(tag.layoutMode)
    customSelection(tag.customLayoutId, fallback)
  elif tag.nativeLayoutId.nativeLayoutIdString().len > 0:
    nativeSelection(tag.nativeLayoutId, tag.layoutMode)
  else:
    builtinSelection(tag.layoutMode)

proc switchLayout*(model: var Model): bool =
  let tagId = model.ensureActiveWorkspace()
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let selectionCycle = model.layoutSelectionCycle()
  if selectionCycle.len == 0:
    return false
  let current = tagOpt.get().tagLayoutSelection()
  var idx = -1
  for i, selection in selectionCycle:
    if selection.kind == current.kind and
        selection.selectionId() == current.selectionId():
      idx = i
      break
  let nextIdx =
    if idx == -1:
      0
    else:
      (idx + 1) mod selectionCycle.len
  let next = selectionCycle[nextIdx]
  case next.kind
  of LayoutSelectionKind.Builtin:
    model.setCommandLayout(tagId, next.builtin)
  of LayoutSelectionKind.Custom:
    let custom = model.customLayoutConfig(next.customId)
    if custom.isNone:
      return model.setCommandLayout(tagId, next.builtin)
    model.setCommandCustomLayout(tagId, next.customId, custom.get().fallback)
  of LayoutSelectionKind.Native:
    model.setCommandNativeLayout(tagId, next.nativeId, next.builtin)

proc setMasterCount*(model: var Model, count: int): bool =
  let tagId = model.ensureActiveWorkspace()
  tagId != NullTagId and model.setTagMasterCount(tagId, count)

proc adjustMasterCount*(model: var Model, delta: int): bool =
  let tagId = model.ensureActiveWorkspace()
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  model.setTagMasterCount(tagId, tagOpt.get().masterCount + delta)

proc setMasterRatio*(model: var Model, ratio: float32): bool =
  let tagId = model.ensureActiveWorkspace()
  tagId != NullTagId and model.setTagMasterRatio(tagId, ratio)

proc adjustMasterRatio*(model: var Model, delta: float32): bool =
  let tagId = model.ensureActiveWorkspace()
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  model.setTagMasterRatio(tagId, tagOpt.get().masterSplitRatio + delta)

proc resizeWidth*(model: var Model, delta: float32): bool =
  if model.activeTagUsesBspTree():
    return model.adjustFocusedBspSplit(
      model.activeTag, FrameSplitOrientation.Horizontal, delta
    )
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if not tag.usesCoreScrollerLayout():
    return false
  case tag.layoutMode
  of LayoutMode.Scroller:
    let column = model.column(pos.columnId).get()
    model.setColumnWidth(pos.columnId, column.widthProportion + delta)
  of LayoutMode.VerticalScroller:
    let win = model.windowData(pos.winId).get()
    model.setWindowWidthProportion(pos.winId, win.widthProportion + delta)
  of LayoutMode.MasterStack:
    model.setTagMasterRatio(pos.tagId, tag.masterSplitRatio + delta)
  else:
    false

proc resizeHeight*(model: var Model, delta: float32): bool =
  if model.activeTagUsesBspTree():
    return model.adjustFocusedBspSplit(
      model.activeTag, FrameSplitOrientation.Vertical, delta
    )
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if not tag.usesCoreScrollerLayout():
    return false
  case tag.layoutMode
  of LayoutMode.VerticalScroller:
    let column = model.column(pos.columnId).get()
    model.setColumnWidth(pos.columnId, column.widthProportion + delta)
  of LayoutMode.Scroller:
    let win = model.windowData(pos.winId).get()
    model.setWindowHeightProportion(pos.winId, win.heightProportion + delta)
  else:
    false

proc setFocusedColumnWidth*(model: var Model, width: float32): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if not tag.usesCoreScrollerLayout() or tag.layoutMode != LayoutMode.Scroller:
    return false
  model.setColumnWidth(pos.columnId, width)

proc switchProportionPreset*(model: var Model, delta: int): bool =
  if delta == 0:
    return false
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if not tag.usesCoreScrollerLayout():
    return false
  let presets = model.scrollerProportionPresets()
  if presets.len == 0:
    return false
  let column = model.column(pos.columnId).get()
  let current = clampProportion(column.widthProportion)
  let epsilon = 0.0001'f32
  var index =
    if delta > 0:
      0
    else:
      presets.len - 1
  if delta > 0:
    while index < presets.len and presets[index] <= current + epsilon:
      inc index
    if index >= presets.len:
      index = 0
    for _ in 1 ..< abs(delta):
      index = (index + 1) mod presets.len
  else:
    while index >= 0 and presets[index] >= current - epsilon:
      dec index
    if index < 0:
      index = presets.len - 1
    for _ in 1 ..< abs(delta):
      index = (index + presets.len - 1) mod presets.len
  model.setColumnWidth(pos.columnId, presets[index])

proc toggleFocusedColumnFullWidth*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if not tag.usesCoreScrollerLayout():
    return false
  result = model.toggleColumnFullWidth(pos.columnId)
  if result:
    discard model.requestTagViewportRetarget(pos.tagId)

proc preserveMovedFocus(
    model: var Model, tagId: TagId, winId: WindowId, moved: bool
): bool =
  if not moved:
    return false
  discard model.setTagFocus(tagId, winId)
  discard model.requestTagViewportRetarget(tagId)
  true

proc retargetMovedFocus(model: var Model, tagId: TagId, moved: bool): bool =
  if not moved:
    return false
  discard model.requestTagViewportRetarget(tagId)
  true

proc moveFocusedWindowToFrameTarget(
    model: var Model, targetFrame: FrameId, targetWindow: WindowId
): bool =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  if tagId == NullTagId or focused == NullWindowId or targetFrame == NullFrameId:
    return false

  let sourceFrame = model.frameForWindowOnTag(tagId, focused)
  if sourceFrame == NullFrameId or sourceFrame == targetFrame:
    return false

  if targetWindow == NullWindowId:
    return model.preserveMovedFocus(
      tagId, focused, model.addWindowToFrame(tagId, focused, targetFrame)
    )

  let targetWindowFrame = model.frameForWindowOnTag(tagId, targetWindow)
  if targetWindowFrame != targetFrame:
    return false

  let focusedMoved = model.addWindowToFrame(tagId, focused, targetFrame)
  let targetMoved = model.addWindowToFrame(tagId, targetWindow, sourceFrame)
  if not focusedMoved or not targetMoved:
    return false

  discard model.setFrameActiveWindow(targetFrame, focused)
  discard model.setFrameActiveWindow(sourceFrame, targetWindow)
  discard model.setFocusedFrame(tagId, targetFrame)
  model.preserveMovedFocus(tagId, focused, true)

proc moveFocusedWindowByDirection(model: var Model, direction: Direction): bool =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  if tagId == NullTagId or focused == NullWindowId:
    return false

  let target = model.directionalTarget(direction)
  case target.kind
  of DirectionalTargetKind.Frame:
    model.moveFocusedWindowToFrameTarget(target.frame, target.window)
  of DirectionalTargetKind.Window:
    if target.window == NullWindowId or target.window == focused:
      return false
    model.preserveMovedFocus(
      tagId, focused, model.swapPlacedWindows(tagId, focused, tagId, target.window)
    )
  of DirectionalTargetKind.None:
    false

proc preserveEmptyTargetLayoutContext(
    model: var Model, sourceTag, targetTag: TagId, targetWasEmpty: bool
): bool =
  if not targetWasEmpty:
    return false
  let source = model.tagData(sourceTag)
  let target = model.tagData(targetTag)
  if source.isNone or target.isNone:
    return false
  let sourceData = source.get()
  let targetData = target.get()
  result = false
  if targetData.layoutMode != sourceData.layoutMode:
    result = model.setTagLayout(targetTag, sourceData.layoutMode) or result
  if targetData.masterCount != sourceData.masterCount:
    result = model.setTagMasterCount(targetTag, sourceData.masterCount) or result
  if targetData.masterSplitRatio != sourceData.masterSplitRatio:
    result = model.setTagMasterRatio(targetTag, sourceData.masterSplitRatio) or result

proc moveWindowToSlot*(
    model: var Model, winId: WindowId, targetSlot: uint32, activateInOverview = true
): bool =
  if targetSlot == 0:
    return false
  let position = model.firstWindowPosition(winId)
  let sourceTag = position.tagId
  if sourceTag == NullTagId or winId == NullWindowId:
    return false
  let sourceWindowState = model.windowData(winId)
  let targetTag = model.ensureWorkspaceSlot(targetSlot)
  if targetTag == NullTagId:
    return false
  if targetTag == sourceTag:
    return false
  let targetWasEmpty = not model.tagHasNonStickyLiveWindows(targetTag)

  let sourcePlacement = model.placementForWindowOnTag(sourceTag, winId)
  var sourceColumnWidth = model.defaultColumnWidth()
  var sourceColumnFullWidth = false
  var sourceScrollerSingleProportion = 0.0'f32
  if sourcePlacement.isSome:
    let sourceColumn = model.column(sourcePlacement.get().columnId)
    if sourceColumn.isSome:
      sourceColumnWidth = sourceColumn.get().widthProportion
      sourceColumnFullWidth = sourceColumn.get().isFullWidth
      sourceScrollerSingleProportion = sourceColumn.get().scrollerSingleProportion

  discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
  if not model.overviewActive:
    discard model.sourceWorkspaceFallbackFocus(sourceTag)
  discard model.preserveEmptyTargetLayoutContext(sourceTag, targetTag, targetWasEmpty)
  discard model.addPlacedWindowColumn(
    targetTag,
    winId,
    widthProportion = sourceColumnWidth,
    isFullWidth = sourceColumnFullWidth,
    scrollerSingleProportion = sourceScrollerSingleProportion,
  )
  if sourceWindowState.isSome:
    discard model.preserveWindowRuntimeAttributes(winId, sourceWindowState.get())
  discard model.setTagFocus(targetTag, winId)
  if model.overviewActive and activateInOverview:
    discard model.setActiveWorkspace(targetTag)
    discard model.recordWorkspace(targetTag)
  model.refreshVisibleWorkspaceSlots()
  true

proc moveFocusedWindowToSlot*(model: var Model, targetSlot: uint32): bool =
  model.moveWindowToSlot(model.focusedOnActiveTag(), targetSlot)

proc moveFocusedWindowToSlotAndFocus*(model: var Model, targetSlot: uint32): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false
  if not model.moveFocusedWindowToSlot(targetSlot):
    return false
  model.focusWindow(focused)

proc swapFocusedWindowToSlot*(model: var Model, targetSlot: uint32): bool =
  let activeTag = model.activeTag
  let activeFocused = model.focusedOnActiveTag()
  let targetTag = model.ensureWorkspaceSlot(targetSlot)
  if activeTag == NullTagId or activeFocused == NullWindowId or targetTag == NullTagId:
    return false

  let targetTagData = model.tagData(targetTag).get()
  let targetFocused = targetTagData.focusedWindow
  if targetFocused == NullWindowId or
      model.placementForWindowOnTag(targetTag, targetFocused).isNone:
    return model.moveFocusedWindowToSlot(targetSlot)

  if model.swapPlacedWindows(activeTag, activeFocused, targetTag, targetFocused):
    discard model.setTagFocus(activeTag, targetFocused)
    discard model.setTagFocus(targetTag, activeFocused)
    return true
  false

proc moveFocusedWindowLeft*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirLeft, movementEval)
  if custom.handled:
    return custom.dirty
  model.moveFocusedWindowByDirection(Direction.DirLeft)

proc moveFocusedWindowRight*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirRight, movementEval)
  if custom.handled:
    return custom.dirty
  model.moveFocusedWindowByDirection(Direction.DirRight)

proc moveFocusedWindowUp*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirUp, movementEval)
  if custom.handled:
    return custom.dirty
  model.moveFocusedWindowByDirection(Direction.DirUp)

proc moveFocusedWindowDown*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirDown, movementEval)
  if custom.handled:
    return custom.dirty
  model.moveFocusedWindowByDirection(Direction.DirDown)

proc moveFocusedWindowUpOrWorkspace*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirUp, movementEval)
  if custom.handled:
    return custom.dirty
  if model.moveFocusedWindowByDirection(Direction.DirUp):
    return true
  let target = model.nearestWorkspaceSlot(-1, false)
  target != 0 and model.moveFocusedWindowToSlotAndFocus(target)

proc moveFocusedWindowDownOrWorkspace*(
    model: var Model, movementEval: CustomLayoutMovementEval = nil
): bool =
  let custom = model.applyCustomLayoutMovement(Direction.DirDown, movementEval)
  if custom.handled:
    return custom.dirty
  if model.moveFocusedWindowByDirection(Direction.DirDown):
    return true
  let target = model.nearestWorkspaceSlot(1, false)
  target != 0 and model.moveFocusedWindowToSlotAndFocus(target)

proc moveFocusedColumnLeft*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found or pos.colIdx <= 0:
    return false
  model.retargetMovedFocus(
    pos.tagId, model.moveColumn(pos.tagId, pos.colIdx, pos.colIdx - 1)
  )

proc moveFocusedColumnRight*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columnCount = model.columnCountForTag(pos.tagId)
  if pos.colIdx >= columnCount - 1:
    return false
  model.retargetMovedFocus(
    pos.tagId, model.moveColumn(pos.tagId, pos.colIdx, pos.colIdx + 1)
  )

proc moveFocusedColumnToFirst*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found or pos.colIdx <= 0:
    return false
  model.retargetMovedFocus(pos.tagId, model.moveColumn(pos.tagId, pos.colIdx, 0))

proc moveFocusedColumnToLast*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columnCount = model.columnCountForTag(pos.tagId)
  if pos.colIdx >= columnCount - 1:
    return false
  model.retargetMovedFocus(
    pos.tagId, model.moveColumn(pos.tagId, pos.colIdx, columnCount - 1)
  )

proc consumeNextColumnWindow*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columnCount = model.columnCountForTag(pos.tagId)
  if pos.colIdx >= columnCount - 1:
    return false
  let nextColumn = model.columnAt(pos.tagId, pos.colIdx + 1)
  let nextWindow = model.windowAt(nextColumn, 0)
  if nextWindow == NullWindowId:
    return false
  let targetIdx = model.windowCountForColumn(pos.columnId)
  model.moveWindowToColumn(pos.tagId, nextWindow, pos.columnId, targetIdx)

proc expelFocusedWindow*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if model.windowCountForColumn(pos.columnId) <= 1:
    return false
  let target = model.insertColumn(pos.tagId, pos.colIdx + 1, model.defaultColumnWidth())
  model.preserveMovedFocus(
    pos.tagId, pos.winId, model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)
  )

proc zoomFocusedWindow*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if model.columnCountForTag(pos.tagId) == 0:
    return false
  let master = model.windowAt(model.columnAt(pos.tagId, 0), 0)
  if master == NullWindowId:
    return false
  if master == pos.winId:
    return false
  model.preserveMovedFocus(
    pos.tagId,
    pos.winId,
    model.swapPlacedWindows(pos.tagId, master, pos.tagId, pos.winId),
  )
