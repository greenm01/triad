import std/options
import ../types/shell_snapshot
from ../types/runtime_values import LayoutMode, WindowId

proc layoutSupportsMaximize*(mode: LayoutMode): bool =
  mode in {LayoutMode.Scroller, LayoutMode.VerticalScroller}

proc workspaceForTag(snapshot: ShellSnapshot, tagId: uint32): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == tagId:
      return some(workspace)
  none(ShellWorkspace)

proc windowById*(snapshot: ShellSnapshot, winId: WindowId): Option[ShellWindow] =
  for win in snapshot.windows:
    if win.id == winId:
      return some(win)
  none(ShellWindow)

proc popupRoot*(snapshot: ShellSnapshot, winId: WindowId): WindowId =
  result = winId
  var current = winId
  var depth = 0
  while current != 0'u32 and depth < 64:
    let winOpt = snapshot.windowById(current)
    if winOpt.isNone:
      return result
    let parent = winOpt.get().parentId
    if parent == 0'u32:
      return current
    result = parent
    current = parent
    inc depth

proc windowOnActiveWorkspace*(snapshot: ShellSnapshot, win: ShellWindow): bool =
  win.tagId.isSome and win.tagId.get() == snapshot.activeTag

proc windowLayoutSupportsMaximize*(snapshot: ShellSnapshot, win: ShellWindow): bool =
  if win.tagId.isNone:
    return false
  let workspace = snapshot.workspaceForTag(win.tagId.get())
  workspace.isSome and workspace.get().layoutMode.layoutSupportsMaximize()

proc windowInFullWidthColumn*(snapshot: ShellSnapshot, win: ShellWindow): bool =
  if win.tagId.isNone:
    return false
  let workspace = snapshot.workspaceForTag(win.tagId.get())
  if workspace.isNone:
    return false
  for column in workspace.get().columns:
    if column.isFullWidth and column.windows.find(win.id) != -1:
      return true
  false

proc effectiveMaximized*(
    snapshot: ShellSnapshot, win: ShellWindow, focusedId: WindowId
): bool =
  if not win.isMaximized or win.isMinimized or win.isFloating:
    return false
  if snapshot.overviewActive or not snapshot.windowLayoutSupportsMaximize(win) or
      snapshot.windowInFullWidthColumn(win):
    return false

  let focusedWin = snapshot.windowById(focusedId)
  let overlayFocus =
    focusedWin.isSome and (focusedWin.get().isFloating or focusedWin.get().isOverlay)
  if overlayFocus:
    let root = snapshot.popupRoot(focusedId)
    if root != focusedId:
      return win.id == root
    return snapshot.windowOnActiveWorkspace(win)
  else:
    win.id == focusedId
