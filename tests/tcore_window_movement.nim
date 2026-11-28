import std/math
import tcore_support
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/systems/[daemon_view, window_stacking]
import ../src/systems/runtime
import ../src/types/janet_layouts

proc activeTiledOrder(model: Model): seq[uint32] =
  for columnId, _ in model.columnsOnTagWithId(model.activeTag):
    for winId, _ in model.windowsOnColumnWithId(columnId):
      let win = model.windowData(winId)
      if win.isSome:
        result.add(uint32(win.get().externalId))

proc placementForExternal(
    model: Model, externalId: uint32
): tuple[columnId: ColumnId, windowIdx: uint32] =
  let winId = model.windowForExternal(ExternalWindowId(externalId))
  let placement = model.placementForWindowOnTag(model.activeTag, winId)
  if placement.isSome:
    return (placement.get().columnId, placement.get().windowIdx)
  (NullColumnId, 0'u32)

proc modelWindow(model: Model, externalId: uint32): WindowData =
  model.windowData(model.windowForExternal(ExternalWindowId(externalId))).get()

proc placementForExternalOnSlot(
    model: Model, slot, externalId: uint32
): tuple[found: bool, columnId: ColumnId, windowIdx: uint32] =
  let tagId = model.tagForSlot(slot)
  let winId = model.windowForExternal(ExternalWindowId(externalId))
  let placement = model.placementForWindowOnTag(tagId, winId)
  if placement.isSome:
    return (true, placement.get().columnId, placement.get().windowIdx)
  (false, NullColumnId, 0'u32)

proc projectedInstruction(model: Model, externalId: uint32): RenderInstruction =
  for instr in model.layoutProjection().instructions:
    if uint32(instr.windowId) == externalId:
      return instr
  RenderInstruction()

proc setupSideBySideOutputs(model: var Model) =
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
  )
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 1000, outputY: 0)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

proc setupStackedOutputs(model: var Model) =
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 1000, height: 600)
  )
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: 0, outputY: 700)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

proc setupNegativeOffsetOutputs(model: var Model) =
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "DP-1"))
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 900, height: 700)
  )
  model.applyMsg(
    Msg(kind: MsgKind.WlOutputPosition, positionOutputId: 2, outputX: -900, outputY: 0)
  )
  model.applyMsg(Msg(kind: MsgKind.WlOutputName, nameOutputId: 2, outputName: "DP-2"))

proc spiralMovement(
    context: JanetLayoutContext, direction: Direction
): JanetLayoutMovementEvalResult =
  check context.layoutId.layoutIdString() == "spiral"
  check context.tag.focusedWindow == 3'u32
  case direction
  of Direction.DirUp:
    JanetLayoutMovementEvalResult(
      layoutId: context.layoutId,
      handled: true,
      ok: true,
      op: JanetLayoutMovementOp.MoveOrder,
      delta: -1,
    )
  of Direction.DirDown:
    JanetLayoutMovementEvalResult(
      layoutId: context.layoutId,
      handled: true,
      ok: true,
      op: JanetLayoutMovementOp.MoveOrder,
      delta: 1,
    )
  of Direction.DirLeft, Direction.DirRight:
    JanetLayoutMovementEvalResult(
      layoutId: context.layoutId,
      handled: true,
      ok: true,
      op: JanetLayoutMovementOp.Noop,
    )

proc moveWindowMsg(direction: Direction): Msg =
  case direction
  of Direction.DirLeft:
    Msg(kind: MsgKind.CmdMoveWindowLeft)
  of Direction.DirRight:
    Msg(kind: MsgKind.CmdMoveWindowRight)
  of Direction.DirUp:
    Msg(kind: MsgKind.CmdMoveWindowUp)
  of Direction.DirDown:
    Msg(kind: MsgKind.CmdMoveWindowDown)

proc expectedSwapOrder(order: seq[uint32], focused, target: uint32): seq[uint32] =
  result = order
  let focusedIdx = result.find(focused)
  let targetIdx = result.find(target)
  if focusedIdx != -1 and targetIdx != -1:
    swap(result[focusedIdx], result[targetIdx])

proc checkMoveMirrorsNavigation(base: Model, focused: uint32, direction: Direction) =
  var navigation = base
  navigation.focusExternal(focused)
  let target = navigation.focusDirection(direction)
  if target == 0 or target == focused:
    return

  var moved = base
  moved.focusExternal(focused)
  let beforeOrder = moved.activeTiledOrder()

  moved.applyMsg(direction.moveWindowMsg())

  check moved.focusedWindowId() == focused
  check moved.activeTiledOrder() == beforeOrder.expectedSwapOrder(focused, target)

proc activatePointerDrag(model: var Model, externalId: uint32): tuple[x, y: int32] =
  result = model.instructionGeom(externalId).rectCenter()
  check model.beginPointerMove(ExternalWindowId(externalId), result.x, result.y)
  check model.applyPointerDelta(9, 0)

proc applyPointerDrop(model: var Model, start: tuple[x, y: int32], x, y: int32) =
  check model.applyPointerDelta(x - start.x, y - start.y, x, y)

proc stackWindowOneIntoTwo(model: var Model) =
  let start = model.activatePointerDrag(1)
  let target = model.instructionGeom(2)
  let dropX = target.x + target.w div 2
  let dropY = target.y + (target.h * 3) div 4

  model.applyPointerDrop(start, dropX, dropY)
  discard model.finishPointerOp()

  let first = model.placementForExternal(1)
  let second = model.placementForExternal(2)
  check first.columnId == second.columnId
  check first.windowIdx == 2

