import options, tables
import ../types/core
import ../types/dod_model

proc loadRestoreState*(model: var DodModel; state: DodLiveRestoreState):
    bool =
  model.restoreActiveSlot = state.activeSlot
  model.restoreFocusedWindow = state.focusedWindow
  model.restoreTagByWindow = state.tagByWindow
  model.restoreWindows = state.windows
  model.restoreTags = state.tags
  model.restoreOutputTags = state.outputTags
  model.restoreScratchpadWindows = state.scratchpadWindows
  model.restoreNamedScratchpads = state.namedScratchpads
  model.restoreVisibleScratchpad = state.visibleScratchpad
  model.restoreIsScratchpadVisible = state.isScratchpadVisible
  model.restoreFocusHistory = state.focusHistory
  model.restoreWorkspaceHistory = state.workspaceHistory
  true

proc consumeRestoreWindow*(
    model: var DodModel; externalId: ExternalWindowId):
    Option[RestoredWindowData] =
  if not model.restoreWindows.hasKey(externalId):
    return none(RestoredWindowData)
  result = some(model.restoreWindows[externalId])
  model.restoreWindows.del(externalId)

proc consumeRestoreTagSlot*(model: var DodModel; externalId: ExternalWindowId):
    tuple[found: bool, slot: uint32] =
  if not model.restoreTagByWindow.hasKey(externalId):
    return (false, 0'u32)
  result = (true, model.restoreTagByWindow[externalId])
  model.restoreTagByWindow.del(externalId)

proc rewriteRestoreFocusRefs*(
    model: var DodModel; restoredExternalId, externalId: ExternalWindowId):
    bool =
  if restoredExternalId == externalId:
    return false
  for item in model.restoreFocusHistory.mitems:
    if item == restoredExternalId:
      item = externalId
      result = true

proc clearRestoreFocusedWindow*(
    model: var DodModel; restoredExternalId: ExternalWindowId): bool =
  if restoredExternalId == NullExternalWindowId or
      model.restoreFocusedWindow != restoredExternalId:
    return false
  model.restoreFocusedWindow = NullExternalWindowId
  true
