import std/options
import ../core/shell_focus
import ../types/shell_snapshot
from ../types/runtime_values import WindowRuleIdleInhibitMode

proc workspaceByTagId(snapshot: ShellSnapshot, tagId: uint32): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == tagId:
      return some(workspace)
  none(ShellWorkspace)

proc columnContainsWindow(workspace: ShellWorkspace, winId: uint32): bool =
  for column in workspace.columns:
    for candidate in column.windows:
      if candidate == winId:
        return true
  false

proc windowVisibleOnOutput(snapshot: ShellSnapshot, win: ShellWindow): bool =
  if win.isMinimized:
    return false
  if win.id == snapshot.activeScratchpadWindow:
    return true
  if win.tagId.isNone:
    return false
  let workspaceOpt = snapshot.workspaceByTagId(win.tagId.get())
  if workspaceOpt.isNone or not workspaceOpt.get().isOutputVisible:
    return false
  if win.isFloating:
    return true
  workspaceOpt.get().columnContainsWindow(win.id)

proc idleInhibitActive*(snapshot: ShellSnapshot): bool =
  if snapshot.sessionLocked or snapshot.layerFocusExclusive:
    return false

  let focused = snapshot.focusedWindowId()
  for win in snapshot.windows:
    case win.idleInhibitMode
    of WindowRuleIdleInhibitMode.IdleInhibitNone:
      discard
    of WindowRuleIdleInhibitMode.IdleInhibitFocused:
      if not win.isMinimized and
          (win.id == focused or win.id == snapshot.activeScratchpadWindow):
        return true
    of WindowRuleIdleInhibitMode.IdleInhibitVisible:
      if snapshot.windowVisibleOnOutput(win):
        return true
  false
