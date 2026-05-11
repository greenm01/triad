import std/[options, sets, tables]
import ../state/entity_manager
import ../types/[core, model]
from ../types/runtime_values import PointerOpKind

proc setOverviewActive*(model: var Model; active: bool): bool =
  if model.overviewActive == active:
    return false
  model.overviewActive = active
  true

proc setOverviewSelection*(
    model: var Model; winId: WindowId): bool =
  if model.overviewSelectedWindow == winId:
    return false
  model.overviewSelectedWindow = winId
  true

proc clearOverviewSelection*(model: var Model): bool =
  model.setOverviewSelection(NullWindowId)

proc saveOverviewViewportSnapshot*(model: var Model): bool =
  model.overviewViewportSnapshot.clear()
  for tag in model.tags.entities:
    model.overviewViewportSnapshot[tag.id] = ViewportState(
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset)
  true

proc restoreOverviewViewportSnapshot*(model: var Model): bool =
  for tagId, viewport in model.overviewViewportSnapshot.pairs:
    if model.tags.entity(tagId).isSome:
      model.tags.mEntity(tagId).targetViewportXOffset =
        viewport.targetViewportXOffset
      model.tags.mEntity(tagId).currentViewportXOffset =
        viewport.currentViewportXOffset
      model.tags.mEntity(tagId).targetViewportYOffset =
        viewport.targetViewportYOffset
      model.tags.mEntity(tagId).currentViewportYOffset =
        viewport.currentViewportYOffset
      result = true
  if model.overviewViewportSnapshot.len > 0:
    model.overviewViewportSnapshot.clear()
    result = true
  if model.viewportRetargetTags.len > 0:
    model.viewportRetargetTags.clear()
    result = true

proc setLayerFocusExclusiveState*(
    model: var Model; exclusive: bool): bool =
  if model.layerFocusExclusive == exclusive:
    return false
  model.layerFocusExclusive = exclusive
  true

proc clearPointerOp*(model: var Model): bool =
  if model.pointerOp.kind == PointerOpKind.OpNone:
    return false
  model.pointerOp = PointerOpData(kind: PointerOpKind.OpNone)
  true

proc setSessionLockedState*(model: var Model; locked: bool): bool =
  if model.sessionLocked == locked:
    return false
  model.sessionLocked = locked
  if locked:
    discard model.clearPointerOp()
  true

proc setActiveModifiersState*(model: var Model; modifiers: uint32):
    bool =
  if model.activeModifiers == modifiers:
    return false
  model.activeModifiers = modifiers
  true

proc setPointerOpState*(model: var Model; pointerOp: PointerOpData):
    bool =
  model.pointerOp = pointerOp
  true

proc setScreenSize*(model: var Model; w, h: int32): bool =
  let nextW = max(0'i32, w)
  let nextH = max(0'i32, h)
  if model.screenWidth == nextW and model.screenHeight == nextH:
    return false
  model.screenWidth = nextW
  model.screenHeight = nextH
  true
