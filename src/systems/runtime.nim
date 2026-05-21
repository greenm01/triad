import std/[math, options]
import ../core/native_layout_codec
import ../state/engine
import ../types/projection_values as rv
from ../types/runtime_values import
  JanetLayoutId, LayoutMode, NativeLayoutId, PointerOpKind
import focus, layout_projection, overview_geometry, placement, workspaces

const
  OverviewHoldMs = 752'i32
  ShiftModifier = 1'u32

proc tickElapsedMs(msgElapsedMs: int32): int32 =
  if msgElapsedMs > 0: msgElapsedMs else: DefaultFrameIntervalMs

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

proc overviewScreen(model: Model, outputId: OutputId = NullOutputId): rv.Rect =
  if outputId != NullOutputId:
    return model.outputScreen(outputId)
  model.activeWorkspaceScreen()

proc overviewOutputUnderPointer(model: Model, x, y: int32): Option[OutputId] =
  let outputId = model.overviewOutputAt(x, y)
  if outputId != NullOutputId:
    return some(outputId)
  if model.sortedOutputIdsByExternal().len == 0:
    return some(NullOutputId)
  none(OutputId)

proc updateOverviewDragHover(
    model: var Model, op: var PointerOpData, elapsedMs = 0'i32
): bool =
  let target = model.overviewDropTargetAtForOutput(
    op.outputId, model.overviewScreen(op.outputId), op.currentX, op.currentY
  )
  let slot =
    if target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap}:
      target.slot
    else:
      0'u32
  if op.hoverSlot == slot:
    op.hoverElapsedMs = max(0'i32, op.hoverElapsedMs + max(0'i32, elapsedMs))
  else:
    op.hoverSlot = slot
    op.hoverElapsedMs = 0
  model.setPointerOpState(op)

proc beginOverviewDrag*(
    model: var Model, externalId: ExternalWindowId, x, y: int32
): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let screen = model.overviewScreen(outputId)
  let winId = model.windowForExternal(externalId)
  if winId != NullWindowId and model.overviewWindowIds().find(winId) == -1:
    return false
  if winId == NullWindowId and
      model.overviewWorkspaceSlotAtForOutput(outputId, screen, x, y) == 0:
    return false
  if winId != NullWindowId:
    discard model.setOverviewSelection(winId)
  var op = PointerOpData(
    kind: PointerOpKind.OpOverviewDrag,
    windowId: winId,
    startX: x,
    startY: y,
    currentX: x,
    currentY: y,
    outputId: outputId,
  )
  discard model.updateOverviewDragHover(op)
  true

proc beginOverviewScroll*(model: var Model, x, y: int32): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let screen = model.overviewScreen(outputId)
  let slot =
    model.overviewWorkspaceSlotAtForOutput(outputId, screen, x, y, extendedX = true)
  if slot == 0:
    return false
  let tagId = model.tagForSlot(slot)
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let startOffset =
    if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
      tagOpt.get().currentViewportYOffset
    else:
      tagOpt.get().currentViewportXOffset
  model.setPointerOpState(
    PointerOpData(
      kind: PointerOpKind.OpOverviewScroll,
      startX: x,
      startY: y,
      currentX: x,
      currentY: y,
      outputId: outputId,
      startScrollOffset: startOffset,
      hoverSlot: slot,
    )
  )

proc signedStep(value: int32): int =
  if value > 0:
    return 1
  if value < 0:
    return -1
  0

proc overviewWorkspaceUnderPointerSlot(
    model: Model, outputId: OutputId, x, y: int32
): uint32 =
  model.overviewWorkspaceSlotAtForOutput(
    outputId, model.overviewScreen(outputId), x, y, extendedX = true
  )

proc focusOverviewColumnWheel(model: var Model, x, y: int32, step: int): bool =
  if step == 0:
    return false
  let outputOpt = model.overviewOutputUnderPointer(x, y)
  if outputOpt.isNone:
    return false
  let outputId = outputOpt.get()
  let slot = model.overviewWorkspaceUnderPointerSlot(outputId, x, y)
  if slot == 0:
    return false
  result = model.focusWorkspaceSlot(slot)
  result = model.focusColumnByStep(step) or result

