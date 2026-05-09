import options
import workspaces
import ../layouts/grid_math
import ../state/engine
from ../types/runtime_values import Direction

proc windowOnTag(model: Model; tagId: TagId; winId: WindowId): bool =
  model.placementForWindowOnTag(tagId, winId).isSome

proc focusedOnActiveTag*(model: Model): WindowId =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return NullWindowId
  let focused = tagOpt.get().focusedWindow
  let winOpt = model.windowData(focused)
  if focused != NullWindowId and winOpt.isSome and
      not winOpt.get().isMinimized and
      model.windowOnTag(model.activeTag, focused):
    return focused
  NullWindowId

proc firstFocusableWindow(model: Model; tagId: TagId): WindowId =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isMinimized:
      return winId
  NullWindowId

proc recomputeVisibleFocus*(model: var Model; tagId: TagId): WindowId =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return NullWindowId
  let focused = tagOpt.get().focusedWindow
  let winOpt = model.windowData(focused)
  if focused != NullWindowId and winOpt.isSome and
      not winOpt.get().isMinimized and model.windowOnTag(tagId, focused):
    return focused

  result = model.firstFocusableWindow(tagId)
  discard model.setTagFocus(tagId, result)

proc tagForWindow*(model: Model; winId: WindowId): TagId =
  if model.activeTag != NullTagId and model.windowOnTag(model.activeTag, winId):
    return model.activeTag

  let position = model.firstWindowPosition(winId)
  if position.found:
    return position.tagId
  NullTagId

