import tcore_support

suite "Core Runtime Logic: lifecycle basic":
  test "Window lifecycle mutates state and emits shell updates":
    var model = configuredModel()
    let (nextModel, effects) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 100,
        appId: "firefox",
        title: "Mozilla Firefox",
      )
    )
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 100
    check snapshot.windows[0].appId == "firefox"
    check snapshot.workspaces[0].focusedWindow == 100
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowOpenedOrChanged")
    )

  test "New active-tag window focuses and retargets camera":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "New active-tag window records focus under layer focus":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusExclusive))

    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusNone))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32

  test "Deferred admission hides unparented River window until settled":
    var model = cameraModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "app",
        title: "Two",
        deferAdmission: true,
      )
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    check model.windowData(childId).get().admissionState ==
      WindowAdmissionState.PendingAdmission
    check model.focusedWindowId() == 1
    check not model.layoutProjection().instructions.mapIt(uint32(it.windowId)).contains(
      2'u32
    )
    check model.snapshotWindow(2).id == 0'u32

    model.applyMsg(Msg(kind: MsgKind.WlWindowAdmissionSettled, admissionWindowId: 2))

    check model.windowData(childId).get().admissionState == WindowAdmissionState.Admitted
    check model.focusedWindowId() == 2
    check model.layoutProjection().instructions.mapIt(uint32(it.windowId)).contains(
      2'u32
    )

  test "Late parent admits deferred child directly as floating popup":
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
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
        deferAdmission: true,
      )
    )

    check not model.layoutProjection().instructions.mapIt(uint32(it.windowId)).contains(
      2'u32
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowParent, childWindowId: 2, parentWindowId: 1)
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check child.admissionState == WindowAdmissionState.Admitted
    check child.isFloating
    check child.parentExternalId == ExternalWindowId(1)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check model.focusedWindowId() == 2

  test "Late parented Okular picker fits parent after deferred admission":
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
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
        deferAdmission: true,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowParent, childWindowId: 2, parentWindowId: 1)
    )

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w
    check childGeom.x == parentGeom.x
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Late parent reclassifies admitted child as floating popup":
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
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
        deferAdmission: true,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowAdmissionSettled, admissionWindowId: 2))
    check model.layoutProjection().instructions.mapIt(uint32(it.windowId)).contains(
      2'u32
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowParent, childWindowId: 2, parentWindowId: 1)
    )

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check child.isFloating
    check child.parentExternalId == ExternalWindowId(1)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