proc handleOverviewWheel*(model: var Model, x, y, horizontal, vertical: int32): bool =
  if not model.overviewUsesWorkspacePreviews():
    return false

  let modifiers = model.activeModifiers
  if modifiers == 0'u32:
    result = model.focusOverviewColumnWheel(x, y, horizontal.signedStep())
    let workspaceStep = vertical.signedStep()
    if workspaceStep != 0:
      let outputOpt = model.overviewOutputUnderPointer(x, y)
      if outputOpt.isSome:
        let outputId = outputOpt.get()
        let slot = model.overviewWorkspaceUnderPointerSlot(outputId, x, y)
        if slot != 0:
          result = model.focusWorkspaceSlot(slot) or result
          result =
            model.focusOverviewWorkspaceStepForOutput(outputId, workspaceStep) or result
  elif modifiers == ShiftModifier:
    result = model.focusOverviewColumnWheel(x, y, vertical.signedStep())

proc closeOverviewMode*(model: var Model): bool =
  result = model.setOverviewActive(false)
  result = model.setOverviewWorkspacePreviewsActive(false) or result
  result = model.clearOverviewSelection() or result
  result = model.setOverviewTabModeActive(false, 0'u32) or result

proc closeOverviewFromPointer(model: var Model): bool =
  model.closeOverviewMode()

proc overviewDragPastThreshold(op: PointerOpData): bool =
  abs(op.totalDX) >= OverviewDragThreshold or abs(op.totalDY) >= OverviewDragThreshold

proc closeOverviewToSlot(model: var Model, slot: uint32): bool =
  if slot == 0:
    return false
  result = model.focusWorkspaceSlot(slot)
  result = model.closeOverviewFromPointer() or result

proc commitOverviewDrag(model: var Model, op: PointerOpData, activateDrop: bool): bool =
  let target = model.overviewDropTargetAtForOutput(
    op.outputId, model.overviewScreen(op.outputId), op.currentX, op.currentY
  )

  if op.windowId == NullWindowId:
    if not op.overviewDragPastThreshold() and
        target.kind == OverviewDropKind.DropWorkspace:
      return model.closeOverviewToSlot(target.slot)
    return false

  if op.overviewDragPastThreshold() and
      target.kind in {OverviewDropKind.DropWorkspace, OverviewDropKind.DropDynamicGap} and
      target.slot != 0:
    if target.kind == OverviewDropKind.DropDynamicGap and target.outputId != NullOutputId:
      let targetTag = model.ensureWorkspaceSlot(target.slot)
      if targetTag != NullTagId:
        discard model.setTagOutput(targetTag, target.outputId)
        if activateDrop:
          discard model.setOutputTag(target.outputId, targetTag)
          discard model.setActiveOutput(target.outputId)
    result = model.moveWindowToSlot(op.windowId, target.slot, activateDrop)
    if activateDrop and result:
      result = model.focusWindow(op.windowId) or result
      result = model.closeOverviewFromPointer() or result
  else:
    result = model.focusWindow(op.windowId)
    result = model.closeOverviewFromPointer() or result

proc panOverviewWorkspace(model: var Model, op: PointerOpData, dx, dy: int32): bool =
  if op.hoverSlot == 0:
    return false
  let tagId = model.tagForSlot(op.hoverSlot)
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  let zoom = model.effectiveOverviewZoom()
  let delta =
    if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
      -float32(dy) / zoom
    else:
      -float32(dx) / zoom
  let offset = op.startScrollOffset + delta
  if tagOpt.get().layoutMode == rv.LayoutMode.VerticalScroller:
    result =
      model.setTagViewportTarget(tagId, tagOpt.get().targetViewportXOffset, offset)
    result =
      model.setTagViewportCurrent(tagId, tagOpt.get().currentViewportXOffset, offset) or
      result
  else:
    result =
      model.setTagViewportTarget(tagId, offset, tagOpt.get().targetViewportYOffset)
    result =
      model.setTagViewportCurrent(tagId, offset, tagOpt.get().currentViewportYOffset) or
      result

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
    return model.panOverviewWorkspace(op, dx, dy)

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

  if op.kind == PointerOpKind.OpMove:
    model.setWindowManualFloatingGeom(op.windowId, geom)
  else:
    model.setWindowFloatingGeom(op.windowId, geom)

proc finishPointerOp*(model: var Model): core.WindowId =
  let op = model.pointerOp
  if op.kind == PointerOpKind.OpOverviewDrag:
    discard model.commitOverviewDrag(op, activateDrop = false)
    discard model.clearPointerOp()
    return NullWindowId
  if op.kind == PointerOpKind.OpOverviewScroll:
    discard model.clearPointerOp()
    return NullWindowId
  result = if op.kind == PointerOpKind.OpResize: op.windowId else: NullWindowId
  discard model.clearPointerOp()

proc tickOverviewPointerHold*(
    model: var Model, elapsedMs = DefaultFrameIntervalMs
): bool =
  var op = model.pointerOp
  if op.kind != PointerOpKind.OpOverviewDrag or not op.overviewDragPastThreshold():
    return false
  discard model.updateOverviewDragHover(op, elapsedMs.tickElapsedMs())
  op = model.pointerOp
  if op.hoverSlot == 0 or op.hoverElapsedMs < OverviewHoldMs:
    return false
  result = model.commitOverviewDrag(op, activateDrop = true)
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
  model.setWindowManualFloatingGeom(winId, geom)

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
  if tagOpt.get().nativeLayoutId.nativeLayoutIdString() == BspTreeLayoutId:
    return false
  let focused = tagOpt.get().focusedWindow
  if focused == NullWindowId or
      model.placementForWindowOnTag(model.activeTag, focused).isNone:
    return false

  var visible: seq[WindowId] = @[]
  for instr in model.activeFocusLayoutInstructions():
    let winId = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    if winId != NullWindowId and visible.find(winId) == -1 and
        model.placementForWindowOnTag(model.activeTag, winId).isSome:
      visible.add(winId)
  let focusedIdx = visible.find(focused)
  if focusedIdx == -1 or visible.len <= 1:
    return false

  let neighbor = visible[(focusedIdx + 1) mod visible.len]
  var members: seq[WindowId] = @[]
  for winId in [focused, neighbor]:
    let groupId = model.groupForWindow(winId)
    if groupId != NullGroupId:
      let groupOpt = model.groupData(groupId)
      if groupOpt.isSome:
        for member in groupOpt.get().windows:
          if members.find(member) == -1:
            members.add(member)
    elif members.find(winId) == -1:
      members.add(winId)
  if members.len <= 1:
    return false

  if tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId:
    var frameId = model.frameForWindowOnTag(model.activeTag, focused)
    if frameId == NullFrameId:
      frameId = model.focusedFrameOrRoot(model.activeTag)
    if frameId == NullFrameId:
      return false
    for member in members:
      discard model.addWindowToFrame(model.activeTag, member, frameId)
    discard model.setFrameActiveWindow(frameId, focused)
    discard model.setFocusedFrame(model.activeTag, frameId)
  else:
    let placement = model.placementForWindowOnTag(model.activeTag, focused)
    if placement.isNone:
      return false
    let columnId = placement.get().columnId
    var targetIdx = int(placement.get().windowIdx)
    for member in members:
      if member == focused:
        continue
      discard model.moveWindowToColumn(model.activeTag, member, columnId, targetIdx)
      inc targetIdx

  let groupId = model.addGroup(members, focused)
  if groupId == NullGroupId:
    return false
  discard model.setTagFocus(model.activeTag, focused)
  true

proc ungroupFocusedWindow*(model: var Model): bool =
  let focused = model.focusedOnActiveTag()
  focused != NullWindowId and model.ungroupWindow(focused)

proc focusNextInGroup*(model: var Model): bool =
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return false
  let groupId = model.groupForWindow(focused)
  let groupOpt = model.groupData(groupId)
  if groupOpt.isNone or groupOpt.get().windows.len <= 1:
    return false
  let group = groupOpt.get()
  var idx = group.windows.find(group.activeWindow)
  if idx == -1:
    idx = group.windows.find(focused)
  if idx == -1:
    return false
  let next = group.windows[(idx + 1) mod group.windows.len]
  discard model.setGroupActiveWindow(next)
  model.focusWindow(next)

proc animatedViewportOffset(
    current, target, speed, snapThreshold: float32
): tuple[value: float32, changed: bool] =
  let delta = target - current
  if speed <= 0.0'f32 or abs(delta) <= snapThreshold:
    return (target, abs(delta) > 0.0'f32)
  (current + delta * speed, true)

proc elapsedAnimationSpeed(speed: float32, elapsedMs: int32): float32 =
  if speed <= 0.0'f32 or speed >= 1.0'f32:
    return speed
  let frames =
    max(0.0'f32, float32(elapsedMs.tickElapsedMs()) / float32(DefaultFrameIntervalMs))
  1.0'f32 - pow(1.0'f32 - speed, frames)

proc tickAnimations*(model: var Model, elapsedMs = DefaultFrameIntervalMs): bool =
  if not model.enableAnimations:
    return false
  let tickOverviewPreviews = model.overviewUsesWorkspacePreviews()
  if model.overviewActive and not tickOverviewPreviews:
    return false
  let previewSlots =
    if tickOverviewPreviews:
      model.previewSlots()
    else:
      @[]
  let speed = model.animationSpeed.elapsedAnimationSpeed(elapsedMs)
  let snapThreshold = max(model.animationSnapThreshold, 0.01'f32)
  for tagId, tag in model.tagsWithId():
    if tickOverviewPreviews:
      if previewSlots.find(tag.slot) == -1:
        continue
    elif tagId != model.activeTag:
      continue
    var currentX = tag.currentViewportXOffset
    var currentY = tag.currentViewportYOffset
    let nextX =
      animatedViewportOffset(currentX, tag.targetViewportXOffset, speed, snapThreshold)
    let nextY =
      animatedViewportOffset(currentY, tag.targetViewportYOffset, speed, snapThreshold)
    currentX = nextX.value
    currentY = nextY.value
    let changed = nextX.changed or nextY.changed
    if changed:
      discard model.setTagViewportCurrent(tagId, currentX, currentY)
      result = true

proc hasPendingViewportAnimation*(model: Model): bool =
  if not model.enableAnimations:
    return false
  let tickOverviewPreviews = model.overviewUsesWorkspacePreviews()
  if model.overviewActive and not tickOverviewPreviews:
    return false
  let previewSlots =
    if tickOverviewPreviews:
      model.previewSlots()
    else:
      @[]
  let snapThreshold = max(model.animationSnapThreshold, 0.01'f32)
  for tagId, tag in model.tagsWithId():
    if tickOverviewPreviews:
      if previewSlots.find(tag.slot) == -1:
        continue
    elif tagId != model.activeTag:
      continue
    if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > 0.0'f32 or
        abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > 0.0'f32:
      if model.animationSpeed <= 0.0'f32:
        return true
      if abs(tag.targetViewportXOffset - tag.currentViewportXOffset) > snapThreshold or
          abs(tag.targetViewportYOffset - tag.currentViewportYOffset) > snapThreshold:
        return true
      return true

proc needsFrameTick*(model: Model): bool =
  if model.hasPendingViewportAnimation():
    return true
  if model.pointerOp.kind == PointerOpKind.OpOverviewDrag and
      model.pointerOp.overviewDragPastThreshold() and model.pointerOp.hoverSlot != 0 and
      model.pointerOp.hoverElapsedMs < OverviewHoldMs:
    return true
  if model.pendingRecentFocusWindow != NullWindowId:
    return true
  if model.recentWindowsActive and
      model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
    return true
  if model.layoutSwitchToastOpen:
    return true
  model.pendingDialogFocusWindows.len > 0

proc frameTickReasons*(model: Model): seq[string] =
  if model.hasPendingViewportAnimation():
    result.add("viewport-animation")
  if model.pointerOp.kind == PointerOpKind.OpOverviewDrag and
      model.pointerOp.overviewDragPastThreshold() and model.pointerOp.hoverSlot != 0 and
      model.pointerOp.hoverElapsedMs < OverviewHoldMs:
    result.add("overview-hover")
  if model.pendingRecentFocusWindow != NullWindowId:
    result.add("recent-focus")
  if model.recentWindowsActive and
      model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
    result.add("recent-window-open-delay")
  if model.layoutSwitchToastOpen:
    result.add("layout-switch-toast")
  if model.pendingDialogFocusWindows.len > 0:
    result.add("dialog-focus")

proc openLayoutSwitchToast*(
    model: var Model,
    layout: LayoutMode,
    customLayout = JanetLayoutId(""),
    nativeLayout = NativeLayoutId(""),
): bool =
  if not model.layoutSwitchToast.enabled or model.layoutSwitchToast.timeoutMs <= 0:
    return false
  result =
    not model.layoutSwitchToastOpen or model.layoutSwitchToastElapsedMs != 0 or
    model.layoutSwitchToastLayout != layout or
    string(model.layoutSwitchToastCustomLayout) != string(customLayout) or
    string(model.layoutSwitchToastNativeLayout) != string(nativeLayout)
  model.layoutSwitchToastOpen = true
  model.layoutSwitchToastElapsedMs = 0
  model.layoutSwitchToastLayout = layout
  model.layoutSwitchToastCustomLayout = customLayout
  model.layoutSwitchToastNativeLayout = nativeLayout

proc tickLayoutSwitchToast*(
    model: var Model, elapsedMs = DefaultFrameIntervalMs
): bool =
  if not model.layoutSwitchToastOpen:
    return false
  model.layoutSwitchToastElapsedMs += elapsedMs.tickElapsedMs()
  if model.layoutSwitchToastElapsedMs >= model.layoutSwitchToast.timeoutMs:
    model.layoutSwitchToastOpen = false
    model.layoutSwitchToastElapsedMs = 0
    return true
  false
