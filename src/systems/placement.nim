import std/options
import focus, workspaces
import ../state/engine
from ../types/runtime_values import LayoutMode

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

proc sourceWorkspaceFallbackFocus(model: var Model, tagId: TagId): WindowId =
  if tagId == NullTagId:
    return NullWindowId
  if model.focusMostRecentWindowOnTag(tagId):
    return model.focusedOnActiveTag()
  model.recomputeVisibleFocus(tagId)

proc setLayoutForSlot*(model: var Model, slot: uint32, mode: LayoutMode): bool =
  let tagId =
    if slot == 0:
      model.ensureActiveWorkspace()
    else:
      model.tagForSlot(slot)
  if tagId == NullTagId:
    return false
  if slot > model.defaultWorkspaceCount() and slot != model.activeWorkspaceSlot() and
      not model.tagHasNonStickyLiveWindows(tagId):
    return false
  tagId != NullTagId and model.setTagLayout(tagId, mode)

proc switchLayout*(model: var Model): bool =
  let tagId = model.ensureActiveWorkspace()
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let cycle = model.layoutCycle()
  let idx = cycle.find(tagOpt.get().layoutMode)
  let nextIdx =
    if idx == -1:
      0
    else:
      (idx + 1) mod cycle.len
  model.setTagLayout(tagId, cycle[nextIdx])

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
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
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
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
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
  if tag.layoutMode != LayoutMode.Scroller:
    return false
  model.setColumnWidth(pos.columnId, width)

proc toggleFocusedColumnFullWidth*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if tag.layoutMode notin {LayoutMode.Scroller, LayoutMode.VerticalScroller}:
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

proc moveFocusedWindowLeft*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if pos.colIdx > 0:
    let target = model.columnAt(pos.tagId, pos.colIdx - 1)
    let targetIdx = model.windowCountForColumn(target)
    return model.preserveMovedFocus(
      pos.tagId,
      pos.winId,
      model.moveWindowToColumn(pos.tagId, pos.winId, target, targetIdx),
    )
  else:
    let target = model.insertColumn(pos.tagId, 0, model.defaultColumnWidth())
    return model.preserveMovedFocus(
      pos.tagId, pos.winId, model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)
    )

proc moveFocusedWindowRight*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columnCount = model.columnCountForTag(pos.tagId)
  if pos.colIdx < columnCount - 1:
    return model.preserveMovedFocus(
      pos.tagId,
      pos.winId,
      model.moveWindowToColumn(
        pos.tagId, pos.winId, model.columnAt(pos.tagId, pos.colIdx + 1), 0
      ),
    )
  else:
    let target = model.addColumn(pos.tagId, model.defaultColumnWidth())
    return model.preserveMovedFocus(
      pos.tagId, pos.winId, model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)
    )

proc moveFocusedWindowUp*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found or pos.winIdx <= 0:
    return false
  model.preserveMovedFocus(
    pos.tagId,
    pos.winId,
    model.moveWindowToColumn(pos.tagId, pos.winId, pos.columnId, pos.winIdx - 1),
  )

proc moveFocusedWindowDown*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let windowCount = model.windowCountForColumn(pos.columnId)
  if pos.winIdx < 0 or pos.winIdx >= windowCount - 1:
    return false
  model.preserveMovedFocus(
    pos.tagId,
    pos.winId,
    model.moveWindowToColumn(pos.tagId, pos.winId, pos.columnId, pos.winIdx + 1),
  )

proc moveFocusedWindowUpOrWorkspace*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if pos.winIdx > 0:
    return model.moveFocusedWindowUp()
  let target = model.nearestWorkspaceSlot(-1, false)
  target != 0 and model.moveFocusedWindowToSlotAndFocus(target)

proc moveFocusedWindowDownOrWorkspace*(model: var Model): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let windowCount = model.windowCountForColumn(pos.columnId)
  if pos.winIdx >= 0 and pos.winIdx < windowCount - 1:
    return model.moveFocusedWindowDown()
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
