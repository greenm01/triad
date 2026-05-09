import options, sequtils
import ../state/entity_manager
import ../types/core
import ../types/dod_model

const MaxHistoryEntries = 32

proc recordFocus*(model: var DodModel; winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  model.focusHistory.add(winId)
  while model.focusHistory.len > MaxHistoryEntries:
    model.focusHistory.delete(0)
  true

proc recordWorkspace*(model: var DodModel; tagId: TagId): bool =
  if tagId == NullTagId or model.tags.entity(tagId).isNone:
    return false
  model.workspaceHistory.keepIf(proc(id: TagId): bool = id != tagId)
  model.workspaceHistory.add(tagId)
  while model.workspaceHistory.len > MaxHistoryEntries:
    model.workspaceHistory.delete(0)
  true

proc replaceFocusHistory*(model: var DodModel; history: seq[WindowId]):
    bool =
  model.focusHistory = history
  while model.focusHistory.len > MaxHistoryEntries:
    model.focusHistory.delete(0)
  true

proc replaceWorkspaceHistory*(model: var DodModel; history: seq[TagId]):
    bool =
  model.workspaceHistory = history
  while model.workspaceHistory.len > MaxHistoryEntries:
    model.workspaceHistory.delete(0)
  true

proc removeFocusHistoryRef*(model: var DodModel; winId: WindowId): bool =
  let before = model.focusHistory.len
  model.focusHistory.keepIf(proc(id: WindowId): bool = id != winId)
  model.focusHistory.len != before

proc removeWorkspaceHistoryRef*(model: var DodModel; tagId: TagId): bool =
  let before = model.workspaceHistory.len
  model.workspaceHistory.keepIf(proc(id: TagId): bool = id != tagId)
  model.workspaceHistory.len != before
