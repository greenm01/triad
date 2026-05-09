import options, sequtils
import dod_workspaces
import ../state/engine
from ../types/legacy_model import Direction, DirDown, DirLeft, DirRight, DirUp

proc recordFocus*(model: var DodModel; winId: WindowId) =
  if winId == NullWindowId or model.windowData(winId).isNone:
    return
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  model.focusHistory.add(winId)
  while model.focusHistory.len > 32:
    model.focusHistory.delete(0)

proc recordWorkspace*(model: var DodModel; tagId: TagId) =
  if tagId == NullTagId or model.tagData(tagId).isNone:
    return
  model.workspaceHistory.keepIf(proc(id: TagId): bool = id != tagId)
  model.workspaceHistory.add(tagId)
  while model.workspaceHistory.len > 32:
    model.workspaceHistory.delete(0)

proc windowOnTag(model: DodModel; tagId: TagId; winId: WindowId): bool =
  model.placementForWindowOnTag(tagId, winId).isSome

proc focusedOnActiveTag*(model: DodModel): WindowId =
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

proc firstFocusableWindow(model: DodModel; tagId: TagId): WindowId =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isMinimized:
      return winId
  NullWindowId

proc recomputeVisibleFocus*(model: var DodModel; tagId: TagId): WindowId =
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

proc tagForWindow*(model: DodModel; winId: WindowId): TagId =
  if model.activeTag != NullTagId and model.windowOnTag(model.activeTag, winId):
    return model.activeTag

  let position = model.firstWindowPosition(winId)
  if position.found:
    return position.tagId
  NullTagId

