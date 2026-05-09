import options, strutils, tables
import dod_focus
import dod_placement
import dod_workspaces
import ../state/engine

proc addScratchpadWindow(model: var DodModel; winId: WindowId) =
  if model.scratchpadWindows.find(winId) == -1:
    model.scratchpadWindows.add(winId)

proc removeScratchpadWindow(model: var DodModel; winId: WindowId) =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.scratchpadWindows[i] == winId:
      model.scratchpadWindows.delete(i)
    else:
      inc i

proc removeNamedScratchpadRefs(model: var DodModel; winId: WindowId) =
  var deadNames: seq[string] = @[]
  for name, namedWin in model.namedScratchpads.pairs:
    if namedWin == winId:
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)

proc pruneScratchpads*(model: var DodModel) =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.hasWindow(model.scratchpadWindows[i]):
      inc i
    else:
      model.scratchpadWindows.delete(i)

  var deadNames: seq[string] = @[]
  for name, winId in model.namedScratchpads.pairs:
    if not model.hasWindow(winId):
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)

  if model.visibleScratchpad != NullWindowId and
      not model.hasWindow(model.visibleScratchpad):
    model.visibleScratchpad = NullWindowId
    model.isScratchpadVisible = false

proc moveFocusedToScratchpad*(model: var DodModel; name = ""): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false

  let activeTag = model.activeTag
  if activeTag == NullTagId or
      model.placementForWindowOnTag(activeTag, focused).isNone:
    return false

  discard model.removeWindowFromAllTagsAndRefreshFocus(focused)
  model.addScratchpadWindow(focused)
  let scratchpadName = name.strip()
  if scratchpadName.len > 0:
    model.namedScratchpads[scratchpadName] = focused
  model.visibleScratchpad = NullWindowId
  model.isScratchpadVisible = false
  true

proc showScratchpad*(model: var DodModel; winId: WindowId): bool =
  if winId == NullWindowId or not model.hasWindow(winId):
    return false
  discard model.setWindowMinimized(winId, false)
  discard model.setWindowMaximized(winId, false)
  model.addScratchpadWindow(winId)
  model.visibleScratchpad = winId
  model.isScratchpadVisible = true
  model.recordFocus(winId)
  true

proc hideScratchpad*(model: var DodModel): bool =
  model.visibleScratchpad = NullWindowId
  model.isScratchpadVisible = false
  true

proc toggleScratchpad*(model: var DodModel): bool =
  model.pruneScratchpads()
  if model.isScratchpadVisible:
    return model.hideScratchpad()
  if model.scratchpadWindows.len == 0:
    return false
  model.showScratchpad(model.scratchpadWindows[^1])

proc toggleNamedScratchpad*(model: var DodModel; name: string): bool =
  let scratchpadName = name.strip()
  if scratchpadName.len == 0:
    return false

  model.pruneScratchpads()
  if model.namedScratchpads.hasKey(scratchpadName):
    let winId = model.namedScratchpads[scratchpadName]
    if model.isScratchpadVisible and model.visibleScratchpad == winId:
      return model.hideScratchpad()
    return model.showScratchpad(winId)

  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId or model.activeTag == NullTagId or
      model.placementForWindowOnTag(model.activeTag, focused).isNone:
    return false
  if not model.moveFocusedToScratchpad(scratchpadName):
    return false
  model.showScratchpad(focused)

proc restoreScratchpad*(model: var DodModel): bool =
  model.pruneScratchpads()
  let winId =
    if model.visibleScratchpad != NullWindowId:
      model.visibleScratchpad
    elif model.scratchpadWindows.len > 0:
      model.scratchpadWindows[^1]
    else:
      NullWindowId
  if winId == NullWindowId or not model.hasWindow(winId):
    return false

  model.removeScratchpadWindow(winId)
  model.removeNamedScratchpadRefs(winId)
  model.visibleScratchpad = NullWindowId
  model.isScratchpadVisible = false

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

proc recordRestoredScratchpad*(model: var DodModel;
    restoredExternalId: ExternalWindowId; winId: WindowId) =
  if winId == NullWindowId:
    return

  if model.restoreScratchpadWindows.find(restoredExternalId) != -1:
    model.addScratchpadWindow(winId)

  for name, externalId in model.restoreNamedScratchpads.pairs:
    if externalId == restoredExternalId:
      model.namedScratchpads[name] = winId
      model.addScratchpadWindow(winId)

  if model.restoreVisibleScratchpad == restoredExternalId:
    model.visibleScratchpad = winId
    model.isScratchpadVisible = model.restoreIsScratchpadVisible
    if model.isScratchpadVisible:
      model.addScratchpadWindow(winId)
