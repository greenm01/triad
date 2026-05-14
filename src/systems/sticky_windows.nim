import std/options
import ../state/engine

proc isLocalFocusable(win: WindowData): bool =
  win.windowAdmitted() and not win.isMinimized and not win.isSticky

proc tagHasLocalFocusableWindow(model: Model, tagId: TagId): bool =
  for _, win in model.windowsOnTagWithId(tagId):
    if win.isLocalFocusable():
      return true
  false

proc stickySourceColumn(
    model: Model, winId: WindowId
): tuple[found: bool, column: ColumnData] =
  for tagId, _, placement in model.placementsWithId():
    if placement.windowId == winId:
      let columnOpt = model.columnData(placement.columnId)
      if columnOpt.isSome:
        return (true, columnOpt.get())
  (false, ColumnData())

proc addStickyPlacement(model: var Model, tagId: TagId, winId: WindowId): bool =
  if tagId == NullTagId or winId == NullWindowId:
    return false
  if model.placementForWindowOnTag(tagId, winId).isSome:
    return false

  let source = model.stickySourceColumn(winId)
  let columnId =
    if source.found:
      model.addColumn(
        tagId, source.column.widthProportion, source.column.isFullWidth,
        source.column.scrollerSingleProportion,
      )
    else:
      model.addColumn(tagId, model.defaultColumnWidth())
  if columnId == NullColumnId:
    return false
  model.moveWindowToColumn(tagId, winId, columnId, model.windowCountForColumn(columnId))

proc syncStickyWindow*(model: var Model, winId: WindowId, sourceTag = NullTagId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().windowAdmitted() or not winOpt.get().isSticky:
    return false

  for tagId, _ in model.tagsWithId():
    let hadPlacement = model.placementForWindowOnTag(tagId, winId).isSome
    if model.addStickyPlacement(tagId, winId):
      result = true
    let currentTag = model.tagData(tagId)
    if currentTag.isSome and currentTag.get().focusedWindow == NullWindowId and
        not model.tagHasLocalFocusableWindow(tagId):
      result = model.setTagFocus(tagId, winId) or result
    elif not hadPlacement and tagId == sourceTag:
      result = model.setTagFocus(tagId, winId) or result

proc syncStickyWindowsForWorkspace*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  var stickyWindows: seq[WindowId] = @[]
  for winId, win in model.windowsWithId():
    if win.windowAdmitted() and win.isSticky:
      stickyWindows.add(winId)
  for winId in stickyWindows:
    result = model.syncStickyWindow(winId, tagId) or result
