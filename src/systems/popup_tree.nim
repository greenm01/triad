import options
import ../state/engine

proc popupRoot*(model: Model; winId: WindowId): WindowId =
  result = winId
  var current = winId
  var depth = 0
  while current != NullWindowId and depth < 64:
    let winOpt = model.windowData(current)
    if winOpt.isNone:
      return result
    let parentExternalId = winOpt.get().parentExternalId
    if parentExternalId == NullExternalWindowId:
      return current
    let parent = model.windowForExternal(parentExternalId)
    if parent == NullWindowId:
      return current
    result = parent
    current = parent
    inc depth

proc samePopupRoot*(model: Model; first, second: WindowId): bool =
  first != NullWindowId and second != NullWindowId and
    model.popupRoot(first) == model.popupRoot(second)

proc popupTreeLayoutFocus*(model: Model; winId: WindowId): WindowId =
  if winId == NullWindowId:
    return NullWindowId
  model.popupRoot(winId)

proc lastFocusedInPopupTree*(
    model: Model; root: WindowId; tagId: TagId): WindowId =
  if root == NullWindowId:
    return NullWindowId
  for candidate in model.focusHistoryIdsReverse():
    let winOpt = model.windowData(candidate)
    if winOpt.isNone or winOpt.get().isMinimized:
      continue
    if tagId != NullTagId and
        model.placementForWindowOnTag(tagId, candidate).isNone:
      continue
    if model.popupRoot(candidate) == root:
      return candidate
  NullWindowId
