import math, options
import ../state/engine
from ../types/runtime_values import OpMove, OpNone, OpResize, PointerOpKind

proc keyboardShortcutsInhibited*(model: Model): bool =
  if model.sessionLocked or model.layerFocusExclusive:
    return false
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.keyboardShortcutsInhibit and not win.keyboardShortcutsInhibitBypass

proc setLayerFocusExclusive*(model: var Model; exclusive: bool): bool =
  model.setLayerFocusExclusiveState(exclusive)

proc setSessionLocked*(model: var Model; locked: bool): bool =
  model.setSessionLockedState(locked)

proc setActiveModifiers*(model: var Model; modifiers: uint32): bool =
  model.setActiveModifiersState(modifiers)

proc beginPointerMove*(model: var Model; externalId: ExternalWindowId):
    bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  model.setPointerOpState(PointerOpData(
    kind: OpMove,
    windowId: winId,
    initialGeom: winOpt.get().floatingGeom
  ))

proc beginPointerResize*(model: var Model; externalId: ExternalWindowId;
    edges: uint32): bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  model.setPointerOpState(PointerOpData(
    kind: OpResize,
    windowId: winId,
    initialGeom: winOpt.get().floatingGeom,
    edges: edges
  ))

proc applyPointerDelta*(model: var Model; dx, dy: int32): bool =
  let op = model.pointerOp
  if op.kind == OpNone:
    return false
  let winOpt = model.windowData(op.windowId)
  if winOpt.isNone:
    return false

  var geom = winOpt.get().floatingGeom
  case op.kind
  of OpMove:
    geom.x = op.initialGeom.x + dx
    geom.y = op.initialGeom.y + dy
  of OpResize:
    if (op.edges and 1) != 0:
      geom.y = op.initialGeom.y + dy
      geom.h = max(model.effectiveFloatingMinHeight(), op.initialGeom.h - dy)
    elif (op.edges and 2) != 0:
      geom.h = max(model.effectiveFloatingMinHeight(), op.initialGeom.h + dy)
    if (op.edges and 4) != 0:
      geom.x = op.initialGeom.x + dx
      geom.w = max(model.effectiveFloatingMinWidth(), op.initialGeom.w - dx)
    elif (op.edges and 8) != 0:
      geom.w = max(model.effectiveFloatingMinWidth(), op.initialGeom.w + dx)
  of OpNone:
    return false

  model.setWindowFloatingGeom(op.windowId, geom)

proc finishPointerOp*(model: var Model): WindowId =
  result =
    if model.pointerOp.kind == OpResize: model.pointerOp.windowId
    else: NullWindowId
  discard model.clearPointerOp()

proc moveFloatingFocused*(model: var Model; dx, dy: int32): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  var geom = winOpt.get().floatingGeom
  geom.x += dx
  geom.y += dy
  model.setWindowFloatingGeom(winId, geom)

proc resizeFloatingFocused*(model: var Model; dw, dh: int32): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let winId = tagOpt.get().focusedWindow
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  var geom = winOpt.get().floatingGeom
  geom.w = max(model.effectiveFloatingMinWidth(), geom.w + dw)
  geom.h = max(model.effectiveFloatingMinHeight(), geom.h + dh)
  model.setWindowFloatingGeom(winId, geom)

proc adjustGaps*(model: var Model; delta: int32): bool =
  model.outerGaps = max(0'i32, model.outerGaps + delta)
  model.innerGaps = model.outerGaps div 2
  true

proc toggleGaps*(model: var Model): bool =
  if model.outerGaps > 0:
    model.previousOuterGaps = model.outerGaps
    model.previousInnerGaps = model.innerGaps
    model.outerGaps = 0
    model.innerGaps = 0
  else:
    model.outerGaps = model.previousOuterGaps
    model.innerGaps = model.previousInnerGaps
  true

proc renameActiveWorkspace*(model: var Model; name: string): bool =
  let tagId = model.activeTag
  tagId != NullTagId and model.setTagName(tagId, name)

proc groupFocusedWindow*(model: var Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let focused = tagOpt.get().focusedWindow
  if focused == NullWindowId or
      model.placementForWindowOnTag(model.activeTag, focused).isNone:
    return false
  model.addGroup(@[focused], focused) != NullGroupId

proc tickAnimations*(model: var Model): bool =
  if not model.enableAnimations:
    return false
  let speed = model.animationSpeed
  let epsilon = 0.5'f32
  for tagId, tag in model.tagsWithId():
    var currentX = tag.currentViewportXOffset
    var currentY = tag.currentViewportYOffset
    let dx = tag.targetViewportXOffset - currentX
    let dy = tag.targetViewportYOffset - currentY
    var changed = false
    if abs(dx) > epsilon:
      currentX += dx * speed
      changed = true
    else:
      currentX = tag.targetViewportXOffset
    if abs(dy) > epsilon:
      currentY += dy * speed
      changed = true
    else:
      currentY = tag.targetViewportYOffset
    if changed:
      discard model.setTagViewportCurrent(tagId, currentX, currentY)
      result = true