proc stackWindowOneIntoTwoVertical(model: var Model) =
  let start = model.activatePointerDrag(1)
  let target = model.instructionGeom(2)
  let dropX = target.x + target.w + max(0'i32, model.innerGaps) - 1
  let dropY = target.y + target.h div 2

  model.applyPointerDrop(start, dropX, dropY)
  discard model.finishPointerOp()

  let first = model.placementForExternal(1)
  let second = model.placementForExternal(2)
  check first.columnId == second.columnId
  check first.windowIdx == 2

proc stackWindowThreeIntoTwoColumn(model: var Model) =
  model.stackWindowOneIntoTwo()
  let start = model.activatePointerDrag(3)
  let target = model.instructionGeom(1)
  let dropX = target.x + target.w div 2
  let dropY = target.y + target.h - 1

  model.applyPointerDrop(start, dropX, dropY)
  discard model.finishPointerOp()

  let first = model.placementForExternal(1)
  let second = model.placementForExternal(2)
  let third = model.placementForExternal(3)
  check first.columnId == second.columnId
  check third.columnId == second.columnId
  check model.activeTiledOrder() == @[2'u32, 1, 3]

proc stackWindowThreeIntoTwoRow(model: var Model) =
  model.stackWindowOneIntoTwoVertical()
  let start = model.activatePointerDrag(3)
  let target = model.instructionGeom(1)
  let dropX = target.x + target.w - 1
  let dropY = target.y + target.h div 2

  model.applyPointerDrop(start, dropX, dropY)
  discard model.finishPointerOp()

  let first = model.placementForExternal(1)
  let second = model.placementForExternal(2)
  let third = model.placementForExternal(3)
  check first.columnId == second.columnId
  check third.columnId == second.columnId
  check model.activeTiledOrder() == @[2'u32, 1, 3]

suite "Core Runtime Logic: window movement":
  test "Pointer drag can toggle tiled window to floating on release":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let geom = model.instructionGeom(1)
    let center = geom.rectCenter()

    check model.beginPointerMove(ExternalWindowId(1), center.x, center.y)
    check model.applyPointerDelta(16, 0)
    check model.pointerOp.dragActive
    check not model.pointerOp.dropFloating

    check model.togglePointerDropMode()
    check model.pointerOp.dropFloating
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    check win.isFloating
    check win.manualFloatingPosition
    check win.floatingGeom.x == geom.x + 16
    check win.floatingGeom.y == geom.y

  test "Pointer drag can toggle floating window back to tiled placement":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let original = model.placementForExternal(1)
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerMove(ExternalWindowId(1), geom.x + 10, geom.y + 10)
    check model.pointerOp.dropFloating
    check model.togglePointerDropMode()
    check model.pointerOp.tiled
    check not model.pointerOp.dropFloating
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    let placement = model.placementForExternal(1)
    check not win.isFloating
    check placement.columnId == original.columnId
    check placement.windowIdx == original.windowIdx

  test "Floating pointer move previews before committing manual geometry":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerMove(ExternalWindowId(1), geom.x + 10, geom.y + 10)
    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlPointerDelta,
        dx: 25,
        dy: 30,
        pointerX: geom.x + 35,
        pointerY: geom.y + 40,
      )
    )

    let preview = model.instructionGeom(1)
    let held = model.modelWindow(1)
    check held.floatingGeom == geom
    check preview.x == geom.x + 25
    check preview.y == geom.y + 30
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

    discard model.updateModel(Msg(kind: MsgKind.WlPointerRelease))
    let committed = model.modelWindow(1)
    check committed.manualFloatingPosition
    check committed.floatingGeom.x == geom.x + 25
    check committed.floatingGeom.y == geom.y + 30

  test "Floating pointer move release without delta preserves auto geometry":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerMove(ExternalWindowId(1), geom.x + 10, geom.y + 10)
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    check not win.manualFloatingPosition
    check win.floatingGeom == geom

  test "Floating pointer resize uses hit-tested edge axes":
    var rightModel = cameraModel()
    rightModel.seedCameraWindows(2)
    let rightWin = rightModel.windowForExternal(ExternalWindowId(1))
    let rightGeom = rightModel.instructionGeom(1)
    check rightModel.setWindowFloating(rightWin, true, rightGeom)
    check rightModel.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      rightGeom.x + rightGeom.w - 1,
      rightGeom.y + rightGeom.h div 2,
    )
    check rightModel.applyPointerDelta(40, 40)
    discard rightModel.finishPointerOp()
    check rightModel.modelWindow(1).floatingGeom.w == rightGeom.w + 40
    check rightModel.modelWindow(1).floatingGeom.h == rightGeom.h

    var bottomModel = cameraModel()
    bottomModel.seedCameraWindows(2)
    let bottomWin = bottomModel.windowForExternal(ExternalWindowId(1))
    let bottomGeom = bottomModel.instructionGeom(1)
    check bottomModel.setWindowFloating(bottomWin, true, bottomGeom)
    check bottomModel.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      bottomGeom.x + bottomGeom.w div 2,
      bottomGeom.y + bottomGeom.h - 1,
    )
    check bottomModel.applyPointerDelta(40, 40)
    discard bottomModel.finishPointerOp()
    check bottomModel.modelWindow(1).floatingGeom.w == bottomGeom.w
    check bottomModel.modelWindow(1).floatingGeom.h == bottomGeom.h + 40

    var cornerModel = cameraModel()
    cornerModel.seedCameraWindows(2)
    let cornerWin = cornerModel.windowForExternal(ExternalWindowId(1))
    let cornerGeom = cornerModel.instructionGeom(1)
    check cornerModel.setWindowFloating(cornerWin, true, cornerGeom)
    check cornerModel.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      cornerGeom.x + cornerGeom.w - 1,
      cornerGeom.y + cornerGeom.h - 1,
    )
    check cornerModel.applyPointerDelta(40, 40)
    discard cornerModel.finishPointerOp()
    check cornerModel.modelWindow(1).floatingGeom.w == cornerGeom.w + 40
    check cornerModel.modelWindow(1).floatingGeom.h == cornerGeom.h + 40

  test "Floating pointer corner resize tracks both axes immediately":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerResize(
      ExternalWindowId(1), 10'u32, geom.x + geom.w - 1, geom.y + 1
    )
    check model.applyPointerDelta(40, 4)
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    check win.floatingGeom.w == geom.w + 40
    check win.floatingGeom.y == geom.y + 4
    check win.floatingGeom.h == geom.h - 4

  test "Floating pointer resize can become diagonal after dominant-axis start":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerResize(
      ExternalWindowId(1), 10'u32, geom.x + geom.w - 1, geom.y + geom.h - 1
    )
    check model.applyPointerDelta(40, 0)
    check model.modelWindow(1).floatingGeom.w == geom.w + 40
    check model.modelWindow(1).floatingGeom.h == geom.h

    check model.applyPointerDelta(40, 40)
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    check win.floatingGeom.w == geom.w + 40
    check win.floatingGeom.h == geom.h + 40

  test "Floating pointer resize preserves hit-tested top-left direction":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    check model.setWindowFloating(winId, true, geom)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, geom.x + 1, geom.y + 1)
    check model.applyPointerDelta(40, 40)
    discard model.finishPointerOp()

    let win = model.modelWindow(1)
    check win.floatingGeom.x == geom.x + 40
    check win.floatingGeom.y == geom.y + 40
    check win.floatingGeom.w == geom.w - 40
    check win.floatingGeom.h == geom.h - 40

  test "Floating pointer resize falls back to binding edges from center third":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let geom = model.instructionGeom(1)
    let center = geom.rectCenter()
    check model.setWindowFloating(winId, true, geom)

    check not model.beginPointerResize(ExternalWindowId(1), 0'u32, center.x, center.y)
    check model.pointerOp.kind == PointerOpKind.OpNone

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, center.x, center.y)
    check model.applyPointerDelta(40, 40)
    discard model.finishPointerOp()
    check model.modelWindow(1).floatingGeom.w == geom.w + 40
    check model.modelWindow(1).floatingGeom.h == geom.h + 40

  test "Scroller resize edge double-click toggles full-width column":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let geom = model.instructionGeom(1)
    let placement = model.placementForExternal(1)
    check not model.column(placement.columnId).get().isFullWidth

    let first = model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + 1, geom.y + geom.h div 2, 1000
    )
    check not first.handled
    let second = model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + 1, geom.y + geom.h div 2, 1200
    )
    check second.handled
    check second.dirty
    check model.column(placement.columnId).get().isFullWidth

  test "Scroller resize edge double-click resets window height proportion":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)

    discard model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + geom.w div 2, geom.y + 1, 1000
    )
    let second = model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + geom.w div 2, geom.y + 1, 1200
    )
    check second.handled
    check model.modelWindow(1).heightProportion == 1.0'f32

  test "Vertical scroller resize edge double-click uses transposed gestures":
    var model = directionalModel(LayoutMode.VerticalScroller, 2)
    let geom = model.instructionGeom(1)
    let placement = model.placementForExternal(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowWidthProportion(winId, 0.5)

    discard model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + geom.w div 2, geom.y + 1, 1000
    )
    let fullWidth = model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), geom.x + geom.w div 2, geom.y + 1, 1200
    )
    check fullWidth.handled
    check model.column(placement.columnId).get().isFullWidth

    let resetGeom = model.instructionGeom(1)
    discard model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), resetGeom.x + 1, resetGeom.y + resetGeom.h div 2, 2000
    )
    let reset = model.handlePointerResizeDoubleClick(
      ExternalWindowId(1), resetGeom.x + 1, resetGeom.y + resetGeom.h div 2, 2200
    )
    check reset.handled
    check model.modelWindow(1).widthProportion == 1.0'f32

  test "Viewport animation uses configured snap threshold":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          enableAnimations: true, animationSpeed: 0.5, animationSnapThreshold: 10.0
        ),
        workspaces: WorkspaceConfig(defaultCount: 1),
      )
    ).model
    model.setViewport(1, targetX = 100.0, currentX = 0.0)

    check model.tickAnimations()
    check model.viewport(1).currentViewportXOffset == 50.0'f32

    model.setViewport(1, targetX = 100.0, currentX = 95.0)
    check model.tickAnimations()
    check model.viewport(1).currentViewportXOffset == 100.0'f32
    check not model.tickAnimations()

  test "Viewport animation scales by elapsed tick time":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          enableAnimations: true, animationSpeed: 0.5, animationSnapThreshold: 0.5
        ),
        workspaces: WorkspaceConfig(defaultCount: 1),
      )
    ).model
    model.setViewport(1, targetX = 100.0, currentX = 0.0)

    check model.tickAnimations(8)
    check abs(model.viewport(1).currentViewportXOffset - 29.289322'f32) < 0.001'f32
    check model.tickAnimations(8)
    check abs(model.viewport(1).currentViewportXOffset - 50.0'f32) < 0.001'f32

  test "Viewport animation stays clean for subpixel-only movement":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          enableAnimations: true, animationSpeed: 0.25, animationSnapThreshold: 0.01
        ),
        workspaces: WorkspaceConfig(defaultCount: 1),
      )
    ).model
    model.setViewport(1, targetX = 0.4, currentX = 0.0)

    check not model.tickAnimations()
    check abs(model.viewport(1).currentViewportXOffset - 0.1'f32) < 0.001'f32
    check model.hasPendingViewportAnimation()

  test "Zero animation speed snaps without repeated dirty ticks":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          enableAnimations: true, animationSpeed: 0.0, animationSnapThreshold: 0.5
        ),
        workspaces: WorkspaceConfig(defaultCount: 1),
      )
    ).model
    model.setViewport(
      1, targetX = 100.0, currentX = 0.0, targetY = 50.0, currentY = 0.0
    )

    check model.tickAnimations()
    let viewport = model.viewport(1)
    check viewport.currentViewportXOffset == 100.0'f32
    check viewport.currentViewportYOffset == 50.0'f32
    check not model.tickAnimations()

  test "Frame ticks are only demanded for active timed work":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          enableAnimations: true, animationSpeed: 0.0, animationSnapThreshold: 0.5
        ),
        layoutSwitchToast: LayoutSwitchToastConfig(enabled: true, timeoutMs: 16),
        workspaces: WorkspaceConfig(defaultCount: 1),
      )
    ).model

    check not model.needsFrameTick()

    model.setViewport(1, targetX = 100.0, currentX = 0.0)
    check model.hasPendingViewportAnimation()
    check model.needsFrameTick()
    check model.tickAnimations()
    check not model.hasPendingViewportAnimation()
    check not model.needsFrameTick()

    check model.openLayoutSwitchToast(LayoutMode.Deck)
    check model.needsFrameTick()
    check model.tickLayoutSwitchToast(16)
    check not model.needsFrameTick()

  test "Switching to non-scroller layout clears stale viewport offset":
    var baseline = cameraModel()
    baseline.seedCameraWindows(4)
    baseline.applyMsg(Msg(kind: MsgKind.CmdSwitchLayout))
    let baselineGeom = baseline.instructionGeom(1)

    var model = cameraModel()
    model.seedCameraWindows(4)
    model.setViewport(
      1, targetX = 636.0, currentX = 636.0, targetY = 25.0, currentY = 25.0
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSwitchLayout))

    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check model.viewport(1).currentViewportXOffset == 0.0'f32
    check model.viewport(1).targetViewportYOffset == 0.0'f32
    check model.viewport(1).currentViewportYOffset == 0.0'f32
    let geom = model.instructionGeom(1)
    check geom.x == baselineGeom.x
    check geom.y == baselineGeom.y

  test "Switching to bundled Janet layout clears stale viewport offset":
    var baseline = cameraModel()
    baseline.seedCameraWindows(4)
    baseline.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("right-tile"))
    )
    let baselineGeom = baseline.instructionGeom(1)

    var model = cameraModel()
    model.seedCameraWindows(4)
    model.setViewport(
      1, targetX = 636.0, currentX = 636.0, targetY = 25.0, currentY = 25.0
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("right-tile"))
    )

    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check model.viewport(1).currentViewportXOffset == 0.0'f32
    check model.viewport(1).targetViewportYOffset == 0.0'f32
    check model.viewport(1).currentViewportYOffset == 0.0'f32
    let geom = model.instructionGeom(1)
    check geom.x == baselineGeom.x
    check geom.y == baselineGeom.y

  test "Bundled grid ignores stale BSP substrate after layout switch":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Window 3")
    )

    let projection = model.layoutProjection()
    let first = projection.instructions.filterIt(uint32(it.windowId) == 1)[0]
    let third = projection.instructions.filterIt(uint32(it.windowId) == 3)[0]

    check projection.instructions.len == 3
    check projection.viewportTargets.len == 0
    check third.geom.y > first.geom.y

  test "Custom layout movement hook can reorder tiled window order":
    var model = cameraModel()
    model.seedCameraWindows(4)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("spiral"))
    )
    model.focusExternal(3)

    check model.activeTiledOrder() == @[1'u32, 2, 3, 4]

    var effects: seq[Effect]
    (model, effects) = model.update(Msg(kind: MsgKind.CmdMoveWindowUp), spiralMovement)
    check effects.len > 0
    check model.activeTiledOrder() == @[1'u32, 3, 2, 4]
    check model.focusedWindowId() == 3

    (model, effects) =
      model.update(Msg(kind: MsgKind.CmdMoveWindowLeft), spiralMovement)
    check effects.len == 0
    check model.activeTiledOrder() == @[1'u32, 3, 2, 4]

    (model, effects) =
      model.update(Msg(kind: MsgKind.CmdMoveWindowDown), spiralMovement)
    check effects.len > 0
    check model.activeTiledOrder() == @[1'u32, 2, 3, 4]
    check model.focusedWindowId() == 3

  test "Built-in layout movement mirrors directional focus target":
    for mode in [
      LayoutMode.Scroller, LayoutMode.VerticalScroller, LayoutMode.MasterStack,
      LayoutMode.RightTile, LayoutMode.CenterTile, LayoutMode.VerticalTile,
      LayoutMode.Grid, LayoutMode.VerticalGrid, LayoutMode.Deck,
      LayoutMode.VerticalDeck, LayoutMode.Monocle,
    ]:
      let base = directionalModel(mode, 6)
      for direction in [
        Direction.DirLeft, Direction.DirRight, Direction.DirUp, Direction.DirDown
      ]:
        base.checkMoveMirrorsNavigation(3, direction)

  test "Built-in fallback pointer move works without split resize":
    var model = directionalModel(LayoutMode.Grid, 4)
    let start = model.instructionGeom(4).rectCenter()
    let target = model.instructionGeom(1)
    let dropX = target.x + 1
    let dropY = target.y + target.h div 2

    check model.beginPointerMove(ExternalWindowId(4), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.pointerDropPreview().found
    discard model.finishPointerOp()

    check model.activeTiledOrder() == @[4'u32, 1, 2, 3]

    let geom = model.instructionGeom(4)
    check not model.beginPointerResize(
      ExternalWindowId(4), 0'u32, geom.x + geom.w - 1, geom.y + geom.h div 2
    )

  test "Tiled pointer move below threshold does not reorder scroller windows":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let start = model.instructionGeom(1).rectCenter()

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(4, 4)
    check not model.pointerDropPreview().found
    discard model.finishPointerOp()

    check model.activeTiledOrder() == @[1'u32, 2, 3]

  test "Tiled pointer move previews first scroller column drop":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let screen = model.primaryScreen()
    let first = model.instructionGeom(1)
    let start = model.instructionGeom(3).rectCenter()
    let dropX = first.x - 8
    let dropY = first.y + first.h div 2

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)

    let preview = model.pointerDropPreview()
    check preview.found
    check preview.rect.w == 300
    check preview.rect.h == screen.h - model.outerGaps * 2
    check preview.rect.x == screen.x + model.outerGaps - preview.rect.w div 2
    check preview.rect.y == screen.y + model.outerGaps

  test "Tiled pointer move previews last scroller column drop":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let screen = model.primaryScreen()
    let last = model.instructionGeom(3)
    let start = model.instructionGeom(1).rectCenter()
    let dropX = last.x + last.w + 8
    let dropY = last.y + last.h div 2

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)

    let preview = model.pointerDropPreview()
    check preview.found
    check preview.rect.w == 300
    check preview.rect.h == screen.h - model.outerGaps * 2
    check preview.rect.x == screen.x + screen.w - model.outerGaps - preview.rect.w div 2
    check preview.rect.y == screen.y + model.outerGaps

  test "Tiled pointer move previews stack insertion in scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowOneIntoTwo()

    let start = model.instructionGeom(3).rectCenter()
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w div 2
    let dropY = target.y + target.h - 1

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)

    let preview = model.pointerDropPreview()
    check preview.found
    check preview.rect.w == target.w
    check preview.rect.h in [150'i32, 300'i32]
    check preview.rect.x == target.x
    check preview.rect.y >= target.y

  test "Tiled pointer move previews vertical scroller row drop":
    var model = directionalModel(LayoutMode.VerticalScroller, 3)
    let screen = model.primaryScreen()
    let last = model.instructionGeom(3)
    let start = model.instructionGeom(1).rectCenter()
    let dropX = last.x + last.w div 2
    let dropY = last.y + last.h + 8

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)

    let preview = model.pointerDropPreview()
    check preview.found
    check preview.rect.w == screen.w - model.outerGaps * 2
    check preview.rect.h == 300
    check preview.rect.x == screen.x + model.outerGaps
    check preview.rect.y == screen.y + screen.h - model.outerGaps - preview.rect.h div 2

  test "Tiled pointer move hides scroller drop preview in floating drop mode":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let start = model.activatePointerDrag(1)
    let target = model.instructionGeom(2)

    model.applyPointerDrop(start, target.x + target.w div 2, target.y + target.h div 2)
    check model.pointerDropPreview().found
    check model.togglePointerDropMode()
    check not model.pointerDropPreview().found

  test "Tiled pointer move can structurally reorder scroller columns":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let start = model.activatePointerDrag(1)
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w - 2
    let dropY = target.y + target.h div 2

    model.applyPointerDrop(start, dropX, dropY)
    let dragged = model.instructionGeom(1)
    check dragged.x == model.pointerOp.initialGeom.x + model.pointerOp.totalDX
    discard model.finishPointerOp()

    check model.activeTiledOrder() == @[2'u32, 1, 3]
    check model.focusedWindowId() == 1

  test "Tiled pointer move can drop before first scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let start = model.instructionGeom(3).rectCenter()
    let first = model.instructionGeom(1)
    let dropX = first.x - 8
    let dropY = first.y + first.h div 2

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)
    discard model.finishPointerOp()

    check model.activeTiledOrder() == @[3'u32, 1, 2]

  test "Tiled pointer move can drop after last scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    let start = model.instructionGeom(1).rectCenter()
    let last = model.instructionGeom(3)
    let dropX = last.x + last.w + 8
    let dropY = last.y + last.h div 2

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)
    discard model.finishPointerOp()

    check model.activeTiledOrder() == @[2'u32, 3, 1]

  test "Tiled pointer move can drop into an existing scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowOneIntoTwo()

    let first = model.placementForExternal(1)
    let second = model.placementForExternal(2)
    check first.columnId == second.columnId
    check first.windowIdx == 2
    check model.activeTiledOrder() == @[2'u32, 1, 3]

  test "Tiled pointer move near scroller stack side creates sibling column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowOneIntoTwo()

    let start = model.instructionGeom(3).rectCenter()
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w + max(0'i32, model.innerGaps) - 1
    let dropY = target.y + target.h - 1

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId != second.columnId
    check third.windowIdx == 1
    check model.activeTiledOrder() == @[2'u32, 1, 3]

  test "Tiled pointer move near scroller stack middle still stacks":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowOneIntoTwo()

    let start = model.instructionGeom(3).rectCenter()
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w div 2
    let dropY = target.y + target.h - 1

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId == second.columnId
    check third.windowIdx == 2

  test "Tiled pointer move can reorder to top of same scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowThreeIntoTwoColumn()

    let start = model.activatePointerDrag(3)
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w div 2
    let dropY = target.y

    model.applyPointerDrop(start, dropX, dropY)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId == second.columnId
    check third.windowIdx == 1
    check model.activeTiledOrder() == @[3'u32, 2, 1]

  test "Tiled pointer move can reorder to middle of same scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowThreeIntoTwoColumn()

    let start = model.activatePointerDrag(3)
    let target = model.instructionGeom(1)
    let dropX = target.x + target.w div 2
    let dropY = target.y

    model.applyPointerDrop(start, dropX, dropY)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId == second.columnId
    check third.windowIdx == 2
    check model.activeTiledOrder() == @[2'u32, 3, 1]

  test "Tiled pointer move can reorder to bottom of same scroller column":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.stackWindowThreeIntoTwoColumn()

    let start = model.activatePointerDrag(2)
    let target = model.instructionGeom(3)
    let dropX = target.x + target.w div 2
    let dropY = target.y + target.h + max(0'i32, model.innerGaps) - 1

    model.applyPointerDrop(start, dropX, dropY)
    discard model.finishPointerOp()

    let second = model.placementForExternal(2)
    let third = model.placementForExternal(3)
    check second.columnId == third.columnId
    check second.windowIdx == 3
    check model.activeTiledOrder() == @[1'u32, 3, 2]

  test "Tiled pointer move near vertical scroller stack side creates sibling row":
    var model = directionalModel(LayoutMode.VerticalScroller, 3)
    model.stackWindowOneIntoTwoVertical()

    let start = model.instructionGeom(3).rectCenter()
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w - 1
    let dropY = target.y + target.h + max(0'i32, model.innerGaps) - 1

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId != second.columnId
    check third.windowIdx == 1

  test "Tiled pointer move can reorder within same vertical scroller row":
    var model = directionalModel(LayoutMode.VerticalScroller, 3)
    model.stackWindowThreeIntoTwoRow()

    let start = model.activatePointerDrag(3)
    let target = model.instructionGeom(1)
    let dropX = target.x
    let dropY = target.y + target.h div 2

    model.applyPointerDrop(start, dropX, dropY)
    discard model.finishPointerOp()

    let third = model.placementForExternal(3)
    let second = model.placementForExternal(2)
    check third.columnId == second.columnId
    check third.windowIdx == 2
    check model.activeTiledOrder() == @[2'u32, 3, 1]

  test "Tiled pointer move can start from a non-active output scroller workspace":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let targetGeom = model.instructionGeom(2)
    let start = targetGeom.rectCenter()
    model.applyMsg(
      Msg(
        kind: MsgKind.WlPointerMoveRequested,
        moveWinId: 2,
        moveSeat: nil,
        moveStartX: start.x,
        moveStartY: start.y,
      )
    )

    check model.activeWorkspaceSlot() == 1
    check model.pointerOp.kind == PointerOpKind.OpMove
    check model.pointerOp.sourceTag == model.tagForSlot(2)
    check model.pointerOp.initialGeom == targetGeom
    check model.applyPointerDelta(9, 0, start.x + 9, start.y)
    check model.pointerOp.dragActive

  test "Tiled pointer move commit is stable after active workspace changes":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let start = model.instructionGeom(1).rectCenter()
    let dropX = 1200'i32
    let dropY = 350'i32

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.pointerOp.dropTag == model.tagForSlot(2)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    discard model.finishPointerOp()

    check model.placementForExternalOnSlot(2, 1).found
    check not model.placementForExternalOnSlot(1, 1).found

  test "Tiled pointer move can drop across vertically stacked outputs":
    var model = configuredModel()
    model.setupStackedOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let start = model.instructionGeom(1).rectCenter()
    let dropX = 500'i32
    let dropY = 1000'i32

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    discard model.finishPointerOp()

    check model.placementForExternalOnSlot(2, 1).found
    check model.activeWorkspaceSlot() == 2

  test "Tiled pointer move can drop onto an output with negative coordinates":
    var model = configuredModel()
    model.setupNegativeOffsetOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let start = model.instructionGeom(1).rectCenter()
    let dropX = -450'i32
    let dropY = 350'i32

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    discard model.finishPointerOp()

    check model.placementForExternalOnSlot(2, 1).found
    check model.activeWorkspaceSlot() == 2

  test "Tiled pointer move can drop into another output scroller workspace":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let start = model.instructionGeom(1).rectCenter()
    let target = model.instructionGeom(2)
    let dropX = target.x + target.w div 2
    let dropY = target.y + (target.h * 3) div 4

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    discard model.finishPointerOp()

    let moved = model.placementForExternalOnSlot(2, 1)
    let targetPlacement = model.placementForExternalOnSlot(2, 2)
    check moved.found
    check targetPlacement.found
    check moved.columnId == targetPlacement.columnId
    check moved.windowIdx == 2
    check model.activeWorkspaceSlot() == 2
    check model.focusedWindowId() == 1

  test "Tiled pointer drag remains render-visible across outputs before drop":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let sourceScreen = model.activeWorkspaceScreen()
    let target = model.instructionGeom(2)
    let start = model.instructionGeom(1).rectCenter()
    let dropX = target.x + target.w div 2
    let dropY = target.y + target.h div 2

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)

    let dragged = model.projectedInstruction(1)
    let allOutputBounds = model.overviewDragVisibilityBounds()
    let sourceVisibility = renderVisibility(dragged.geom, sourceScreen, 4)
    let allOutputVisibility = renderVisibility(dragged.geom, allOutputBounds, 4)
    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    let visibilityBounds = daemon.desiredVisibilityBounds(1)
    let state =
      daemon.desiredRenderWindowState(1, dragged.geom, visibilityBounds, false)

    check model.draggedPointerRiverId() == 1
    check uint32(dragged.windowId) == 1
    check dragged.geom.x < sourceScreen.x + sourceScreen.w
    check dragged.geom.x + dragged.geom.w > sourceScreen.x + sourceScreen.w
    check sourceVisibility.visible
    check sourceVisibility.clipped
    check sourceVisibility.clipW < dragged.geom.w
    check allOutputVisibility.visible
    check not allOutputVisibility.clipped
    check visibilityBounds == allOutputBounds
    check state.visible

  test "Floating windows stay above the focused tiled window":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(kind: MsgKind.WlWindowCreated, windowId: id, appId: "app", title: $id)
      )
    let geom = Rect(x: 100, y: 100, w: 400, h: 300)
    for id in [2'u32, 3'u32]:
      check model.setWindowFloating(
        model.windowForExternal(ExternalWindowId(id)), true, geom
      )
    var ids = @[1'u32, 2'u32, 3'u32]
    model.sortStackIds(ids)

    model.focusExternal(3)
    model.focusExternal(2)
    model.focusExternal(1)
    check model.stackOrder(ids) == @[1'u32, 3'u32, 2'u32]

    model.focusExternal(3)
    check model.stackOrder(ids) == @[1'u32, 2'u32, 3'u32]

  test "Focused fullscreen covers floating windows and maximized does not":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    for id in 1'u32 .. 2'u32:
      model.applyMsg(
        Msg(kind: MsgKind.WlWindowCreated, windowId: id, appId: "app", title: $id)
      )
    check model.setWindowFloating(
      model.windowForExternal(ExternalWindowId(2)),
      true,
      Rect(x: 100, y: 100, w: 400, h: 300),
    )
    var ids = @[1'u32, 2'u32]
    model.sortStackIds(ids)

    model.focusExternal(1)
    model.applyMsg(Msg(kind: MsgKind.CmdToggleMaximized))
    check model.effectivelyMaximizedForRiverId(1)
    check model.stackOrder(ids) == @[1'u32, 2'u32]

    model.applyMsg(Msg(kind: MsgKind.CmdToggleMaximized))
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFullscreen))
    check model.modelWindow(1).isFullscreen
    check model.stackOrder(ids) == @[2'u32, 1'u32]

    model.focusExternal(2)
    check model.stackOrder(ids) == @[1'u32, 2'u32]

  test "Fullscreen app stays above floating windows while its dialog has focus":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    for id in 1'u32 .. 2'u32:
      model.applyMsg(
        Msg(kind: MsgKind.WlWindowCreated, windowId: id, appId: "app", title: $id)
      )
    check model.setWindowFloating(
      model.windowForExternal(ExternalWindowId(2)),
      true,
      Rect(x: 100, y: 100, w: 400, h: 300),
    )
    model.focusExternal(1)
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFullscreen))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    check model.focusedWindowId() == 3
    var ids = @[1'u32, 2'u32, 3'u32]
    model.sortStackIds(ids)
    check model.stackOrder(ids) == @[2'u32, 1'u32, 3'u32]

  test "Floating window past the screen edge keeps its on-screen borders":
    var model = configuredModel()
    model.borderWidth = 2
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    let screen = model.activeWorkspaceScreen()
    let offLeft = Rect(x: screen.x - 100, y: screen.y + 50, w: 400, h: 300)
    check model.setWindowFloating(
      model.windowForExternal(ExternalWindowId(1)), true, offLeft
    )

    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    let floating = daemon.desiredRenderWindowState(1, offLeft, screen, false)
    let tiled = daemon.desiredRenderWindowState(2, offLeft, screen, false)

    check floating.keepVisibleBorders
    check floating.borderEdges == (RenderAllEdges and not RenderEdgeLeft)
    check not tiled.keepVisibleBorders
    check tiled.borderEdges == (RenderEdgeTop or RenderEdgeBottom)

  test "Tiled pointer drag at source output seam autoscrolls source scroller":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    let leftOutput = model.outputForExternal(ExternalOutputId(1))
    let rightOutput = model.outputForExternal(ExternalOutputId(2))
    let rightTag = model.tagForSlot(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.setViewport(3, targetX = 300.0, currentX = 300.0)

    let rightScreen = model.outputScreen(rightOutput)
    let start = model.instructionGeom(3).rectCenter()
    let dropX = rightScreen.x - 10
    let dropY = start.y
    let before = model.viewport(3)

    check model.workspaceOutput(rightTag) == rightOutput
    check model.outputActiveTag(leftOutput) == model.tagForSlot(1)
    check start.x >= rightScreen.x
    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.pointerOp.dropTag == rightTag
    check model.pointerOp.dropOutput == rightOutput
    check model.activeScrollerPointerDrag()
    check model.tickPointerDragAutoScroll(16)
    check model.pointerOp.dragAutoScrollElapsedMs == 16
    check model.tickPointerDragAutoScroll(84)
    check model.viewport(3).currentViewportXOffset < before.currentViewportXOffset

    discard model.finishPointerOp()

    check model.placementForExternalOnSlot(3, 3).found
    check not model.placementForExternalOnSlot(1, 3).found
    check model.activeWorkspaceSlot() == 3
    check model.activeOutput == rightOutput
    check model.outputActiveTag(leftOutput) == model.tagForSlot(1)

  test "Tiled pointer drag beyond source seam can drop on adjacent output":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    let leftOutput = model.outputForExternal(ExternalOutputId(1))
    let rightOutput = model.outputForExternal(ExternalOutputId(2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )

    let start = model.instructionGeom(3).rectCenter()
    let dropX =
      model.outputScreen(leftOutput).x + model.outputScreen(leftOutput).w div 2
    let dropY = start.y

    check model.workspaceOutput(model.tagForSlot(3)) == rightOutput
    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.pointerOp.dropTag == model.tagForSlot(1)
    check model.pointerOp.dropOutput == leftOutput
    discard model.finishPointerOp()

    let moved = model.placementForExternalOnSlot(1, 3)
    check moved.found
    check not model.placementForExternalOnSlot(3, 3).found
    check model.activeWorkspaceSlot() == 1
    check model.activeOutput == leftOutput

  test "Tiled pointer move can drop into empty scroller workspace on another output":
    var model = configuredModel()
    model.setupSideBySideOutputs()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: "DP-2"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    let start = model.instructionGeom(1).rectCenter()
    let dropX = 1200'i32
    let dropY = 350'i32

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    discard model.finishPointerOp()

    let moved = model.placementForExternalOnSlot(2, 1)
    check moved.found
    check moved.windowIdx == 1
    check model.activeWorkspaceSlot() == 2

  test "Tiled pointer drag autoscrolls scroller viewport near output edge":
    var model = cameraModel()
    model.seedCameraWindows(6)
    let start = model.instructionGeom(1).rectCenter()
    let dropX = 999'i32
    let dropY = start.y
    let before = model.viewport(1)

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.activeScrollerPointerDrag()
    check model.tickPointerDragAutoScroll(16)
    check model.viewport(1).currentViewportXOffset == before.currentViewportXOffset
    check model.pointerOp.dragAutoScrollElapsedMs == 16
    check model.tickPointerDragAutoScroll(84)
    let after = model.viewport(1)
    check after.currentViewportXOffset > before.currentViewportXOffset
    check after.targetViewportXOffset == after.currentViewportXOffset

  test "Tiled pointer drag autoscrolls vertical scroller viewport near output edge":
    var model = directionalModel(LayoutMode.VerticalScroller, 6)
    let screen = model.primaryScreen()
    let start = model.instructionGeom(1).rectCenter()
    let dropX = start.x
    let dropY = screen.y + screen.h - 1
    let before = model.viewport(1)

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.tickPointerDragAutoScroll(16)
    check model.viewport(1).currentViewportYOffset == before.currentViewportYOffset
    check model.pointerOp.dragAutoScrollElapsedMs == 16
    check model.tickPointerDragAutoScroll(84)

    let after = model.viewport(1)
    check after.currentViewportYOffset > before.currentViewportYOffset
    check after.targetViewportYOffset == after.currentViewportYOffset
    check after.currentViewportXOffset == before.currentViewportXOffset

  test "Tiled pointer resize adjusts scroller column width from edge drag":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h div 2
    let placement = model.placementForExternal(1)
    let before = model.column(placement.columnId).get().widthProportion

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(100, 0)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > before

  test "Tiled pointer resize center fallback uses binding edges":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)
    let center = geom.rectCenter()
    let placement = model.placementForExternal(1)
    let beforeWidth = model.column(placement.columnId).get().widthProportion
    let beforeHeight = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, center.x, center.y)
    check model.applyPointerDelta(100, 100)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.modelWindow(1).heightProportion > beforeHeight
    check model.instructionGeom(1).h > beforeGeom.h

  test "Tiled pointer corner resize tracks secondary height immediately":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + 1
    let placement = model.placementForExternal(1)
    let beforeWidth = model.column(placement.columnId).get().widthProportion
    let beforeHeight = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, startX, startY)
    check model.applyPointerDelta(100, 20)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.modelWindow(1).heightProportion < beforeHeight
    check model.instructionGeom(1).h < beforeGeom.h

  test "Tiled pointer corner resize tracks secondary width immediately":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h - 1
    let placement = model.placementForExternal(1)
    let beforeWidth = model.column(placement.columnId).get().widthProportion
    let beforeHeight = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, startX, startY)
    check model.applyPointerDelta(20, 100)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.modelWindow(1).heightProportion > beforeHeight
    check model.instructionGeom(1).w > beforeGeom.w

  test "Tiled pointer resize can add height after width-dominant start":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h - 1
    let placement = model.placementForExternal(1)
    let beforeWidth = model.column(placement.columnId).get().widthProportion
    let beforeHeight = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, startX, startY)
    check model.applyPointerDelta(100, 0)
    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.instructionGeom(1).h == beforeGeom.h

    check model.applyPointerDelta(100, 100)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.modelWindow(1).heightProportion > beforeHeight
    check model.instructionGeom(1).h > beforeGeom.h

  test "Tiled pointer resize can add width after height-dominant start":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h - 1
    let placement = model.placementForExternal(1)
    let beforeWidth = model.column(placement.columnId).get().widthProportion
    let beforeHeight = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 10'u32, startX, startY)
    check model.applyPointerDelta(0, 100)
    check model.modelWindow(1).heightProportion > beforeHeight
    check model.instructionGeom(1).w == beforeGeom.w

    check model.applyPointerDelta(100, 100)
    discard model.finishPointerOp()

    check model.column(placement.columnId).get().widthProportion > beforeWidth
    check model.modelWindow(1).heightProportion > beforeHeight
    check model.instructionGeom(1).w > beforeGeom.w

  test "Tiled pointer resize adjusts scroller window height from edge drag":
    var model = cameraModel()
    model.seedCameraWindows(2)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w div 2
    let startY = geom.y + geom.h - 1
    let before = model.modelWindow(1).heightProportion
    let beforeGeom = model.instructionGeom(1)

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, 100)
    discard model.finishPointerOp()

    check model.modelWindow(1).heightProportion > before
    check model.instructionGeom(1).h > beforeGeom.h

  test "Tiled pointer resize caps scroller window height at viewport":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let screen = model.primaryScreen()
    let usableHeight = screen.h - 2 * model.outerGaps
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w div 2
    let startY = geom.y + geom.h - 1

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, screen.h * 2)
    discard model.finishPointerOp()

    let resized = model.instructionGeom(1)
    check model.modelWindow(1).heightProportion == 1.0'f32
    check resized.h == usableHeight
    check resized.y == screen.y + model.outerGaps

  test "Tiled pointer resize lets scroller column width exceed viewport":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let screen = model.primaryScreen()
    let usableWidth = screen.w - 2 * model.outerGaps
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h div 2
    let placement = model.placementForExternal(1)

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(screen.w * 2, 0)
    discard model.finishPointerOp()

    let resized = model.instructionGeom(1)
    check model.column(placement.columnId).get().widthProportion > 1.0'f32
    check resized.w > usableWidth

  test "Tiled pointer resize clamps scroller column width to max-width":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let before = model.instructionGeom(1)
    let maxWidth = before.w + 80
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowDimensionsHint, hintWindowId: 1, maxWidth: maxWidth)
    )
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h div 2

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(model.primaryScreen().w * 2, 0)
    discard model.finishPointerOp()

    check model.instructionGeom(1).w == maxWidth

  test "Tiled pointer resize clamps scroller window height to max-height":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let before = model.instructionGeom(1)
    let maxHeight = before.h + 80
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowDimensionsHint, hintWindowId: 1, maxHeight: maxHeight)
    )
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w div 2
    let startY = geom.y + geom.h - 1

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, model.primaryScreen().h * 2)
    discard model.finishPointerOp()

    check model.instructionGeom(1).h == maxHeight

  test "Tiled pointer diagonal resize clamps like straight scroller axes":
    var straightWidth = cameraModel()
    straightWidth.seedCameraWindows(1)
    var straightHeight = cameraModel()
    straightHeight.seedCameraWindows(1)
    var diagonal = cameraModel()
    diagonal.seedCameraWindows(1)

    let winId = straightHeight.windowForExternal(ExternalWindowId(1))
    check straightHeight.setWindowHeightProportion(winId, 0.5)
    let diagonalWinId = diagonal.windowForExternal(ExternalWindowId(1))
    check diagonal.setWindowHeightProportion(diagonalWinId, 0.5)

    let base = diagonal.instructionGeom(1)
    let maxWidth = base.w + 80
    let maxHeight = diagonal.instructionGeom(1).h + 80
    for model in [addr straightWidth, addr straightHeight, addr diagonal]:
      model[].applyMsg(
        Msg(
          kind: MsgKind.WlWindowDimensionsHint,
          hintWindowId: 1,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        )
      )

    let widthGeom = straightWidth.instructionGeom(1)
    check straightWidth.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      widthGeom.x + widthGeom.w - 1,
      widthGeom.y + widthGeom.h div 2,
    )
    check straightWidth.applyPointerDelta(straightWidth.primaryScreen().w * 2, 0)
    discard straightWidth.finishPointerOp()

    let heightGeom = straightHeight.instructionGeom(1)
    check straightHeight.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      heightGeom.x + heightGeom.w div 2,
      heightGeom.y + heightGeom.h - 1,
    )
    check straightHeight.applyPointerDelta(0, straightHeight.primaryScreen().h * 2)
    discard straightHeight.finishPointerOp()

    let diagonalGeom = diagonal.instructionGeom(1)
    check diagonal.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      diagonalGeom.x + diagonalGeom.w - 1,
      diagonalGeom.y + diagonalGeom.h - 1,
    )
    check diagonal.applyPointerDelta(
      diagonal.primaryScreen().w * 2, diagonal.primaryScreen().h * 2
    )
    discard diagonal.finishPointerOp()

    check diagonal.instructionGeom(1).w == straightWidth.instructionGeom(1).w
    check diagonal.instructionGeom(1).h == straightHeight.instructionGeom(1).h

  test "Tiled pointer diagonal resize resumes from clamped scroller geometry":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowHeightProportion(winId, 0.5)
    let before = model.instructionGeom(1)
    let maxWidth = before.w + 80
    let maxHeight = before.h + 80
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 1,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      )
    )

    let growGeom = model.instructionGeom(1)
    check model.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      growGeom.x + growGeom.w - 1,
      growGeom.y + growGeom.h - 1,
    )
    check model.applyPointerDelta(
      model.primaryScreen().w * 2, model.primaryScreen().h * 2
    )
    discard model.finishPointerOp()
    check model.instructionGeom(1).w == maxWidth
    check model.instructionGeom(1).h == maxHeight

    let shrinkGeom = model.instructionGeom(1)
    check model.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      shrinkGeom.x + shrinkGeom.w - 1,
      shrinkGeom.y + shrinkGeom.h - 1,
    )
    check model.applyPointerDelta(-40, -40)
    discard model.finishPointerOp()

    check model.instructionGeom(1).w == maxWidth - 40
    check model.instructionGeom(1).h == maxHeight - 40

  test "Vertical scroller pointer resize caps window width at viewport":
    var model = directionalModel(LayoutMode.VerticalScroller, 1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowWidthProportion(winId, 0.5)
    let screen = model.primaryScreen()
    let usableWidth = screen.w - 2 * model.outerGaps
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h div 2

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(screen.w * 2, 0)
    discard model.finishPointerOp()

    let resized = model.instructionGeom(1)
    check model.modelWindow(1).widthProportion == 1.0'f32
    check resized.x == screen.x + model.outerGaps
    check resized.w == usableWidth

  test "Vertical scroller pointer resize clamps window width to max-width":
    var model = directionalModel(LayoutMode.VerticalScroller, 1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowWidthProportion(winId, 0.5)
    let before = model.instructionGeom(1)
    let maxWidth = before.w + 80
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowDimensionsHint, hintWindowId: 1, maxWidth: maxWidth)
    )
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w - 1
    let startY = geom.y + geom.h div 2

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(model.primaryScreen().w * 2, 0)
    discard model.finishPointerOp()

    check model.instructionGeom(1).w == maxWidth

  test "Vertical scroller pointer resize lets row height exceed viewport":
    var model = directionalModel(LayoutMode.VerticalScroller, 1)
    let screen = model.primaryScreen()
    let usableHeight = screen.h - 2 * model.outerGaps
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w div 2
    let startY = geom.y + geom.h - 1
    let placement = model.placementForExternal(1)

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, screen.h * 2)
    discard model.finishPointerOp()

    let resized = model.instructionGeom(1)
    check model.column(placement.columnId).get().widthProportion > 1.0'f32
    check resized.h > usableHeight

  test "Vertical scroller pointer resize clamps row height to max-height":
    var model = directionalModel(LayoutMode.VerticalScroller, 1)
    let before = model.instructionGeom(1)
    let maxHeight = before.h + 80
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowDimensionsHint, hintWindowId: 1, maxHeight: maxHeight)
    )
    let geom = model.instructionGeom(1)
    let startX = geom.x + geom.w div 2
    let startY = geom.y + geom.h - 1

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, model.primaryScreen().h * 2)
    discard model.finishPointerOp()

    check model.instructionGeom(1).h == maxHeight

  test "Vertical scroller pointer diagonal resize clamps like straight axes":
    var straightWidth = directionalModel(LayoutMode.VerticalScroller, 1)
    var straightHeight = directionalModel(LayoutMode.VerticalScroller, 1)
    var diagonal = directionalModel(LayoutMode.VerticalScroller, 1)

    let widthWinId = straightWidth.windowForExternal(ExternalWindowId(1))
    check straightWidth.setWindowWidthProportion(widthWinId, 0.5)
    let diagonalWinId = diagonal.windowForExternal(ExternalWindowId(1))
    check diagonal.setWindowWidthProportion(diagonalWinId, 0.5)

    let base = diagonal.instructionGeom(1)
    let maxWidth = base.w + 80
    let maxHeight = straightHeight.instructionGeom(1).h + 80
    for model in [addr straightWidth, addr straightHeight, addr diagonal]:
      model[].applyMsg(
        Msg(
          kind: MsgKind.WlWindowDimensionsHint,
          hintWindowId: 1,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        )
      )

    let widthGeom = straightWidth.instructionGeom(1)
    check straightWidth.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      widthGeom.x + widthGeom.w - 1,
      widthGeom.y + widthGeom.h div 2,
    )
    check straightWidth.applyPointerDelta(straightWidth.primaryScreen().w * 2, 0)
    discard straightWidth.finishPointerOp()

    let heightGeom = straightHeight.instructionGeom(1)
    check straightHeight.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      heightGeom.x + heightGeom.w div 2,
      heightGeom.y + heightGeom.h - 1,
    )
    check straightHeight.applyPointerDelta(0, straightHeight.primaryScreen().h * 2)
    discard straightHeight.finishPointerOp()

    let diagonalGeom = diagonal.instructionGeom(1)
    check diagonal.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      diagonalGeom.x + diagonalGeom.w - 1,
      diagonalGeom.y + diagonalGeom.h - 1,
    )
    check diagonal.applyPointerDelta(
      diagonal.primaryScreen().w * 2, diagonal.primaryScreen().h * 2
    )
    discard diagonal.finishPointerOp()

    check diagonal.instructionGeom(1).w == straightWidth.instructionGeom(1).w
    check diagonal.instructionGeom(1).h == straightHeight.instructionGeom(1).h

  test "Vertical scroller pointer diagonal resize resumes from clamped geometry":
    var model = directionalModel(LayoutMode.VerticalScroller, 1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    check model.setWindowWidthProportion(winId, 0.5)
    let before = model.instructionGeom(1)
    let maxWidth = before.w + 80
    let maxHeight = before.h + 80
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 1,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      )
    )

    let growGeom = model.instructionGeom(1)
    check model.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      growGeom.x + growGeom.w - 1,
      growGeom.y + growGeom.h - 1,
    )
    check model.applyPointerDelta(
      model.primaryScreen().w * 2, model.primaryScreen().h * 2
    )
    discard model.finishPointerOp()
    check model.instructionGeom(1).w == maxWidth
    check model.instructionGeom(1).h == maxHeight

    let shrinkGeom = model.instructionGeom(1)
    check model.beginPointerResize(
      ExternalWindowId(1),
      0'u32,
      shrinkGeom.x + shrinkGeom.w - 1,
      shrinkGeom.y + shrinkGeom.h - 1,
    )
    check model.applyPointerDelta(-40, -40)
    discard model.finishPointerOp()

    check model.instructionGeom(1).w == maxWidth - 40
    check model.instructionGeom(1).h == maxHeight - 40

  test "Scroller command resize caps window height at viewport":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let screen = model.primaryScreen()
    let usableHeight = screen.h - 2 * model.outerGaps

    check model.setWindowHeightProportion(winId, 5.0)

    let geom = model.instructionGeom(1)
    check model.modelWindow(1).heightProportion == 1.0'f32
    check geom.h == usableHeight
    check geom.y == screen.y + model.outerGaps

  test "Scroller height resize ignores client max-height hint":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let screen = model.primaryScreen()
    let usableHeight = screen.h - 2 * model.outerGaps

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint, hintWindowId: 1, maxHeight: usableHeight
      )
    )
    check model.modelWindow(1).maxHeight == usableHeight
    check model.setWindowHeightProportion(winId, 5.0)

    let geom = model.instructionGeom(1)
    check model.modelWindow(1).heightProportion == 1.0'f32
    check geom.h == usableHeight
    check model.proposalDimensionsForRiverId(
      1, geom.w, geom.h, honorMinimums = false, honorMaximums = false
    ).h == geom.h
    check model.manageDimensionBoundsForRiverId(1) == (w: 0'i32, h: 0'i32)

  test "Window proportion state paths sanitize invalid resize proportions":
    var model = cameraModel()
    let added = model.addWindow(
      ExternalWindowId(90), widthProportion = 0.0'f32, heightProportion = float32(NaN)
    )
    check model.windowData(added).get().widthProportion == 0.05'f32
    check model.windowData(added).get().heightProportion == 1.0'f32

    check model.setWindowCreatedState(
      added, widthProportion = 0.0'f32, heightProportion = float32(NaN)
    )
    check model.windowData(added).get().widthProportion == 0.05'f32
    check model.windowData(added).get().heightProportion == 1.0'f32

    var source = model.windowData(added).get()
    source.widthProportion = 0.0'f32
    source.heightProportion = float32(NaN)
    check model.preserveWindowRuntimeAttributes(added, source)
    check model.windowData(added).get().widthProportion == 0.05'f32
    check model.windowData(added).get().heightProportion == 1.0'f32

    check model.setWindowRestoredState(
      added,
      RestoredWindowData(widthProportion: 0.0'f32, heightProportion: float32(NaN)),
    )
    check model.windowData(added).get().widthProportion == 0.05'f32
    check model.windowData(added).get().heightProportion == 1.0'f32

  test "Tiled pointer move drops frame-tree windows into target frame":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    let sourceFrame = model.frameForWindowOnTag(model.activeTag, WindowId(1))
    let targetFrame = model.frameForWindowOnTag(model.activeTag, WindowId(2))
    let start = model.instructionGeom(1).rectCenter()
    let target = model.instructionGeom(2).rectCenter()

    check sourceFrame != targetFrame
    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(target.x - start.x, target.y - start.y)
    discard model.finishPointerOp()

    check model.frameForWindowOnTag(model.activeTag, WindowId(1)) == targetFrame
    check model.focusedWindowId() == 1

  test "Tiled pointer move swaps BSP windows under cursor":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("bsp-tree"))
    )
    let firstBefore = model.instructionGeom(1)
    let secondBefore = model.instructionGeom(2)
    let start = firstBefore.rectCenter()
    let target = secondBefore.rectCenter()

    check model.beginPointerMove(ExternalWindowId(1), start.x, start.y)
    check model.applyPointerDelta(target.x - start.x, target.y - start.y)
    discard model.finishPointerOp()

    check model.instructionGeom(1) == secondBefore
    check model.instructionGeom(2) == firstBefore
    check model.focusedWindowId() == 1

  test "Tiled pointer resize adjusts native frame split ratio":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    let before = model.instructionGeom(1)
    let startX = before.x + before.w - 1
    let startY = before.y + before.h div 2

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(100, 0)
    discard model.finishPointerOp()

    check model.instructionGeom(1).w > before.w

  test "Tiled pointer resize adjusts native frame vertical split ratio":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitVertical))
    let before = model.instructionGeom(1)
    let startX = before.x + before.w div 2
    let startY = before.y + before.h - 1

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, 100)
    discard model.finishPointerOp()

    check model.instructionGeom(1).h > before.h

  test "Bundled Janet layout movement mirrors directional focus target":
    for layoutId in [
      "tile", "right-tile", "center-tile", "vertical-tile", "grid", "vertical-grid",
      "spiral", "dwindle", "deck", "vertical-deck", "monocle",
    ]:
      var base = directionalModel(LayoutMode.Scroller, 6)
      base.applyMsg(
        Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId(layoutId))
      )
      for direction in [
        Direction.DirLeft, Direction.DirRight, Direction.DirUp, Direction.DirDown
      ]:
        base.checkMoveMirrorsNavigation(3, direction)

  test "Bundled Janet tiled pointer move previews and reorders algorithmic layout":
    var model = directionalModel(LayoutMode.Scroller, 4)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tile"))
    )
    let start = model.instructionGeom(3).rectCenter()
    let target = model.instructionGeom(1)
    let dropX = target.x + 1
    let dropY = target.y + target.h div 2

    check model.beginPointerMove(ExternalWindowId(3), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)

    let preview = model.pointerDropPreview()
    check preview.found
    check preview.rect.x == target.x
    check preview.rect.y == target.y
    check preview.rect.w == target.w div 2
    check preview.rect.h == target.h

    discard model.finishPointerOp()

    check model.focusedWindowId() == 3
    check model.activeTiledOrder() == @[3'u32, 1, 2, 4]

  test "Bundled Janet tiled pointer move works for grid-shaped layout":
    var model = directionalModel(LayoutMode.Scroller, 4)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid"))
    )
    let start = model.instructionGeom(4).rectCenter()
    let target = model.instructionGeom(1)
    let dropX = target.x + 1
    let dropY = target.y + target.h div 2

    check model.beginPointerMove(ExternalWindowId(4), start.x, start.y)
    check model.applyPointerDelta(dropX - start.x, dropY - start.y, dropX, dropY)
    check model.pointerDropPreview().found
    discard model.finishPointerOp()

    check model.focusedWindowId() == 4
    check model.activeTiledOrder() == @[4'u32, 1, 2, 3]

  test "Bundled Janet tiled pointer resize adjusts horizontal master split":
    var model = directionalModel(LayoutMode.Scroller, 2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tile"))
    )
    let beforeRatio = model.tagData(model.activeTag).get().masterSplitRatio
    let beforeGeom = model.instructionGeom(1)
    let startX = beforeGeom.x + beforeGeom.w - 1
    let startY = beforeGeom.y + beforeGeom.h div 2

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(100, 0)
    discard model.finishPointerOp()

    check model.tagData(model.activeTag).get().masterSplitRatio > beforeRatio
    check model.instructionGeom(1).w > beforeGeom.w

  test "Bundled Janet tiled pointer resize adjusts vertical master split":
    var model = directionalModel(LayoutMode.Scroller, 2)
    model.applyMsg(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-tile")
      )
    )
    let beforeRatio = model.tagData(model.activeTag).get().masterSplitRatio
    let beforeGeom = model.instructionGeom(1)
    let startX = beforeGeom.x + beforeGeom.w div 2
    let startY = beforeGeom.y + beforeGeom.h - 1

    check model.beginPointerResize(ExternalWindowId(1), 0'u32, startX, startY)
    check model.applyPointerDelta(0, 100)
    discard model.finishPointerOp()

    check model.tagData(model.activeTag).get().masterSplitRatio > beforeRatio
    check model.instructionGeom(1).h > beforeGeom.h

  test "Bundled Janet move-only layouts reject tiled pointer resize":
    for layoutId in ["grid", "vertical-grid", "monocle", "spiral"]:
      var model = directionalModel(LayoutMode.Scroller, 4)
      model.applyMsg(
        Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId(layoutId))
      )
      let geom = model.instructionGeom(1)
      check not model.beginPointerResize(
        ExternalWindowId(1), 0'u32, geom.x + geom.w - 1, geom.y + geom.h div 2
      )

  test "Center tile side-stack movement swaps through center pane":
    var base = directionalModel(LayoutMode.CenterTile, 7)
    let centerBefore = base.instructionGeom(1)

    for leftId in [2'u32, 4, 6]:
      var model = base
      model.focusExternal(leftId)
      let sideBefore = model.instructionGeom(leftId)
      model.applyMsg(Msg(kind: MsgKind.CmdMoveWindowRight))
      check model.focusedWindowId() == leftId
      check model.instructionGeom(leftId) == centerBefore
      check model.instructionGeom(1) == sideBefore

    for rightId in [3'u32, 5, 7]:
      var model = base
      model.focusExternal(rightId)
      let sideBefore = model.instructionGeom(rightId)
      model.applyMsg(Msg(kind: MsgKind.CmdMoveWindowLeft))
      check model.focusedWindowId() == rightId
      check model.instructionGeom(rightId) == centerBefore
      check model.instructionGeom(1) == sideBefore

  test "Frame-tree movement swaps occupied directional target frames":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))

    let firstBefore = model.instructionGeom(1)
    let secondBefore = model.instructionGeom(2)
    model.focusExternal(2)
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWindowLeft))

    check model.focusedWindowId() == 2
    check model.instructionGeom(2) == firstBefore
    check model.instructionGeom(1) == secondBefore

  test "Frame-tree movement moves into empty directional target frames":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))

    let projection = model.layoutProjection()
    check projection.frameEmptyChrome.len == 1
    let emptyFrame = FrameId(projection.frameEmptyChrome[0].frameId)
    let emptyBefore = projection.frameEmptyChrome[0].geom

    model.applyMsg(Msg(kind: MsgKind.CmdMoveWindowRight))

    check model.focusedWindowId() == 1
    check model.windowsForFrame(emptyFrame) == @[WindowId(1)]
    check model.instructionGeom(1).x == emptyBefore.x
    check model.instructionGeom(1).w == emptyBefore.w

  test "Switching to native layout clears stale viewport offset":
    var model = cameraModel()
    model.seedCameraWindows(4)
    model.setViewport(
      1, targetX = 636.0, currentX = 636.0, targetY = 25.0, currentY = 25.0
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )

    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check model.viewport(1).currentViewportXOffset == 0.0'f32
    check model.viewport(1).targetViewportYOffset == 0.0'f32
    check model.viewport(1).currentViewportYOffset == 0.0'f32

  test "New active-tag window focuses after live restore settles":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    var restore = PendingRestoreState(
      activeSlot: 1,
      focusedWindow: ExternalWindowId(1),
      focusHistory: @[ExternalWindowId(1)],
    )
    restore.windows[ExternalWindowId(1)] = RestoredWindowData(
      slot: 1, appId: "app", title: "One", widthProportion: 0.5, heightProportion: 1.0
    )
    restore.tagByWindow[ExternalWindowId(1)] = 1
    model.applyLiveRestore(restore)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    check not model.restoreFocusedWindowPending()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)

  test "New scroller window opens beside focused window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "app", title: "Window 4")
    )
    discard model.layoutInstructions()

    check model.columnHeads(1) == @[1'u32, 2, 4, 3]
    check model.focusedWindowId() == 4
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(4)

  test "Targeted Janet-style window commands do not require focused window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdMoveWindowToTag,
        moveWindowId: 2,
        moveTargetTag: 8,
        moveFollowWindow: false,
      )
    )
    check model.focusedWindowId() == 1
    check model.snapshotWindow(2).tagId == some(8'u32)

    discard model.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid, layoutTargetTag: 8)
    )
    for workspace in model.shellSnapshot().workspaces:
      if workspace.tagId == 8:
        check workspace.layoutMode == LayoutMode.Scroller
        check workspace.layoutId == "grid"

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdSetWindowFloatingById,
        floatingWindowId: 2,
        windowFloating: true,
      )
    )
    check model.snapshotWindow(2).isFloating

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdSetWindowMaximizedById,
        maximizedWindowId: 2,
        windowMaximized: true,
      )
    )
    check model.snapshotWindow(2).isMaximized

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
        moveWorkspaceWindowId: 2,
        moveWorkspaceIndex: 2,
        moveWorkspaceFollowWindow: true,
      )
    )
    check model.focusedWindowId() == 2

  test "Live restore JSON records moved maximized window":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 10,
        appId: "generic-app",
        title: "Window",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 10))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 1))

    let win = model.restoreWindowJson(10)

    check win.kind == JObject
    check win["tag_id"].getInt() == 1
    check win["is_maximized"].getBool()

  test "Moving focused window follows target and refocuses source":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.seedCameraWindows(3)
    let outputId = model.outputForExternal(ExternalOutputId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    check model.activeWorkspaceFocusId() == 3
    check model.focusedWindowId() == 3
    check model.outputTags[outputId] == model.tagForSlot(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2
    check model.outputTags[outputId] == model.tagForSlot(1)

  test "Moving focused window to another workspace reasserts focus":
    var model = cameraModel()
    model.seedCameraWindows(1)

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    check model.activeTag == model.tagForSlot(2)
    check model.snapshotWindow(1).workspaceIdx == 2
    check model.focusedWindowId() == 1
    check effects.hasFocusEffect(1)

  test "Focusing workspace updates primary output tag":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    let outputId = model.outputForExternal(ExternalOutputId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check outputId != NullOutputId
    check model.activeTag == model.tagForSlot(2)
    check model.outputTags[outputId] == model.activeTag

  test "Moving only source window follows target and leaves source empty":
    var model = cameraModel()
    model.seedCameraWindows(1)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    check model.activeWorkspaceFocusId() == 1
    check model.focusedWindowId() == 1

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 0
    check model.focusedWindowId() == 0

  test "Adjacent tag move follows target":
    var model = cameraModel()
    model.seedCameraWindows(2)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToTagRight))

    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 1
    check model.focusedWindowId() == 1

  test "Moving window preserves target column width":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let sourceTag = model.tagForSlot(1)
    let sourceColumn = model.columnAt(sourceTag, 0)
    discard model.setColumnWidth(sourceColumn, 0.42'f32)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    let targetTag = model.tagForSlot(2)
    let targetColumn = model.columnAt(targetTag, 0)
    check model.columnData(targetColumn).get().widthProportion == 0.42'f32

  test "Moving normal window to empty grid workspace preserves source layout":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(defaultColumnWidth: 0.5),
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[
          TagRule(tagId: 2, defaultLayoutSet: true, defaultLayout: LayoutMode.Scroller),
          TagRule(tagId: 3, defaultLayoutSet: true, defaultLayout: LayoutMode.Grid),
        ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 6,
        appId: "sublime_text",
        title: "Sublime Text",
      )
    )

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 3))
    let targetTag = model.tagForSlot(3)
    let screen = model.primaryScreen()
    let geom = model.instructionGeom(6)

    check model.tagData(targetTag).get().layoutMode == LayoutMode.Scroller
    check not model.snapshotWindow(6).isMaximized
    check geom.w <= screen.w

  test "Moving to occupied grid workspace keeps target layout":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(defaultColumnWidth: 0.5),
        workspaces: WorkspaceConfig(defaultCount: 3),
        tagRules: @[
          TagRule(tagId: 2, defaultLayoutSet: true, defaultLayout: LayoutMode.Scroller),
          TagRule(tagId: 3, defaultLayoutSet: true, defaultLayout: LayoutMode.Grid),
        ],
      )
    ).model
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "files", title: "Files")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 6,
        appId: "sublime_text",
        title: "Sublime Text",
      )
    )

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 3))

    let targetTag = model.tagData(model.tagForSlot(3)).get()
    check targetTag.layoutMode == LayoutMode.Scroller
    check targetTag.customLayoutId.layoutIdString() == "grid"

  test "Moving fullscreen window through dynamic workspace preserves state":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 1,
        fullscreenOutputId: 1,
      )
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    let win = model.snapshotWindow(1)

    check model.activeTag == model.tagForSlot(4)
    check win.workspaceIdx == 4
    check win.isFullscreen
    check win.fullscreenOutput == 1
    check effects.hasFocusEffect(1)
    check effects.hasFullscreenEffect(1, true)

  test "Dynamic layout changes preserve maximized intent":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))

    let tgmixEffects =
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.TGMix))
    check model.activeTag == model.tagForSlot(4)
    let activeTag = model.tagData(model.activeTag).get()
    check activeTag.layoutMode == LayoutMode.Scroller
    check activeTag.customLayoutId.layoutIdString() == "tgmix"
    check model.snapshotWindow(1).isMaximized
    check tgmixEffects.hasMaximizedEffect(1, false)
    check tgmixEffects.hasFocusEffect(1)

    let scrollerEffects =
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
    check model.snapshotWindow(1).isMaximized
    check scrollerEffects.hasMaximizedEffect(1, true)
    check scrollerEffects.hasFocusEffect(1)

  test "Maximize column is separate from window maximize state":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let beforeGeom = model.instructionGeom(1)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    let afterColumn = model.columnData(columnId).get()
    let afterGeom = model.instructionGeom(1)

    check afterColumn.isFullWidth
    check afterColumn.widthProportion == 0.7'f32
    check not model.snapshotWindow(1).isMaximized
    check not effects.hasMaximizedEffect(1, true)
    check afterGeom.w > beforeGeom.w

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    check not model.columnData(columnId).get().isFullWidth

  test "Maximize column renders resized single scroller window at full height":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let winId = model.windowForExternal(ExternalWindowId(1))
    let screen = model.primaryScreen()
    let usableHeight = screen.h - 2 * model.outerGaps

    check model.setWindowHeightProportion(winId, 0.5)
    let resizedGeom = model.instructionGeom(1)
    check resizedGeom.h < usableHeight

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    let maximizedGeom = model.instructionGeom(1)
    check model.columnData(columnId).get().isFullWidth
    check model.modelWindow(1).heightProportion == 0.5'f32
    check maximizedGeom.y == screen.y + model.outerGaps
    check maximizedGeom.h == usableHeight

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    let restoredGeom = model.instructionGeom(1)
    check not model.columnData(columnId).get().isFullWidth
    check model.modelWindow(1).heightProportion == 0.5'f32
    check restoredGeom.h == resizedGeom.h
    check restoredGeom.y == resizedGeom.y

  test "Maximize column suppresses edge-maximized presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let screen = model.primaryScreen()

    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    check model.instructionGeom(1) == screen

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))

    check model.columnData(columnId).get().isFullWidth
    check model.snapshotWindow(1).isMaximized
    check effects.hasMaximizedEffect(1, false)
    check model.instructionGeom(1) != screen

  test "Maximize to edges exits full-width column presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let screen = model.primaryScreen()
    let winId = model.windowForExternal(ExternalWindowId(1))

    check model.setWindowHeightProportion(winId, 0.5)
    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))

    check not model.columnData(columnId).get().isFullWidth
    check model.snapshotWindow(1).isMaximized
    check effects.hasMaximizedEffect(1, true)
    check model.instructionGeom(1) == screen

  test "Maximize to edges restores stored maximized presentation from full-width column":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let screen = model.primaryScreen()

    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    check model.columnData(columnId).get().isFullWidth
    check model.snapshotWindow(1).isMaximized
    check model.instructionGeom(1) != screen

    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))

    check not model.columnData(columnId).get().isFullWidth
    check model.snapshotWindow(1).isMaximized
    check effects.hasMaximizedEffect(1, true)
    check model.instructionGeom(1) == screen

  test "Vertical scroller switches between full-width column and edge maximize":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    let screen = model.primaryScreen()
    discard model.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    check model.columnData(columnId).get().isFullWidth
    check model.snapshotWindow(1).isMaximized
    check model.instructionGeom(1) != screen

    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check not model.columnData(columnId).get().isFullWidth
    check effects.hasMaximizedEffect(1, true)
    check model.instructionGeom(1) == screen

  test "Maximize column is ignored outside scroller layouts":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)
    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))

    check not model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check effects.len == 0

  test "Window rule maximize-policy ignore blocks maximize and clears existing state":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules: @[
          WindowRule(
            appIdMatch: "docs",
            maximizePolicySet: true,
            maximizePolicy: WindowRuleMaximizePolicy.Ignore,
          )
        ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "docs", title: "Manual")
    )
    let winId = model.windowForExternal(ExternalWindowId(1))
    let columnId = model.columnAt(model.activeTag, 0)

    let requestEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    check not model.snapshotWindow(1).isMaximized
    check not model.columnData(columnId).get().isFullWidth
    check not requestEffects.hasMaximizedEffect(1, true)

    let toggleEffects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check not model.snapshotWindow(1).isMaximized
    check not model.columnData(columnId).get().isFullWidth
    check not toggleEffects.hasMaximizedEffect(1, true)

    discard model.setWindowMaximized(winId, true)
    let clearEdgeEffects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check not model.snapshotWindow(1).isMaximized
    check clearEdgeEffects.hasMaximizedEffect(1, false)

    discard model.setColumnFullWidth(columnId, true)
    let clearColumnEffects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check not model.columnData(columnId).get().isFullWidth
    check not clearColumnEffects.hasMaximizedEffect(1, true)

  test "Window rule maximize-policy column uses full-width scroller column":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules: @[
          WindowRule(
            appIdMatch: "docs",
            maximizePolicySet: true,
            maximizePolicy: WindowRuleMaximizePolicy.Column,
          )
        ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "docs", title: "Manual")
    )
    let columnId = model.columnAt(model.activeTag, 0)
    let beforeGeom = model.instructionGeom(1)

    let requestEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    let afterGeom = model.instructionGeom(1)

    check model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check afterGeom.w > beforeGeom.w
    check not requestEffects.hasMaximizedEffect(1, true)

    let clearEffects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check not model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check not clearEffects.hasMaximizedEffect(1, true)

    let commandEffects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check not commandEffects.hasMaximizedEffect(1, true)

  test "Window rule maximize-policy column supports vertical scroller":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces:
          WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.VerticalScroller),
        windowRules: @[
          WindowRule(
            appIdMatch: "docs",
            maximizePolicySet: true,
            maximizePolicy: WindowRuleMaximizePolicy.Column,
          )
        ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "docs", title: "Manual")
    )
    let columnId = model.columnAt(model.activeTag, 0)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    check model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized

    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))
    check model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check not effects.hasMaximizedEffect(1, true)

  test "Window rule maximize-policy column is no-op outside scroller layouts":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Grid),
        windowRules: @[
          WindowRule(
            appIdMatch: "docs",
            maximizePolicySet: true,
            maximizePolicy: WindowRuleMaximizePolicy.Column,
          )
        ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "docs", title: "Manual")
    )
    let columnId = model.columnAt(model.activeTag, 0)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdToggleMaximized))

    check not model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(1).isMaximized
    check not effects.hasMaximizedEffect(1, true)

  test "Column resize clears maximize column state":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    check model.columnData(columnId).get().isFullWidth

    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetColumnWidth, targetWidth: 0.5'f32))
    check not model.columnData(columnId).get().isFullWidth
    check model.columnData(columnId).get().widthProportion == 0.5'f32

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard model.updateModel(Msg(kind: MsgKind.CmdResizeWidth, deltaW: 0.1'f32))
    check not model.columnData(columnId).get().isFullWidth

  test "Proportion preset command cycles scroller column widths":
    var model = cameraModel()
    model.scrollerProportionPresets = @[0.25'f32, 0.5'f32, 0.75'f32]
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)

    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetColumnWidth, targetWidth: 0.5'f32))
    discard model.updateModel(
      Msg(kind: MsgKind.CmdSwitchProportionPreset, proportionPresetDelta: 1)
    )
    check model.columnData(columnId).get().widthProportion == 0.75'f32

    discard model.updateModel(
      Msg(kind: MsgKind.CmdSwitchProportionPreset, proportionPresetDelta: 1)
    )
    check model.columnData(columnId).get().widthProportion == 0.25'f32

    discard model.updateModel(
      Msg(kind: MsgKind.CmdSwitchProportionPreset, proportionPresetDelta: -1)
    )
    check model.columnData(columnId).get().widthProportion == 0.75'f32

  test "Moving full-width column preserves column presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard
      model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    let targetTag = model.tagForSlot(2)
    let targetColumn = model.columnAt(targetTag, 0)
    check model.activeTag == targetTag
    check model.columnData(targetColumn).get().isFullWidth
    check model.columnData(targetColumn).get().widthProportion == 0.7'f32

  test "Moving floating window through dynamic layouts preserves geometry":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFloating))
    let before = model.snapshotWindow(1).floatingGeom

    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))

    let win = model.snapshotWindow(1)
    check model.activeTag == model.tagForSlot(4)
    check win.workspaceIdx == 4
    check win.isFloating
    check win.floatingGeom == before

  test "Moving editor from grid to scroller preserves runtime attributes":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "kitty", title: "Terminal")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 6,
        appId: "sublime_text",
        title: "Sublime Text",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 6,
        actualWidth: 900,
        actualHeight: 600,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 6,
        minWidth: 300,
        minHeight: 200,
        maxWidth: 1600,
        maxHeight: 1200,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDecorationHint, decorationWindowId: 6, decorationHint: 2
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowPresentationHint,
        presentationWindowId: 6,
        presentationHint: 3,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 6))

    let before = model.windowData(model.windowForExternal(ExternalWindowId(6))).get()
    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))
    let winId = model.windowForExternal(ExternalWindowId(6))
    let after = model.windowData(winId).get()
    let snapshotWin = model.snapshotWindow(6)

    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 6
    check snapshotWin.workspaceIdx == 2
    check after.widthProportion == before.widthProportion
    check after.heightProportion == before.heightProportion
    check after.isMaximized == before.isMaximized
    check after.isFullscreen == before.isFullscreen
    check after.isFloating == before.isFloating
    check after.isMinimized == before.isMinimized
    check after.actualW == before.actualW
    check after.actualH == before.actualH
    check after.minWidth == before.minWidth
    check after.maxWidth == before.maxWidth
    check after.hasDecorationHint == before.hasDecorationHint
    check after.decorationHint == before.decorationHint
    check after.hasPresentationHint == before.hasPresentationHint
    check after.presentationHint == before.presentationHint
    check effects.hasFocusEffect(6)

  test "Moving maximized window through grid preserves desired state":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 6,
        appId: "sublime_text",
        title: "Sublime Text",
      )
    )
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 6)
    )

    let toGridEffects =
      model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 3))
    check model.activeTag == model.tagForSlot(3)
    check model.tagData(model.activeTag).get().layoutMode == LayoutMode.Scroller
    check model.snapshotWindow(6).isMaximized
    check toGridEffects.hasMaximizedEffect(6, false)

    let toScrollerEffects =
      model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))
    check model.activeTag == model.tagForSlot(2)
    check model.snapshotWindow(6).isMaximized
    check toScrollerEffects.hasMaximizedEffect(6, true)
    check toScrollerEffects.hasFocusEffect(6)

  test "Targeted layout ignores missing empty dynamic workspace":
    var model = cameraModel()
    model.seedCameraWindows(1)

    let (nextModel, effects) = model.update(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck, layoutTargetTag: 4)
    )

    check nextModel.tagForSlot(4) == NullTagId
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Duplicate window create preserves moved window attributes":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 10, appId: "kitty", title: "Terminal"
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 10,
        actualWidth: 640,
        actualHeight: 480,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 10,
        minWidth: 200,
        minHeight: 100,
        maxWidth: 1200,
        maxHeight: 900,
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDecorationHint, decorationWindowId: 10, decorationHint: 2
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowPresentationHint,
        presentationWindowId: 10,
        presentationHint: 3,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 10))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 10,
        fullscreenOutputId: 0,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 10,
        appId: "kitty",
        title: "Terminal renamed",
      )
    )

    let winId = model.windowForExternal(ExternalWindowId(10))
    let win = model.windowData(winId).get()

    check model.placementForWindowOnTag(model.tagForSlot(1), winId).isNone
    check model.placementForWindowOnTag(model.tagForSlot(2), winId).isSome
    check win.title == "Terminal renamed"
    check win.isMaximized
    check win.isFullscreen
    check win.actualW == 640
    check win.actualH == 480
    check win.minWidth == 200
    check win.maxWidth == 1200
    check win.hasDecorationHint
    check win.decorationHint == 2
    check win.hasPresentationHint
    check win.presentationHint == 3
