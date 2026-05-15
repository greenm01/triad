import std/[options, strutils]
import focus, placement, workspaces
import ../state/engine

proc pruneScratchpads*(model: var Model) =
  discard model.pruneScratchpadRefs()

proc moveFocusedToScratchpad*(model: var Model, name = ""): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false

  let activeTag = model.activeTag
  if activeTag == NullTagId or model.placementForWindowOnTag(activeTag, focused).isNone:
    return false

  let restoreMask = model.windowTagMask(focused)
  discard model.setWindowSticky(focused, false)
  discard model.removeWindowFromAllTagsAndRefreshFocus(focused)
  discard model.addScratchpadRef(focused)
  discard model.recordScratchpadRestoreTags(focused, restoreMask)
  let scratchpadName = name.strip()
  if scratchpadName.len > 0:
    discard model.setNamedScratchpadRef(scratchpadName, focused)
  discard model.hideScratchpadRef()
  true

proc showScratchpad*(model: var Model, winId: WindowId): bool =
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
    let active = model.activeScratchpadWindow()
    if active != NullWindowId and model.isNamedScratchpadWindow(active):
      let hidden = model.hideScratchpad()
      let next = model.nextStandardScratchpadWindow()
      if next == NullWindowId:
        return hidden
      return model.showScratchpad(next) or hidden
    let hidden = model.hideScratchpad()
    if active != NullWindowId:
      discard model.rotateScratchpadRefToBack(active)
    return hidden
  let next = model.nextStandardScratchpadWindow()
  if next == NullWindowId:
    return false
  model.showScratchpad(next)

proc toggleNamedScratchpad*(model: var Model, name: string): bool =
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
    elif model.nextStandardScratchpadWindow() != NullWindowId:
      model.nextStandardScratchpadWindow()
    else:
      NullWindowId
  if winId == NullWindowId or not model.hasWindow(winId):
    return false

  let restoreSlots = model.scratchpadRestoreSlots(winId)
  discard model.removeScratchpadRef(winId)

  var targetSlots = restoreSlots
  if targetSlots.len == 0:
    targetSlots.add(
      if model.activeWorkspaceSlot() == 0:
        1'u32
      else:
        model.activeWorkspaceSlot()
    )

  let activeSlot = model.activeWorkspaceSlot()
  var targetSlot = targetSlots[0]
  if activeSlot != 0 and targetSlots.find(activeSlot) != -1:
    targetSlot = activeSlot
  var targetTag = NullTagId
  discard model.setWindowSticky(winId, false)
  discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
  for slot in targetSlots:
    let tagId = model.ensureWorkspaceSlot(slot)
    if tagId == NullTagId:
      continue
    discard model.addPlacedWindowColumn(tagId, winId)
    if slot == targetSlot:
      targetTag = tagId
  if targetTag == NullTagId:
    return false

  discard model.focusWorkspaceSlot(targetSlot)
  discard model.setTagFocus(targetTag, winId)
  model.focusWindow(winId)

proc scratchpadRestoreMaskForSlots(slots: openArray[uint32]): TagMask =
  for slot in slots:
    if slot == 0 or slot > MaxTagBits:
      continue
    result.incl(tagBit(slot))

proc recordRestoredScratchpad*(
    model: var Model, restoredExternalId: ExternalWindowId, winId: WindowId
) =
  if winId == NullWindowId:
    return

  if model.restoredScratchpadContains(restoredExternalId):
    discard model.addScratchpadRef(winId)

  for name, externalId in model.restoreNamedScratchpadsWithId():
    if externalId == restoredExternalId:
      discard model.setNamedScratchpadRef(name, winId)

  if model.restoreVisibleScratchpadId() == restoredExternalId:
    discard model.setVisibleScratchpadRef(winId, model.restoreScratchpadVisible())

  let restoreMask =
    scratchpadRestoreMaskForSlots(model.restoredScratchpadSlots(restoredExternalId))
  if restoreMask != EmptyTagMask and model.restoredScratchpadContains(
    restoredExternalId
  ):
    discard model.recordScratchpadRestoreTags(winId, restoreMask)
