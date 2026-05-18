import tcore_support

suite "Core Runtime Logic: parented geometry":
  test "Parented floating window hides with obscured maximized parent":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.contains(1'u32)
    check not order.contains(2'u32)
    check not order.contains(3'u32)

  test "Manual parented popup wider than parent stays centered and clamped":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Wide dialog",
      )
    )
    let parentId = model.windowForExternal(ExternalWindowId(1))
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard
      model.setWindowFloating(parentId, true, Rect(x: 300, y: 100, w: 400, h: 300))
    discard model.setWindowFloating(childId, true, Rect(x: 0, y: 0, w: 800, h: 500))

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.w == 800
    check childGeom.h == 500
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2
    check childGeom.x <= parentGeom.x + parentGeom.w
    check childGeom.x + childGeom.w >= parentGeom.x

  test "Size-forced parented popup can overhang parent":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Wide dialog",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: parentGeom.w + 120,
        minHeight: 140,
        maxWidth: 0,
        maxHeight: 0,
      )
    )

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w + 120
    check childGeom.x == 0
    check childGeom.x <= parentGeom.x + parentGeom.w
    check childGeom.x + childGeom.w >= parentGeom.x

  test "Manual parented popup resize disables parent auto fit":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Dialog",
      )
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    check model.windowData(childId).get().parentAutoFloating
    model.applyMsg(Msg(kind: MsgKind.CmdResizeFloating, deltaFW: 120, deltaFH: 0))

    let parentId = model.windowForExternal(ExternalWindowId(1))
    discard
      model.setWindowFloating(parentId, true, Rect(x: 300, y: 100, w: 400, h: 300))

    let child = model.windowData(childId).get()
    let childGeom = model.instructionGeom(2)
    check not child.parentAutoFloating
    check not child.manualFloatingPosition
    check childGeom.w == child.floatingGeom.w
    check childGeom.w > model.instructionGeom(1).w
    let parentGeom = model.instructionGeom(1)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Manual parented popup move uses free position":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Dialog",
      )
    )

    let parentGeom = model.instructionGeom(1)
    let childId = model.windowForExternal(ExternalWindowId(2))
    let initial = model.windowData(childId).get()
    let initialGeom = model.instructionGeom(2)
    check not initial.manualFloatingPosition
    check initialGeom.x == parentGeom.x + (parentGeom.w - initialGeom.w) div 2
    check initialGeom.y == parentGeom.y + (parentGeom.h - initialGeom.h) div 2

    model.applyMsg(Msg(kind: MsgKind.CmdMoveFloating, moveDX: 90, moveDY: 40))

    let moved = model.windowData(childId).get()
    let movedGeom = model.instructionGeom(2)
    check moved.manualFloatingPosition
    check moved.floatingGeom.x == initial.floatingGeom.x + 90
    check moved.floatingGeom.y == initial.floatingGeom.y + 40
    check movedGeom == moved.floatingGeom
    check restoreWindowJson(model, 2)["manual_floating_position"].getBool()

  test "Parented popup larger than screen shrinks to screen":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Oversized dialog",
      )
    )
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard model.setWindowFloating(childId, true, Rect(x: 0, y: 0, w: 1400, h: 900))

    let childGeom = model.instructionGeom(2)
    check childGeom == model.primaryScreen()

  test "Parented popup hides when parent leaves camera":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    model.setViewport(1, targetX = 900.0, currentX = 900.0)

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.contains(1'u32)
    check not order.contains(4'u32)

  test "Parented popup hides until partly visible parent is fully visible":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Wide dialog",
      )
    )
    let childId = model.windowForExternal(ExternalWindowId(4))
    discard model.setWindowFloating(childId, true, Rect(x: 0, y: 0, w: 800, h: 500))

    model.setViewport(1, targetX = 350.0, currentX = 350.0)

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(4)
    check parentGeom.x < 0
    check parentGeom.x + parentGeom.w > 0
    check childGeom.w == 0

    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let visibleParentGeom = model.instructionGeom(1)
    let visibleChildGeom = model.instructionGeom(4)
    check visibleParentGeom.x >= 0
    check visibleChildGeom.w == 800
    check visibleChildGeom.x == 0
    check visibleChildGeom.x <= visibleParentGeom.x + visibleParentGeom.w

  test "Parented floating stack keeps children and newer siblings above":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Second",
      )
    )

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.find(1'u32) < order.find(2'u32)
    check order.find(2'u32) < order.find(3'u32)

  test "Focused popup rises above newer sibling in stack history":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Second",
      )
    )

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.find(3'u32) < order.find(2'u32)

  test "Large parented primary surface tiles after size hint":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "editor",
        title: "Detached",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: int32(float32(parentGeom.w) * 0.95'f32),
        minHeight: int32(float32(parentGeom.h) * 0.95'f32),
        maxWidth: 0,
        maxHeight: 0,
      )
    )

    let child = model.snapshotWindow(2)
    check not child.isFloating
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    check model.focusedWindowId() == 1

  test "Respect size hints false keeps large parented surface floating":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "editor", respectSizeHintsSet: true, respectSizeHints: false
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "editor",
        title: "Detached",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: int32(float32(parentGeom.w) * 0.95'f32),
        minHeight: int32(float32(parentGeom.h) * 0.95'f32),
        maxWidth: 0,
        maxHeight: 0,
      )
    )

    let child = model.snapshotWindow(2)
    check child.isFloating

  test "Manual tiled parented child is not refloated by later hints":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard model.setWindowFloating(childId, false)

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 2,
        minWidth: 260,
        minHeight: 140,
        maxWidth: 260,
        maxHeight: 140,
      )
    )

    check not model.snapshotWindow(2).isFloating

  test "Offscreen parented popup defers focus until parent is visible":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    discard model.layoutInstructions()

    check not effects.hasFocusEffect(4)
    check model.focusedWindowId() == 1
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check model.pendingDialogFocusWindows.len == 1
    check model.instructionGeom(4).w == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    discard model.layoutInstructions()
    let parentViewport = model.viewport(1)
    model.setViewport(
      1,
      targetX = parentViewport.targetViewportXOffset,
      currentX = parentViewport.targetViewportXOffset,
    )
    let flushEffects = model.updateModel(Msg(kind: MsgKind.CmdTick))

    check flushEffects.hasFocusEffect(4)
    check model.focusedWindowId() == 4
    check model.pendingDialogFocusWindows.len == 0

  test "Parented popup viewport jump rule focuses and snaps":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          gaps: 10,
          defaultColumnWidth: 0.7,
          centerFocusedColumn: "always",
          enableAnimations: true,
          animationSpeed: 0.5,
        ),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules: @[WindowRule(appIdMatch: "keepassxc", dialogViewportJump: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Window 1")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Window 2")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        appId: "keepassxc",
        title: "KeePassXC",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    discard model.layoutInstructions()

    check effects.hasFocusEffect(4)
    check model.focusedWindowId() == 4
    check model.pendingDialogFocusWindows.len == 0
    check model.viewport(1).targetViewportXOffset > 0.0'f32
    check model.viewport(1).currentViewportXOffset ==
      model.viewport(1).targetViewportXOffset

  test "Parented popup open-focused false suppresses viewport jump":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          gaps: 10,
          defaultColumnWidth: 0.7,
          centerFocusedColumn: "always",
          enableAnimations: true,
          animationSpeed: 0.5,
        ),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(appIdMatch: "keepassxc", dialogViewportJump: true),
            WindowRule(appIdMatch: "pinentry", openFocusedSet: true, openFocused: false),
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Window 1")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Window 2")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        appId: "keepassxc",
        title: "KeePassXC",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    discard model.layoutInstructions()

    check not effects.hasFocusEffect(4)
    check model.focusedWindowId() == 1
    check model.pendingDialogFocusWindows.len == 0
    check model.viewport(1).targetViewportXOffset == 0.0'f32

  test "Queued parented popup is cleared when parent closes":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    check model.pendingDialogFocusWindows.len == 1

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 3))

    check model.pendingDialogFocusWindows.len == 0

  test "Deck popup from visible background parent anchors immediately":
    for mode in [LayoutMode.Deck, LayoutMode.VerticalDeck]:
      var model = directionalModel(mode, 3)
      model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: 4,
          createdParentWindowId: 3,
          appId: "pinentry",
          title: "Passphrase",
        )
      )

      var parentGeom = model.instructionGeom(3)
      var childGeom = model.instructionGeom(4)
      check childGeom.w > 0
      check model.focusedWindowId() == 4
      check model.pendingDialogFocusWindows.len == 0
      check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
      check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

      let idleEffects = model.updateModel(Msg(kind: MsgKind.CmdTick))
      parentGeom = model.instructionGeom(3)
      childGeom = model.instructionGeom(4)

      check not idleEffects.hasFocusEffect(4)
      check model.focusedWindowId() == 4
      check model.pendingDialogFocusWindows.len == 0
      check childGeom.w > 0
      check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
      check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "TGMix popup anchors in tile-sized parent zone":
    var model = directionalModel(LayoutMode.TGMix, 3)
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    let childGeom = model.instructionGeom(4)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "TGMix popup anchors in grid-sized parent zone":
    var model = directionalModel(LayoutMode.TGMix, 4)
    let parentGeom = model.instructionGeom(4)
    model.focusExternal(4)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        createdParentWindowId: 4,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    let childGeom = model.instructionGeom(5)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Parented window rules can suppress focus and floating":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pinentry",
              openFloatingSet: true,
              openFloating: false,
              openFocusedSet: true,
              openFocused: false,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    let child = model.snapshotWindow(2)

    check not child.isFloating
    check model.focusedWindowId() == 1
    check not effects.hasFocusEffect(2)
