import options
import dod_focus
import dod_workspaces
import ../state/engine
from ../types/legacy_model import LayoutMode, MasterStack, Scroller,
  VerticalScroller

proc focusedPosition(model: DodModel):
    tuple[found: bool, tagId: TagId, winId: WindowId, columnId: ColumnId,
      colIdx, winIdx: int] =
  let tagId = model.activeTag
  let winId = model.focusedOnActiveTag()
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, tagId, winId, NullColumnId, -1, -1)
  let placement = placementOpt.get()
  let colIdx = int(model.columnIndexForTag(tagId, placement.columnId)) - 1
  if colIdx < 0:
    return (false, tagId, winId, NullColumnId, -1, -1)
  (
    true,
    tagId,
    winId,
    placement.columnId,
    colIdx,
    int(placement.windowIdx) - 1
  )

proc removeWindowFromAllTagsAndRefreshFocus*(
    model: var DodModel; winId: WindowId): bool =
  let slots = model.sortedSlots()
  for slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId != NullTagId and model.removeWindowFromTag(tagId, winId):
      discard model.recomputeVisibleFocus(tagId)
      result = true

proc addPlacedWindowColumn*(
    model: var DodModel; tagId: TagId; winId: WindowId;
    index = high(int)): ColumnId =
  result = model.insertColumn(tagId, index, model.dodDefaultColumnWidth())
  discard model.moveWindowToColumn(tagId, winId, result, 0)

proc setLayoutForSlot*(
    model: var DodModel; slot: uint32; mode: LayoutMode): bool =
  let targetSlot =
    if slot != 0: slot
    else: model.activeWorkspaceSlot()
  let tagId = model.ensureWorkspaceSlot(targetSlot)
  tagId != NullTagId and model.setTagLayout(tagId, mode)

proc switchLayout*(model: var DodModel): bool =
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let cycle = model.dodLayoutCycle()
  let idx = cycle.find(tagOpt.get().layoutMode)
  let nextIdx =
    if idx == -1: 0
    else: (idx + 1) mod cycle.len
  model.setTagLayout(tagId, cycle[nextIdx])

proc setMasterCount*(model: var DodModel; count: int): bool =
  model.setTagMasterCount(model.activeTag, count)

proc adjustMasterCount*(model: var DodModel; delta: int): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  model.setTagMasterCount(model.activeTag, tagOpt.get().masterCount + delta)

proc setMasterRatio*(model: var DodModel; ratio: float32): bool =
  model.setTagMasterRatio(model.activeTag, ratio)

proc adjustMasterRatio*(model: var DodModel; delta: float32): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  model.setTagMasterRatio(
    model.activeTag, tagOpt.get().masterSplitRatio + delta)

proc resizeWidth*(model: var DodModel; delta: float32): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  case tag.layoutMode
  of Scroller:
    let column = model.column(pos.columnId).get()
    model.setColumnWidth(pos.columnId, column.widthProportion + delta)
  of VerticalScroller:
    let win = model.windowData(pos.winId).get()
    model.setWindowWidthProportion(pos.winId, win.widthProportion + delta)
  of MasterStack:
    model.setTagMasterRatio(pos.tagId, tag.masterSplitRatio + delta)
  else:
    false

proc resizeHeight*(model: var DodModel; delta: float32): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  case tag.layoutMode
  of VerticalScroller:
    let column = model.column(pos.columnId).get()
    model.setColumnWidth(pos.columnId, column.widthProportion + delta)
  of Scroller:
    let win = model.windowData(pos.winId).get()
    model.setWindowHeightProportion(pos.winId, win.heightProportion + delta)
  else:
    false

proc setFocusedColumnWidth*(model: var DodModel; width: float32): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let tag = model.tagData(pos.tagId).get()
  if tag.layoutMode != Scroller:
    return false
  model.setColumnWidth(pos.columnId, width)

proc moveFocusedWindowToSlot*(
    model: var DodModel; targetSlot: uint32): bool =
  if targetSlot == 0:
    return false
  let sourceTag = model.activeTag
  let focused = model.focusedOnActiveTag()
  if sourceTag == NullTagId or focused == NullWindowId:
    return false
  let targetTag = model.ensureWorkspaceSlot(targetSlot)
  if targetTag == NullTagId:
    return false

  discard model.removeWindowFromAllTagsAndRefreshFocus(focused)
  discard model.addPlacedWindowColumn(targetTag, focused)
  discard model.setTagFocus(targetTag, focused)
  if model.overviewActive:
    model.activeTag = targetTag
    model.activeSlot = targetSlot
    model.recordWorkspace(targetTag)
  model.refreshVisibleWorkspaceSlots()
  true

proc moveFocusedWindowToSlotAndFocus*(
    model: var DodModel; targetSlot: uint32): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false
  if not model.moveFocusedWindowToSlot(targetSlot):
    return false
  model.focusWindow(focused)

