import tcore_support

suite "Core Runtime Logic: restore identity":
  test "Live restore preserves popup parent relationship":
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

    let win = model.restoreWindowJson(2)
    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()

    var restoredModel = cameraModel()
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "Parent")
    )
    restoredModel.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "pinentry",
        title: "Passphrase",
      )
    )

    check win["parent_id"].getInt() == 1
    check restoredModel.snapshotWindow(2).parentId == 1
    check restoredModel.instructionGeom(2).w > 0

  test "Live restore matches unique app id after title changes":
    var model = restoreMatchingModel()
    var restore =
      PendingRestoreState(activeSlot: 1, focusedWindow: ExternalWindowId(50))
    restore.addRestoredWindow(
      ExternalWindowId(50), 1, "generic-app", "Old title", isMaximized = true
    )
    model.applyLiveRestore(restore)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 70,
        appId: "generic-app",
        title: "New title",
      )
    )
    let win = model.snapshotWindow(70)

    check win.id == 70
    check win.workspaceIdx == 1
    check win.isMaximized
    check effects.hasMaximizedEffect(70, true)

  test "Live restore seeds screen size from restored windows when outputs are missing":
    var model = restoreMatchingModel()
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(ExternalWindowId(50), 1, "generic-app", "Restored window")
    restore.windows[ExternalWindowId(50)].actualW = 1200
    restore.windows[ExternalWindowId(50)].actualH = 800

    model.applyLiveRestore(restore)

    check model.screenWidth == 1200
    check model.screenHeight == 800

  test "Live restore does not guess between duplicate app ids":
    var model = restoreMatchingModel()
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(
      ExternalWindowId(50), 1, "generic-app", "Old title A", isMaximized = true
    )
    restore.addRestoredWindow(
      ExternalWindowId(51), 3, "generic-app", "Old title B", isMaximized = true
    )
    model.applyLiveRestore(restore)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 70,
        appId: "generic-app",
        title: "New title",
      )
    )
    let win = model.snapshotWindow(70)

    check win.id == 70
    check win.workspaceIdx == 2
    check not win.isMaximized
    check not effects.hasMaximizedEffect(70, true)

  test "Late identifier restore emits maximized state":
    var model = restoreMatchingModel()
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(
      ExternalWindowId(50),
      1,
      "generic-app",
      "Old title A",
      isMaximized = true,
      identifier = "stable-target",
    )
    restore.addRestoredWindow(
      ExternalWindowId(51), 3, "generic-app", "Old title B", identifier = "stable-other"
    )
    model.applyLiveRestore(restore)

    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 70,
        appId: "generic-app",
        title: "New title",
      )
    )
    check model.snapshotWindow(70).workspaceIdx == 2

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowIdentifier,
        identifierWindowId: 70,
        identifier: "stable-target",
      )
    )
    let win = model.snapshotWindow(70)

    check win.workspaceIdx == 1
    check win.isMaximized
    check effects.hasMaximizedEffect(70, true)

  test "Rule-placed new window does not steal active camera":
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
        windowRules: @[WindowRule(appIdMatch: "chat", defaultWorkspace: 2)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    let beforeViewport = model.viewport(1)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "chat", title: "Chat")
    )
    discard model.layoutInstructions()
    let snapshot = model.shellSnapshot()

    check snapshot.activeTag == 1
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check snapshot.workspaces[1].focusedWindow == 2
    check model.viewport(1) == beforeViewport
    check not effects.hasFocusEffect(2)

  test "Regex window rule placement applies through lifecycle":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              matches:
                @[
                  WindowRuleMatcher(
                    appIdSet: true,
                    appId: "^org\\.gimp\\.",
                    titleSet: true,
                    title: "Welcome",
                  )
                ],
              excludes: @[WindowRuleMatcher(titleSet: true, title: "Private")],
              defaultWorkspace: 2,
              openFloatingSet: true,
              openFloating: true,
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
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 2,
        appId: "org.gimp.GIMP",
        title: "Welcome to GIMP",
      )
    )
    let matched = model.snapshotWindow(2)
    check matched.workspaceIdx == 2
    check matched.isFloating
    check model.focusedWindowId() == 1
    check not effects.hasFocusEffect(2)

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 3,
        appId: "org.gimp.GIMP",
        title: "Private Welcome",
      )
    )

    let excluded = model.snapshotWindow(3)
    check excluded.workspaceIdx == 1
    check not excluded.isFloating
