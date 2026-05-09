import ../types/model
import ../types/core
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
