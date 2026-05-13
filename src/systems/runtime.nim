import std/[math, options]
import ../state/engine
import ../types/runtime_values as rv
from ../types/runtime_values import PointerOpKind
import focus, overview_geometry, placement

const OverviewHoldTicks = 47

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

proc setLayerFocusExclusive*(model: var Model, exclusive: bool): bool =
  model.setLayerFocusExclusiveState(exclusive)

proc setSessionLocked*(model: var Model, locked: bool): bool =
  model.setSessionLockedState(locked)

proc setActiveModifiers*(model: var Model, modifiers: uint32): bool =
  model.setActiveModifiersState(modifiers)

proc beginPointerMove*(model: var Model, externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpMove,
      windowId: winId,
      initialGeom: winOpt.get().floatingGeom,
    )
  )

proc beginPointerResize*(
    model: var Model, externalId: ExternalWindowId, edges: uint32
): bool =
  let winId = model.windowForExternal(externalId)
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().isFloating:
    return false
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpResize,
      windowId: winId,
      initialGeom: winOpt.get().floatingGeom,
      edges: edges,
    )
  )

proc overviewScreen(model: Model): rv.Rect =
  if model.primaryOutput != NullOutputId:
    let outputOpt = model.outputData(model.primaryOutput)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return rv.Rect(
          x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH
        )
      return rv.Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  rv.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc updateOverviewDragHover(model: var Model, op: var PointerOpData): bool =
  let target =
    model.overviewDropTargetAt(model.overviewScreen(), op.currentX, op.currentY)
  let slot =
    if target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap}:
      target.slot
    else:
      0'u32
  if op.hoverSlot == slot:
    inc op.hoverTicks
  else:
    op.hoverSlot = slot
    op.hoverTicks = 0
  model.setPointerOpState(op)

proc beginOverviewDrag*(
    model: var Model, externalId: ExternalWindowId, x, y: int32
): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or model.overviewWindowIds().find(winId) == -1:
    return false
  discard model.setOverviewSelection(winId)
  var op = PointerOpData(
    kind: PointerOpKind.OpOverviewDrag,
    windowId: winId,
    startX: x,
    startY: y,
    currentX: x,
    currentY: y,
  )
  discard model.updateOverviewDragHover(op)
  true

proc beginOverviewScroll*(model: var Model, x, y: int32): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpOverviewScroll,
      startX: x,
      startY: y,
      currentX: x,
      currentY: y,
      startScrollOffset: model.overviewScrollOffset,
    )
  )

proc closeOverviewFromPointer(model: var Model): bool =
  result = model.setOverviewActive(false)
  result = model.clearOverviewSelection() or result
  result = model.restoreOverviewViewportSnapshot() or result

proc overviewDragPastThreshold(op: PointerOpData): bool =
  abs(op.totalDX) >= OverviewDragThreshold or abs(op.totalDY) >= OverviewDragThreshold

proc commitOverviewDrag(model: var Model, op: PointerOpData): bool =
  if op.windowId == NullWindowId:
    return false

  let target =
    model.overviewDropTargetAt(model.overviewScreen(), op.currentX, op.currentY)
  if op.overviewDragPastThreshold() and
      target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap} and
      target.slot != 0:
    discard model.focusWindow(op.windowId, retargetViewport = false)
    result = model.moveFocusedWindowToSlotAndFocus(target.slot)
    if not result:
      result = model.focusWindow(op.windowId)
  else:
    result = model.focusWindow(op.windowId)
  result = model.closeOverviewFromPointer() or result

proc applyPointerDelta*(model: var Model, dx, dy: int32): bool =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpNone:
    return false
  if op.kind == PointerOpKind.OpOverviewDrag:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = op.startX + dx
    next.currentY = op.startY + dy
    return model.updateOverviewDragHover(next)
  if op.kind == PointerOpKind.OpOverviewScroll:
    var next = op
    next.totalDX = dx
    next.totalDY = dy
    next.currentX = op.startX + dx
    next.currentY = op.startY + dy
    discard model.setPointerOpState(next)
    return model.setOverviewScrollOffset(op.startScrollOffset + float32(dy))

  let winOpt = model.windowData(op.windowId)
  if winOpt.isNone:
    return false

  var geom = winOpt.get().floatingGeom
  case op.kind
  of PointerOpKind.OpMove:
    geom.x = op.initialGeom.x + dx
    geom.y = op.initialGeom.y + dy
  of PointerOpKind.OpResize:
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
  of PointerOpKind.OpNone:
    return false
  of PointerOpKind.OpOverviewDrag, PointerOpKind.OpOverviewScroll:
    return false

  model.setWindowFloatingGeom(op.windowId, geom)

proc finishPointerOp*(model: var Model): core.WindowId =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpOverviewDrag:
    discard model.commitOverviewDrag(op)
    discard model.clearPointerOp()
    return NullWindowId
  if op.kind == PointerOpKind.OpOverviewScroll:
    discard model.clearPointerOp()
    return NullWindowId
  result = if op.kind == PointerOpKind.OpResize: op.windowId else: NullWindowId
  discard model.clearPointerOp()

proc tickOverviewPointerHold*(model: var Model): bool =
  var op = model.pointerOp
  if op.kind != PointerOpKind.OpOverviewDrag or not op.overviewDragPastThreshold():
    return false
  discard model.updateOverviewDragHover(op)
  op = model.pointerOp
  if op.hoverSlot == 0 or op.hoverTicks < OverviewHoldTicks:
    return false
  result = model.commitOverviewDrag(op)
  discard model.clearPointerOp()

proc moveFloatingFocused*(model: var Model, dx, dy: int32): bool =
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

proc resizeFloatingFocused*(model: var Model, dw, dh: int32): bool =
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

proc adjustGaps*(model: var Model, delta: int32): bool =
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

proc renameActiveWorkspace*(model: var Model, name: string): bool =
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
  if not model.enableAnimations or model.overviewActive:
    return false
  let speed = model.animationSpeed
  let epsilon = 0.5'f32
  for tagId, tag in model.tagsWithId():
    if tagId != model.activeTag:
      continue
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
