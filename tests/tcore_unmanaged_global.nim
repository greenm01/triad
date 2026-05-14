import tcore_support

suite "Core Runtime Logic: unmanaged global windows":
  test "Window rule open-unmanaged-global merges and can be cleared":
    var model = initRuntimeStateFromConfig(
      Config(
        windowRules:
          @[
            WindowRule(appIdMatch: "camera", openUnmanagedGlobal: true),
            WindowRule(
              appIdMatch: "camera",
              titleMatch: "Private",
              openUnmanagedGlobalSet: true,
              openUnmanagedGlobal: false,
            ),
          ]
      )
    ).model

    let broad = model.windowRuleFor("camera", "Preview")
    check broad.found
    check broad.rule.openUnmanagedGlobalSet
    check broad.rule.openUnmanagedGlobal

    let specific = model.windowRuleFor("camera", "Private Preview")
    check specific.found
    check specific.rule.openUnmanagedGlobalSet
    check not specific.rule.openUnmanagedGlobal

  test "Window rule open-unmanaged-global opens floating without workspace placement":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "pet",
              defaultWorkspace: 2,
              openFloatingSet: true,
              openFloating: false,
              openOnAllWorkspaces: true,
              openOverlay: true,
              openUnmanagedGlobal: true,
              floating: WindowRuleFloatingConfig(
                xRatioSet: true,
                xRatio: 0.1,
                yRatioSet: true,
                yRatio: 0.2,
                widthSet: true,
                width: 320,
                heightSet: true,
                height: 240,
              ),
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1200, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Main")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "pet", title: "Pet")
    )

    let petId = model.windowForExternal(ExternalWindowId(2))
    let pet = model.windowData(petId).get()
    check pet.isUnmanagedGlobal
    check pet.isFloating
    check not pet.isSticky
    check not pet.isOverlay
    check not model.firstWindowPosition(petId).found
    check model.focusedWindowId() == 1

    let shellPet = model.snapshotWindow(2)
    check shellPet.isUnmanagedGlobal
    check shellPet.isFloating
    check shellPet.tagId.isNone
    check shellPet.workspaceIdx == 0
    check shellPet.floatingGeom.w == 320
    check shellPet.floatingGeom.h == 240

  test "Unmanaged global windows render on every workspace without occupying it":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        windowRules: @[WindowRule(appIdMatch: "camera", openUnmanagedGlobal: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Main")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 9, appId: "camera", title: "Cam")
    )

    check model.instructionGeom(9).w > 0
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    check model.instructionGeom(9).w > 0

    let snapshot = model.shellSnapshot()
    check not snapshot.workspaces[1].occupied
    check snapshot.workspaces[1].focusedWindow == 0

  test "Unmanaged global windows stay visible above fullscreen backing windows":
    var model = initRuntimeStateFromConfig(
      Config(windowRules: @[WindowRule(appIdMatch: "hud", openUnmanagedGlobal: true)])
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Main")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFullscreen))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "hud", title: "HUD")
    )

    let projection = model.layoutProjection()
    check projection.instructions.anyIt(uint32(it.windowId) == 1)
    check projection.instructions.anyIt(uint32(it.windowId) == 7)

  test "Live restore preserves unmanaged global windows without workspace placement":
    var restore = PendingRestoreState(activeSlot: 1)
    restore.windows[ExternalWindowId(44)] = RestoredWindowData(
      isFloating: true,
      isUnmanagedGlobal: true,
      floatingGeom: runtime_values.Rect(x: 10, y: 20, w: 300, h: 200),
      appId: "camera",
      title: "Cam",
    )
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 2))
    ).model
    model.applyLiveRestore(restore)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 44, appId: "camera", title: "Cam")
    )

    let winId = model.windowForExternal(ExternalWindowId(44))
    check model.windowData(winId).get().isUnmanagedGlobal
    check model.windowData(winId).get().isFloating
    check not model.firstWindowPosition(winId).found
    check model.restoreWindowJson(44)["is_unmanaged_global"].getBool()
    check model.restoreWindowJson(44)["tag_id"].getInt() == 0
