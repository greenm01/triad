import options
import ../types/shell_snapshot
from ../types/runtime_values import LayoutMode, WindowId

proc layoutSupportsMaximize*(mode: LayoutMode): bool =
  mode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc workspaceForTag(
    snapshot: ShellSnapshot; tagId: uint32): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == tagId:
      return some(workspace)
  none(ShellWorkspace)

proc windowById*(snapshot: ShellSnapshot; winId: WindowId):
    Option[ShellWindow] =
  for win in snapshot.windows:
    if win.id == winId:
      return some(win)
  none(ShellWindow)

proc windowOnActiveWorkspace*(
    snapshot: ShellSnapshot; win: ShellWindow): bool =
  win.tagId.isSome and win.tagId.get() == snapshot.activeTag

proc windowLayoutSupportsMaximize*(
    snapshot: ShellSnapshot; win: ShellWindow): bool =
  if win.tagId.isNone:
    return false
  let workspace = snapshot.workspaceForTag(win.tagId.get())
  workspace.isSome and workspace.get().layoutMode.layoutSupportsMaximize()

proc effectiveMaximized*(
    snapshot: ShellSnapshot; win: ShellWindow; focusedId: WindowId): bool =
  if not win.isMaximized or win.isMinimized or win.isFloating:
    return false
  if snapshot.overviewActive or not snapshot.windowLayoutSupportsMaximize(win):
    return false

  let focusedWin = snapshot.windowById(focusedId)
  let overlayFocus = focusedWin.isSome and focusedWin.get().isFloating
  if overlayFocus:
    snapshot.windowOnActiveWorkspace(win)
  else:
    win.id == focusedId
