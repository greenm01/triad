import std/[options, strutils]
import focus, placement, workspaces
import ../state/engine

proc pruneScratchpads*(model: var Model) =
  discard model.pruneScratchpadRefs()

proc moveFocusedToScratchpad*(model: var Model; name = ""): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false

  let activeTag = model.activeTag
  if activeTag == NullTagId or
      model.placementForWindowOnTag(activeTag, focused).isNone:
    return false

  discard model.removeWindowFromAllTagsAndRefreshFocus(focused)
  discard model.addScratchpadRef(focused)
  let scratchpadName = name.strip()
  if scratchpadName.len > 0:
    discard model.setNamedScratchpadRef(scratchpadName, focused)
  discard model.hideScratchpadRef()
  true

proc showScratchpad*(model: var Model; winId: WindowId): bool =
  if winId == NullWindowId or not model.hasWindow(winId):
    return false
  discard model.setWindowMinimized(winId, false)
  discard model.setWindowMaximized(winId, false)
  discard model.showScratchpadRef(winId)
  discard model.recordFocus(winId)
  true

proc hideScratchpad*(model: var Model): bool =
  model.hideScratchpadRef()

proc toggleScratchpad*(model: var Model): bool =
  model.pruneScratchpads()
  if model.scratchpadVisible():
    return model.hideScratchpad()
  let latest = model.latestScratchpadWindow()
  if latest == NullWindowId:
    return false
  model.showScratchpad(latest)

proc toggleNamedScratchpad*(model: var Model; name: string): bool =
  let scratchpadName = name.strip()
  if scratchpadName.len == 0:
    return false

  model.pruneScratchpads()
  let named = model.namedScratchpadWindow(scratchpadName)
  if named != NullWindowId:
    let winId = named
    if model.activeScratchpadWindow() == winId:
      return model.hideScratchpad()
    return model.showScratchpad(winId)

  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId or model.activeTag == NullTagId or
      model.placementForWindowOnTag(model.activeTag, focused).isNone:
    return false
  if not model.moveFocusedToScratchpad(scratchpadName):
    return false
  model.showScratchpad(focused)

proc restoreScratchpad*(model: var Model): bool =
  model.pruneScratchpads()
  let winId =
    if model.activeScratchpadWindow() != NullWindowId:
      model.activeScratchpadWindow()
    elif model.latestScratchpadWindow() != NullWindowId:
      model.latestScratchpadWindow()
    else:
      NullWindowId
  if winId == NullWindowId or not model.hasWindow(winId):
    return false

  discard model.removeScratchpadRef(winId)

  let targetSlot =
    if model.activeWorkspaceSlot() == 0: 1'u32
    else: model.activeWorkspaceSlot()
  let tagId = model.ensureWorkspaceSlot(targetSlot)
  if tagId == NullTagId:
    return false

  discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
  discard model.addPlacedWindowColumn(tagId, winId)
  discard model.setTagFocus(tagId, winId)
  model.focusWindow(winId)

proc recordRestoredScratchpad*(model: var Model;
    restoredExternalId: ExternalWindowId; winId: WindowId) =
  if winId == NullWindowId:
    return

  if model.restoredScratchpadContains(restoredExternalId):
    discard model.addScratchpadRef(winId)

  for name, externalId in model.restoreNamedScratchpadsWithId():
    if externalId == restoredExternalId:
      discard model.setNamedScratchpadRef(name, winId)

  if model.restoreVisibleScratchpadId() == restoredExternalId:
    discard model.setVisibleScratchpadRef(
      winId, model.restoreScratchpadVisible())
