import tcore_support

suite "Core Runtime Logic: parented popups":
  test "Parented window opens floating over parent without moving camera":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    let parentGeom = model.instructionGeom(1)
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    discard model.layoutInstructions()

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    check child.parentExternalId == ExternalWindowId(1)
    check model.snapshotWindow(2).parentId == 1
    check child.isFloating
    check child.floatingGeom.x ==
      parentGeom.x + (parentGeom.w - child.floatingGeom.w) div 2
    check child.floatingGeom.y ==
      parentGeom.y + (parentGeom.h - child.floatingGeom.h) div 2
    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check not model.viewportRetargetRequested(model.activeTag)
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Deck popup preserves parent column position":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "kitty", title: "btop")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "org.kde.okular",
        title: "Okular",
      )
    )

    let btopBefore = model.instructionGeom(1)
    let parentBefore = model.instructionGeom(2)
    check btopBefore.x < parentBefore.x

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 2,
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
      )
    )

    let btopAfter = model.instructionGeom(1)
    let parentAfter = model.instructionGeom(2)
    let childAfter = model.instructionGeom(3)
    check btopAfter == btopBefore
    check parentAfter == parentBefore
    check childAfter.x == parentAfter.x + (parentAfter.w - childAfter.w) div 2
    check childAfter.y == parentAfter.y + (parentAfter.h - childAfter.h) div 2
    check model.snapshotWindow(3).isFloating

  test "Floating parented popup stays out of public columns":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "kitty", title: "btop")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "org.kde.okular",
        title: "Okular",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        createdParentWindowId: 2,
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
      )
    )

    let snapshot = model.shellSnapshot()
    check snapshot.workspaces[0].columns.len == 2
    check snapshot.workspaces[0].columns[0].windows == @[runtime_values.WindowId(1)]
    check snapshot.workspaces[0].columns[1].windows == @[runtime_values.WindowId(2)]
    check model.snapshotWindow(3).tagId.isSome
    check model.snapshotWindow(3).tagId.get() == 1

    let restoredTag = model.restoreTagJson(1)
    check restoredTag["columns"].len == 2
    check restoredTag["columns"][0]["windows"].len == 1
    check restoredTag["columns"][0]["windows"][0].getInt() == 1
    check restoredTag["columns"][1]["windows"].len == 1
    check restoredTag["columns"][1]["windows"][0].getInt() == 2
    check restoreWindowJson(model, 3)["tag_id"].getInt() == 1

  test "Auto parented popup fits parent when default floating is wider":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          gaps: 10,
          defaultColumnWidth: 0.4,
          defaultWindowWidth: 0.8,
          defaultWindowHeight: 0.6,
        ),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 1, appId: "okular", title: "Document"
      )
    )
    let parentGeom = model.instructionGeom(1)

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        createdParentWindowId: 1,
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
      )
    )

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w
    check childGeom.x == parentGeom.x
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Late parent event floats child without moving camera":
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
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowParent, childWindowId: 2, parentWindowId: 1)
    )
    discard model.layoutInstructions()

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    check child.parentExternalId == ExternalWindowId(1)
    check child.isFloating
    check model.focusedWindowId() == 2
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check not model.viewportRetargetRequested(model.activeTag)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and it.triadEventName == "layout"
    )

  test "Parented inactive-workspace window stays on parent workspace silently":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))

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

    check model.shellSnapshot().activeTag == 2
    check child.tagId.isSome and child.tagId.get() == 1
    check child.workspaceIdx == 1
    check not effects.hasFocusEffect(2)
    check model.instructionGeom(2).w == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Parented floating window follows parent projection":
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
        title: "Passphrase",
      )
    )

    let beforeChildGeom = model.instructionGeom(2)
    let parentId = model.windowForExternal(ExternalWindowId(1))
    discard model.setWindowFloating(
      parentId, true, runtime_values.Rect(x: 300, y: 100, w: 400, h: 300)
    )

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2
    check childGeom != beforeChildGeom

  test "Parented floating window follows scroller camera":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    let beforeChildGeom = model.instructionGeom(4)

    model.setViewport(1, targetX = 500.0, currentX = 500.0)

    let parentGeom = model.instructionGeom(2)
    let childGeom = model.instructionGeom(4)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2
    check childGeom != beforeChildGeom

  test "Parented popup hides when focus moves to visible unrelated window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    model.setViewport(1, targetX = 400.0, currentX = 400.0)

    let parentGeom = model.instructionGeom(2)
    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check parentGeom.x < 1000
    check parentGeom.x + parentGeom.w > 0
    check order.contains(2'u32)
    check not order.contains(4'u32)

  test "Parented popup reappears when focus returns to parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    check not model.layoutProjection().instructions.mapIt(uint32(it.windowId)).contains(
      4'u32
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.setViewport(1, targetX = 400.0, currentX = 400.0)

    let parentGeom = model.instructionGeom(2)
    let childGeom = model.instructionGeom(4)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Parented popup remains while focus is on child":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    let parentGeom = model.instructionGeom(2)
    let childGeom = model.instructionGeom(4)
    check model.focusedWindowId() == 4
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2

  test "Parented popup tree remains while focus is on nested child":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Second",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 6,
        createdParentWindowId: 4,
        appId: "pinentry",
        title: "Nested",
      )
    )

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check model.focusedWindowId() == 6
    check order.contains(4'u32)
    check order.contains(5'u32)
    check order.contains(6'u32)

  test "Parented popup root restores explicitly focused parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Second",
      )
    )

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    check model.focusedWindowId() == 2
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))

    check model.focusedWindowId() == 2

  test "Parented popup root restores last explicitly focused child":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Second",
      )
    )

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))

    check model.focusedWindowId() == 4

  test "Closing focused popup falls back within popup tree":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "First",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 5,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Second",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 4))

    check model.focusedWindowId() == 5

  test "Closing last focused popup falls back to parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 4))

    check model.focusedWindowId() == 2

  test "Focused popup retargets scroller camera to parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    discard model.layoutInstructions()
    let parentTarget = model.viewport(1).targetViewportXOffset
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 4
    check model.viewport(1).targetViewportXOffset == parentTarget