proc isFocusableWindow*(model: DodModel; winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  winOpt.isSome and not winOpt.get().isMinimized

proc focusWindow*(model: var DodModel; winId: WindowId): bool =
  if model.windowData(winId).isNone:
    return false
  let tagId = model.tagForWindow(winId)
  if tagId == NullTagId:
    return false
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false

  discard model.setWindowMinimized(winId, false)
  model.activeTag = tagId
  model.activeSlot = tagOpt.get().slot
  model.refreshVisibleWorkspaceSlots()
  model.recordWorkspace(tagId)
  discard model.setTagFocus(tagId, winId)
  model.recordFocus(winId)
  true

proc focusWorkspaceSlot*(model: var DodModel; slot: uint32): bool =
  let tagId = model.ensureWorkspaceSlot(slot)
  if tagId == NullTagId:
    return false
  model.activeTag = tagId
  model.activeSlot = slot
  model.refreshVisibleWorkspaceSlots()
  model.recordWorkspace(tagId)
  let focused = model.recomputeVisibleFocus(tagId)
  if focused != NullWindowId:
    model.recordFocus(focused)
  true

proc focusWorkspaceIndex*(model: var DodModel; index: uint32): bool =
  let slot = model.workspaceSlotForClampedIndex(index)
  slot != 0 and model.focusWorkspaceSlot(slot)

proc focusExternalWindow*(model: var DodModel; externalId: ExternalWindowId):
    bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.focusWindow(winId)

proc focusMostRecentWindow*(model: var DodModel): bool =
  var candidates: seq[WindowId] = @[]
  for candidate in model.focusHistory:
    if model.isFocusableWindow(candidate) and
        model.tagForWindow(candidate) != NullTagId:
      candidates.add(candidate)
  model.focusHistory = candidates
  if candidates.len == 0:
    return false
  model.focusWindow(candidates[^1])

proc isRestorableWorkspace(model: DodModel; tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  tagOpt.get().slot <= model.dodDefaultWorkspaceCount() or
    model.tagHasFocusableWindow(tagId)

proc focusMostRecentWorkspace*(model: var DodModel): bool =
  var candidates: seq[TagId] = @[]
  for candidate in model.workspaceHistory:
    if model.isRestorableWorkspace(candidate):
      candidates.add(candidate)
  model.workspaceHistory = candidates
  if candidates.len == 0:
    return false

  for i in countdown(candidates.len - 1, 0):
    if candidates[i] != model.activeTag:
      let tagOpt = model.tagData(candidates[i])
      if tagOpt.isSome:
        return model.focusWorkspaceSlot(tagOpt.get().slot)
  false

proc focusLast*(model: var DodModel): bool =
  let current = model.focusedOnActiveTag()
  for i in countdown(model.focusHistory.len - 1, 0):
    let candidate = model.focusHistory[i]
    if candidate != current and model.isFocusableWindow(candidate):
      return model.focusWindow(candidate)
  false

proc focusableWindowsOnTag(model: DodModel; tagId: TagId): seq[WindowId] =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isMinimized:
      result.add(winId)

proc focusOverviewByStep*(model: var DodModel; step: int): bool

proc focusCycle*(model: var DodModel; step: int): bool =
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
  model.recordWorkspace(tagId)
  model.recordFocus(target)
  true

proc visibleWindowNear(
    model: DodModel; columnId: ColumnId; preferredIdx: int): WindowId =
  let windows = model.windowsForColumn(columnId)
  if windows.len == 0:
    return NullWindowId

  let idx = clamp(preferredIdx, 0, windows.len - 1)
  if model.isFocusableWindow(windows[idx]):
    return windows[idx]

  for distance in 1 ..< windows.len:
    let before = idx - distance
    if before >= 0 and model.isFocusableWindow(windows[before]):
      return windows[before]
    let after = idx + distance
    if after < windows.len and model.isFocusableWindow(windows[after]):
      return windows[after]
  NullWindowId

proc findWindowPosition(model: DodModel; tagId: TagId; winId: WindowId):
    tuple[found: bool, colIdx, winIdx: int, columnId: ColumnId] =
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, -1, -1, NullColumnId)
  let placement = placementOpt.get()
  let colIdx = int(model.columnIndexForTag(tagId, placement.columnId)) - 1
  if colIdx < 0:
    return (false, -1, -1, NullColumnId)
  (true, colIdx, int(placement.windowIdx) - 1, placement.columnId)

proc focusColumnByStep*(model: var DodModel; step: int): bool =
  if step == 0:
    return false
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return false

  let columns = model.columnsForTag(tagId)
  var colIdx = pos.colIdx + step
  while colIdx >= 0 and colIdx < columns.len:
    let target = model.visibleWindowNear(columns[colIdx], pos.winIdx)
    if target != NullWindowId:
      return model.focusWindow(target)
    colIdx += step
  false

proc focusColumnAtEdge*(model: var DodModel; first: bool): bool =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  let preferredIdx = if pos.found: pos.winIdx else: 0
  let columns = model.columnsForTag(tagId)

  if first:
    for columnId in columns:
      let target = model.visibleWindowNear(columnId, preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  else:
    for i in countdown(columns.len - 1, 0):
      let target = model.visibleWindowNear(columns[i], preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  false

proc focusWindowOrWorkspace*(model: var DodModel; direction: int): bool =
  if direction == 0:
    return false

  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if pos.found:
    let windows = model.windowsForColumn(pos.columnId)
    var winIdx = pos.winIdx + direction
    while winIdx >= 0 and winIdx < windows.len:
      if model.isFocusableWindow(windows[winIdx]):
        return model.focusWindow(windows[winIdx])
      winIdx += direction

  let target = model.nearestWorkspaceSlot(direction, false)
  target != 0 and model.focusWorkspaceSlot(target)

proc overviewWindows(model: DodModel): seq[WindowId] =
  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    for winId, win in model.windowsOnTagWithId(tagId):
      if not win.isMinimized:
        result.add(winId)

proc focusOverviewByStep*(model: var DodModel; step: int): bool =
  let windows = model.overviewWindows()
  if windows.len == 0:
    return false

  let current = model.focusedOnActiveTag()
  var idx = windows.find(current)
  if idx == -1:
    idx = 0
  else:
    idx = (idx + step + windows.len) mod windows.len
  model.focusWindow(windows[idx])

proc focusByDirection*(model: var DodModel; direction: Direction): bool =
  if model.overviewActive:
    case direction
    of DirLeft:
      return model.focusColumnByStep(-1)
    of DirRight:
      return model.focusColumnByStep(1)
    of DirUp:
      return model.focusWindowOrWorkspace(-1)
    of DirDown:
      return model.focusWindowOrWorkspace(1)

  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return false

  let columns = model.columnsForTag(tagId)
  var target = NullWindowId
  case direction
  of DirLeft:
    var i = pos.colIdx - 1
    while i >= 0 and target == NullWindowId:
      target = model.visibleWindowNear(columns[i], pos.winIdx)
      dec i
  of DirRight:
    var i = pos.colIdx + 1
    while i < columns.len and target == NullWindowId:
      target = model.visibleWindowNear(columns[i], pos.winIdx)
      inc i
  of DirUp:
    let windows = model.windowsForColumn(pos.columnId)
    if pos.winIdx > 0:
      target = windows[pos.winIdx - 1]
  of DirDown:
    let windows = model.windowsForColumn(pos.columnId)
    if pos.winIdx >= 0 and pos.winIdx < windows.len - 1:
      target = windows[pos.winIdx + 1]

  if target != NullWindowId and model.isFocusableWindow(target):
    return model.focusWindow(target)
  false

proc collapseEmptyActiveDynamicWorkspace*(model: var DodModel): bool =
  let oldSlot = model.activeWorkspaceSlot()
  if oldSlot == 0 or oldSlot <= model.dodDefaultWorkspaceCount():
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
