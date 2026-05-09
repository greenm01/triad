import ../types/dod_model
from ../types/legacy_model import OpNone

proc setOverviewActive*(model: var DodModel; active: bool): bool =
  if model.overviewActive == active:
    return false
  model.overviewActive = active
  true

proc setLayerFocusExclusiveState*(
    model: var DodModel; exclusive: bool): bool =
  if model.layerFocusExclusive == exclusive:
    return false
  model.layerFocusExclusive = exclusive
  true

proc clearPointerOp*(model: var DodModel): bool =
  if model.pointerOp.kind == OpNone:
    return false
  model.pointerOp = DodPointerOpData(kind: OpNone)
  true

proc setSessionLockedState*(model: var DodModel; locked: bool): bool =
  if model.sessionLocked == locked:
    return false
  model.sessionLocked = locked
  if locked:
    discard model.clearPointerOp()
  true

proc setActiveModifiersState*(model: var DodModel; modifiers: uint32):
    bool =
  if model.activeModifiers == modifiers:
    return false
  model.activeModifiers = modifiers
  true

proc setPointerOpState*(model: var DodModel; pointerOp: DodPointerOpData):
    bool =
  model.pointerOp = pointerOp
  true

proc setScreenSize*(model: var DodModel; w, h: int32): bool =
  let nextW = max(0'i32, w)
  let nextH = max(0'i32, h)
  if model.screenWidth == nextW and model.screenHeight == nextH:
    return false
  model.screenWidth = nextW
  model.screenHeight = nextH
  true
