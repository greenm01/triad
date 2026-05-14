import std/[options, sequtils]
import ../state/entity_manager
import ../types/[core, model]

const MaxHistoryEntries = 32

proc commitRecentFocus*(model: var Model, winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  model.recentWindowHistory.keepIf(
    proc(id: WindowId): bool =
      id != winId
  )
  model.recentWindowHistory.add(winId)
  while model.recentWindowHistory.len > MaxHistoryEntries:
    model.recentWindowHistory.delete(0)
  if model.pendingRecentFocusWindow == winId:
    model.pendingRecentFocusWindow = NullWindowId
    model.pendingRecentFocusElapsedMs = 0
  true

proc scheduleRecentFocus(model: var Model, winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  if model.recentWindowHistory.find(winId) == -1 or model.recentWindows.debounceMs <= 0:
    return model.commitRecentFocus(winId)
  model.pendingRecentFocusWindow = winId
  model.pendingRecentFocusElapsedMs = 0
  true

proc recordFocus*(model: var Model, winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  model.focusHistory.keepIf(
    proc(id: WindowId): bool =
      id != winId
  )
  model.focusHistory.add(winId)
  while model.focusHistory.len > MaxHistoryEntries:
    model.focusHistory.delete(0)
  discard model.scheduleRecentFocus(winId)
  true

proc recordWorkspace*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId or model.tags.entity(tagId).isNone:
    return false
  model.workspaceHistory.keepIf(
    proc(id: TagId): bool =
      id != tagId
  )
  model.workspaceHistory.add(tagId)
  while model.workspaceHistory.len > MaxHistoryEntries:
    model.workspaceHistory.delete(0)
  true

proc replaceFocusHistory*(model: var Model, history: seq[WindowId]): bool =
  model.focusHistory = history
  model.recentWindowHistory = history
  while model.focusHistory.len > MaxHistoryEntries:
    model.focusHistory.delete(0)
  while model.recentWindowHistory.len > MaxHistoryEntries:
    model.recentWindowHistory.delete(0)
  true

proc replaceWorkspaceHistory*(model: var Model, history: seq[TagId]): bool =
  model.workspaceHistory = history
  while model.workspaceHistory.len > MaxHistoryEntries:
    model.workspaceHistory.delete(0)
  true

proc removeFocusHistoryRef*(model: var Model, winId: WindowId): bool =
  let before = model.focusHistory.len
  model.focusHistory.keepIf(
    proc(id: WindowId): bool =
      id != winId
  )
  model.recentWindowHistory.keepIf(
    proc(id: WindowId): bool =
      id != winId
  )
  if model.pendingRecentFocusWindow == winId:
    model.pendingRecentFocusWindow = NullWindowId
    model.pendingRecentFocusElapsedMs = 0
  model.focusHistory.len != before

proc removeWorkspaceHistoryRef*(model: var Model, tagId: TagId): bool =
  let before = model.workspaceHistory.len
  model.workspaceHistory.keepIf(
    proc(id: TagId): bool =
      id != tagId
  )
  model.workspaceHistory.len != before