proc swapFocusedWindowToSlot*(
    model: var DodModel; targetSlot: uint32): bool =
  let activeTag = model.activeTag
  let activeFocused = model.focusedOnActiveTag()
  let targetTag = model.ensureWorkspaceSlot(targetSlot)
  if activeTag == NullTagId or activeFocused == NullWindowId or
      targetTag == NullTagId:
    return false

  let targetTagData = model.tagData(targetTag).get()
  let targetFocused = targetTagData.focusedWindow
  if targetFocused == NullWindowId or
      model.placementForWindowOnTag(targetTag, targetFocused).isNone:
    return model.moveFocusedWindowToSlot(targetSlot)

  if model.swapPlacedWindows(
      activeTag, activeFocused, targetTag, targetFocused):
    discard model.setTagFocus(activeTag, targetFocused)
    discard model.setTagFocus(targetTag, activeFocused)
    return true
  false

proc moveFocusedWindowLeft*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columns = model.columnsForTag(pos.tagId)
  if pos.colIdx > 0:
    let target = columns[pos.colIdx - 1]
    let targetIdx = model.windowsForColumn(target).len
    model.moveWindowToColumn(pos.tagId, pos.winId, target, targetIdx)
  else:
    let target = model.insertColumn(
      pos.tagId, 0, model.dodDefaultColumnWidth())
    model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)

proc moveFocusedWindowRight*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columns = model.columnsForTag(pos.tagId)
  if pos.colIdx < columns.len - 1:
    model.moveWindowToColumn(pos.tagId, pos.winId, columns[pos.colIdx + 1], 0)
  else:
    let target = model.addColumn(pos.tagId, model.dodDefaultColumnWidth())
    model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)

proc moveFocusedWindowUp*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found or pos.winIdx <= 0:
    return false
  model.moveWindowToColumn(pos.tagId, pos.winId, pos.columnId, pos.winIdx - 1)

proc moveFocusedWindowDown*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let windows = model.windowsForColumn(pos.columnId)
  if pos.winIdx < 0 or pos.winIdx >= windows.len - 1:
    return false
  model.moveWindowToColumn(pos.tagId, pos.winId, pos.columnId, pos.winIdx + 1)

proc moveFocusedWindowUpOrWorkspace*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if pos.winIdx > 0:
    return model.moveFocusedWindowUp()
  let target = model.nearestWorkspaceSlot(-1, false)
  target != 0 and model.moveFocusedWindowToSlotAndFocus(target)

proc moveFocusedWindowDownOrWorkspace*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let windows = model.windowsForColumn(pos.columnId)
  if pos.winIdx >= 0 and pos.winIdx < windows.len - 1:
    return model.moveFocusedWindowDown()
  let target = model.nearestWorkspaceSlot(1, false)
  target != 0 and model.moveFocusedWindowToSlotAndFocus(target)

proc moveFocusedColumnLeft*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  pos.found and pos.colIdx > 0 and
    model.moveColumn(pos.tagId, pos.colIdx, pos.colIdx - 1)

proc moveFocusedColumnRight*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  let columns = model.columnsForTag(pos.tagId)
  pos.found and pos.colIdx < columns.len - 1 and
    model.moveColumn(pos.tagId, pos.colIdx, pos.colIdx + 1)

proc moveFocusedColumnToFirst*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  pos.found and pos.colIdx > 0 and model.moveColumn(pos.tagId, pos.colIdx, 0)

proc moveFocusedColumnToLast*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  let columns = model.columnsForTag(pos.tagId)
  pos.found and pos.colIdx < columns.len - 1 and
    model.moveColumn(pos.tagId, pos.colIdx, columns.len - 1)

proc consumeNextColumnWindow*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columns = model.columnsForTag(pos.tagId)
  if pos.colIdx >= columns.len - 1:
    return false
  let nextColumn = columns[pos.colIdx + 1]
  let nextWindows = model.windowsForColumn(nextColumn)
  if nextWindows.len == 0:
    return false
  let targetIdx = model.windowsForColumn(pos.columnId).len
  model.moveWindowToColumn(pos.tagId, nextWindows[0], pos.columnId, targetIdx)

proc expelFocusedWindow*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  if model.windowsForColumn(pos.columnId).len <= 1:
    return false
  let target = model.insertColumn(
    pos.tagId, pos.colIdx + 1, model.dodDefaultColumnWidth())
  model.moveWindowToColumn(pos.tagId, pos.winId, target, 0)

proc zoomFocusedWindow*(model: var DodModel): bool =
  let pos = model.focusedPosition()
  if not pos.found:
    return false
  let columns = model.columnsForTag(pos.tagId)
  if columns.len == 0:
    return false
  let firstWindows = model.windowsForColumn(columns[0])
  if firstWindows.len == 0:
    return false
  let master = firstWindows[0]
  if master == pos.winId:
    return false
  model.swapPlacedWindows(pos.tagId, master, pos.tagId, pos.winId)
