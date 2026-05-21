import std/[options, tables]
import ../types/[core, model]

proc loadRestoreState*(model: var Model, state: PendingRestoreState): bool =
  model.restoreActiveSlot = state.activeSlot
  model.restoreFocusedWindow = state.focusedWindow
  model.restoreTagByWindow = state.tagByWindow
  model.restoreWindows = state.windows
  model.restoreTags = state.tags
  model.restoreOutputTags = state.outputTags
  model.restoreTagOutputs = state.tagOutputs
  model.restoreScratchpadWindows = state.scratchpadWindows
  model.restoreNamedScratchpads = state.namedScratchpads
  model.restoreScratchpadSlots = state.scratchpadRestoreSlots
  model.restoreVisibleScratchpad = state.visibleScratchpad
  model.restoreIsScratchpadVisible = state.isScratchpadVisible
  model.restoreFocusHistory = state.focusHistory
  model.restoreWorkspaceHistory = state.workspaceHistory
  model.restoreResolvedWindows = initTable[ExternalWindowId, WindowId]()
  model.restoreSwallowedBy = state.swallowedBy
  model.restoreSwallowing = state.swallowing
  true

proc consumeRestoreWindow*(
    model: var Model, externalId: ExternalWindowId
): Option[RestoredWindowData] =
  if not model.restoreWindows.hasKey(externalId):
    return none(RestoredWindowData)
  result = some(model.restoreWindows[externalId])
  model.restoreWindows.del(externalId)

proc consumeRestoreTagSlot*(
    model: var Model, externalId: ExternalWindowId
): tuple[found: bool, slot: uint32] =
  if not model.restoreTagByWindow.hasKey(externalId):
    return (false, 0'u32)
  result = (true, model.restoreTagByWindow[externalId])
  model.restoreTagByWindow.del(externalId)

proc recordRestoreWindowRef*(
    model: var Model, restoredExternalId: ExternalWindowId, winId: WindowId
): bool =
  if restoredExternalId == NullExternalWindowId or winId == NullWindowId:
    return false
  model.restoreResolvedWindows[restoredExternalId] = winId
  true

proc restoredWindowRef*(model: Model, restoredExternalId: ExternalWindowId): WindowId =
  model.restoreResolvedWindows.getOrDefault(restoredExternalId, NullWindowId)

proc clearRestoreFocusedWindow*(
    model: var Model, restoredExternalId: ExternalWindowId
): bool =
  if restoredExternalId == NullExternalWindowId or
      model.restoreFocusedWindow != restoredExternalId:
    return false
  model.restoreFocusedWindow = NullExternalWindowId
  true

proc clearSettledRestoreFocus*(model: var Model): bool =
  if model.restoreWindows.len > 0 or model.restoreTagByWindow.len > 0:
    return false
  if model.restoreFocusedWindow != NullExternalWindowId:
    model.restoreFocusedWindow = NullExternalWindowId
    result = true
  if model.restoreFocusHistory.len > 0:
    model.restoreFocusHistory = @[]
    result = true
  if model.restoreWorkspaceHistory.len > 0:
    model.restoreWorkspaceHistory = @[]
    result = true