proc isFocusableWindow*(model: Model; winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  winOpt.isSome and not winOpt.get().isMinimized

proc focusWindow*(model: var Model; winId: WindowId): bool =
  if model.windowData(winId).isNone:
    return false
  let tagId = model.tagForWindow(winId)
  if tagId == NullTagId:
    return false
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false

  discard model.setWindowMinimized(winId, false)
  discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()
  discard model.recordWorkspace(tagId)
  discard model.setTagFocus(tagId, winId)
  discard model.recordFocus(winId)
  true

proc focusWorkspaceSlot*(model: var Model; slot: uint32): bool =
  let tagId = model.ensureWorkspaceSlot(slot)
  if tagId == NullTagId:
    return false
  discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()
  discard model.recordWorkspace(tagId)
  let focused = model.recomputeVisibleFocus(tagId)
  if focused != NullWindowId:
    discard model.recordFocus(focused)
  true

proc focusWorkspaceIndex*(model: var Model; index: uint32): bool =
  let slot = model.workspaceSlotForClampedIndex(index)
  slot != 0 and model.focusWorkspaceSlot(slot)

proc focusExternalWindow*(model: var Model; externalId: ExternalWindowId):
    bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.focusWindow(winId)

proc focusMostRecentWindow*(model: var Model): bool =
  var candidates: seq[WindowId] = @[]
  for candidate in model.focusHistoryIds():
    if model.isFocusableWindow(candidate) and
        model.tagForWindow(candidate) != NullTagId:
      candidates.add(candidate)
  discard model.replaceFocusHistory(candidates)
  if candidates.len == 0:
    return false
  model.focusWindow(candidates[^1])

proc isRestorableWorkspace(model: Model; tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  tagOpt.get().slot <= model.defaultWorkspaceCount() or
    model.tagHasFocusableWindow(tagId)

proc focusMostRecentWorkspace*(model: var Model): bool =
  var candidates: seq[TagId] = @[]
  for candidate in model.workspaceHistoryIds():
    if model.isRestorableWorkspace(candidate):
      candidates.add(candidate)
  discard model.replaceWorkspaceHistory(candidates)
  if candidates.len == 0:
    return false

  for i in countdown(candidates.len - 1, 0):
    if candidates[i] != model.activeTag:
      let tagOpt = model.tagData(candidates[i])
      if tagOpt.isSome:
        return model.focusWorkspaceSlot(tagOpt.get().slot)
  false

proc focusLast*(model: var Model): bool =
  let current = model.focusedOnActiveTag()
  for candidate in model.focusHistoryIdsReverse():
    if candidate != current and model.isFocusableWindow(candidate):
      return model.focusWindow(candidate)
  false

proc focusableWindowsOnTag(model: Model; tagId: TagId): seq[WindowId] =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isMinimized:
      result.add(winId)

proc focusOverviewByStep*(model: var Model; step: int): bool

proc focusCycle*(model: var Model; step: int): bool =
  if model.overviewActive:
    return model.focusOverviewByStep(step)
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let windows = model.focusableWindowsOnTag(tagId)
  if windows.len == 0:
    return false

  let idx = windows.find(tagOpt.get().focusedWindow)
  let nextIdx =
    if idx == -1: 0
    else: (idx + step + windows.len) mod windows.len
  let target = windows[nextIdx]
  discard model.setTagFocus(tagId, target)
  discard model.recordWorkspace(tagId)
  discard model.recordFocus(target)
  true

proc visibleWindowNear(
    model: Model; columnId: ColumnId; preferredIdx: int): WindowId =
  let count = model.windowCountForColumn(columnId)
  if count == 0:
    return NullWindowId

  let idx = clamp(preferredIdx, 0, count - 1)
  let preferred = model.windowAt(columnId, idx)
  if model.isFocusableWindow(preferred):
    return preferred

  for distance in 1 ..< count:
    let before = idx - distance
    let beforeWin = model.windowAt(columnId, before)
    if beforeWin != NullWindowId and model.isFocusableWindow(beforeWin):
      return beforeWin
    let after = idx + distance
    let afterWin = model.windowAt(columnId, after)
    if afterWin != NullWindowId and model.isFocusableWindow(afterWin):
      return afterWin
  NullWindowId

proc findWindowPosition(model: Model; tagId: TagId; winId: WindowId):
    tuple[found: bool; colIdx, winIdx: int; columnId: ColumnId] =
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, -1, -1, NullColumnId)
  let placement = placementOpt.get()
  let colIdx = int(model.columnIndexForTag(tagId, placement.columnId)) - 1
  if colIdx < 0:
    return (false, -1, -1, NullColumnId)
  (true, colIdx, int(placement.windowIdx) - 1, placement.columnId)

proc focusColumnByStep*(model: var Model; step: int): bool =
  if step == 0:
    return false
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return false

  let columnCount = model.columnCountForTag(tagId)
  var colIdx = pos.colIdx + step
  while colIdx >= 0 and colIdx < columnCount:
    let target = model.visibleWindowNear(
      model.columnAt(tagId, colIdx), pos.winIdx)
    if target != NullWindowId:
      return model.focusWindow(target)
    colIdx += step
  false

proc focusColumnAtEdge*(model: var Model; first: bool): bool =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  let preferredIdx = if pos.found: pos.winIdx else: 0
  let columnCount = model.columnCountForTag(tagId)

  if first:
    for idx in 0 ..< columnCount:
      let columnId = model.columnAt(tagId, idx)
      let target = model.visibleWindowNear(columnId, preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  else:
    for i in countdown(columnCount - 1, 0):
      let target = model.visibleWindowNear(model.columnAt(tagId, i), preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  false

proc focusWindowOrWorkspace*(model: var Model; direction: int): bool =
  if direction == 0:
    return false

  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if pos.found:
    let count = model.windowCountForColumn(pos.columnId)
    var winIdx = pos.winIdx + direction
    while winIdx >= 0 and winIdx < count:
      let candidate = model.windowAt(pos.columnId, winIdx)
      if model.isFocusableWindow(candidate):
        return model.focusWindow(candidate)
      winIdx += direction

  let target = model.nearestWorkspaceSlot(direction, false)
  target != 0 and model.focusWorkspaceSlot(target)

proc focusOverviewByStep*(model: var Model; step: int): bool =
  let windows = model.overviewWindowIds()
  if windows.len == 0:
    return false

  let current = model.focusedOnActiveTag()
  var idx = windows.find(current)
  if idx == -1:
    idx = 0
  else:
    idx = (idx + step + windows.len) mod windows.len
  model.focusWindow(windows[idx])

proc focusOverviewByDelta(
    model: var Model; deltaCol, deltaRow: int): bool =
  let windows = model.overviewWindowIds()
  if windows.len == 0:
    return false

  let current = model.focusedOnActiveTag()
  var idx = windows.find(current)
  if idx == -1:
    idx = 0

  let targetIdx = gridIndexByDelta(idx, windows.len, deltaCol, deltaRow)
  if targetIdx < 0 or targetIdx == idx:
    return false
  model.focusWindow(windows[targetIdx])

proc focusByDirection*(model: var Model; direction: Direction): bool =
  if model.overviewActive:
    case direction
    of Direction.DirLeft:
      return model.focusOverviewByDelta(-1, 0)
    of Direction.DirRight:
      return model.focusOverviewByDelta(1, 0)
    of Direction.DirUp:
      return model.focusOverviewByDelta(0, -1)
    of Direction.DirDown:
      return model.focusOverviewByDelta(0, 1)

  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return false

  let columnCount = model.columnCountForTag(tagId)
  var target = NullWindowId
  case direction
  of Direction.DirLeft:
    var i = pos.colIdx - 1
    while i >= 0 and target == NullWindowId:
      target = model.visibleWindowNear(model.columnAt(tagId, i), pos.winIdx)
      dec i
  of Direction.DirRight:
    var i = pos.colIdx + 1
    while i < columnCount and target == NullWindowId:
      target = model.visibleWindowNear(model.columnAt(tagId, i), pos.winIdx)
      inc i
  of Direction.DirUp:
    if pos.winIdx > 0:
      target = model.windowAt(pos.columnId, pos.winIdx - 1)
  of Direction.DirDown:
    let count = model.windowCountForColumn(pos.columnId)
    if pos.winIdx >= 0 and pos.winIdx < count - 1:
      target = model.windowAt(pos.columnId, pos.winIdx + 1)

  if target != NullWindowId and model.isFocusableWindow(target):
    return model.focusWindow(target)
  false

proc collapseEmptyActiveDynamicWorkspace*(model: var Model): bool =
  let oldSlot = model.activeWorkspaceSlot()
  if oldSlot == 0 or oldSlot <= model.defaultWorkspaceCount():
    return false
  let oldTag = model.activeTag
  if oldTag == NullTagId or model.tagData(oldTag).isNone:
    return false
  if model.tagHasLiveWindows(oldTag):
    return false

  let fallback = model.lowerWorkspaceFallback(oldSlot)
  if fallback == 0 or fallback == oldSlot:
    return false
  model.focusWorkspaceSlot(fallback)
