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

  test "Live restore prefers stable identity over colliding external ids":
    var restore =
      PendingRestoreState(activeSlot: 2, focusedWindow: ExternalWindowId(133))
    restore.addRestoredWindow(
      ExternalWindowId(132),
      1,
      "brave-origin-nightly",
      "Inbox",
      isMaximized = true,
      identifier = "brave-id",
    )
    restore.addRestoredWindow(
      ExternalWindowId(133), 2, "kitty", "spinner-old", identifier = "kitty-main"
    )
    restore.addRestoredWindow(
      ExternalWindowId(136), 2, "kitty", "editor", identifier = "kitty-editor"
    )
    restore.tags[1] = RestoredTagData(
      slot: 1,
      layoutMode: LayoutMode.Scroller,
      focusedWindow: ExternalWindowId(132),
      columns:
        @[RestoredColumnData(windows: @[ExternalWindowId(132)], widthProportion: 0.5)],
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    restore.tags[2] = RestoredTagData(
      slot: 2,
      layoutMode: LayoutMode.Scroller,
      focusedWindow: ExternalWindowId(133),
      columns:
        @[
          RestoredColumnData(windows: @[ExternalWindowId(133)], widthProportion: 0.5),
          RestoredColumnData(windows: @[ExternalWindowId(136)], widthProportion: 0.5),
        ],
      targetViewportXOffset: 300.0,
      currentViewportXOffset: 120.0,
      masterCount: 1,
      masterSplitRatio: 0.5,
    )

    var model = cameraModel()
    model.applyLiveRestore(restore)
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 132, appId: "kitty", title: "new")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowIdentifier,
        identifierWindowId: 132,
        identifier: "kitty-main",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 131,
        appId: "brave-origin-nightly",
        title: "Inbox",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowIdentifier,
        identifierWindowId: 131,
        identifier: "brave-id",
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 133, appId: "kitty", title: "editor")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowIdentifier,
        identifierWindowId: 133,
        identifier: "kitty-editor",
      )
    )

    check model.snapshotWindow(131).workspaceIdx == 1
    check model.snapshotWindow(131).isMaximized
    check model.snapshotWindow(132).workspaceIdx == 2
    check model.snapshotWindow(133).workspaceIdx == 2
    check model.columnHeads(1) == @[131'u32]
    check model.columnHeads(2) == @[132'u32, 133'u32]
    check model.viewport(2).currentViewportXOffset == 120.0'f32

  test "Live restore focus history survives colliding replacement ids":
    var restore =
      PendingRestoreState(activeSlot: 1, focusedWindow: ExternalWindowId(132))
    restore.addRestoredWindow(
      ExternalWindowId(130), 1, "kitty", "triad", identifier = "triad-id"
    )
    restore.addRestoredWindow(
      ExternalWindowId(131), 1, "brave-browser", "GitHub", identifier = "brave-id"
    )
    restore.addRestoredWindow(
      ExternalWindowId(132),
      1,
      "kitty",
      "nimble liveReload ~/d/triad",
      identifier = "live-id",
    )
    restore.focusHistory =
      @[ExternalWindowId(131), ExternalWindowId(130), ExternalWindowId(132)]

    var model = cameraModel()
    model.applyLiveRestore(restore)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 130,
        appId: "brave-browser",
        title: "GitHub",
        createdIdentifier: "brave-id",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 129,
        appId: "kitty",
        title: "triad",
        createdIdentifier: "triad-id",
      )
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 131,
        appId: "kitty",
        title: "nimble liveReload ~/d/triad",
        createdIdentifier: "live-id",
      )
    )

    check model.focusHistory == @[WindowId(1), WindowId(2), WindowId(3)]

  test "Live restore later active workspace windows do not steal restored focus":
    var restore =
      PendingRestoreState(activeSlot: 1, focusedWindow: ExternalWindowId(10))
    restore.addRestoredWindow(
      ExternalWindowId(10), 1, "kitty", "focused", identifier = "focused-id"
    )
    restore.addRestoredWindow(
      ExternalWindowId(11), 1, "kitty", "later", identifier = "later-id"
    )
    restore.tags[1] = RestoredTagData(
      slot: 1,
      layoutMode: LayoutMode.Scroller,
      focusedWindow: ExternalWindowId(10),
      columns:
        @[
          RestoredColumnData(windows: @[ExternalWindowId(10)], widthProportion: 0.5),
          RestoredColumnData(windows: @[ExternalWindowId(11)], widthProportion: 0.5),
        ],
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    restore.focusHistory = @[ExternalWindowId(11), ExternalWindowId(10)]

    var model = cameraModel()
    model.applyLiveRestore(restore)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 10,
        appId: "kitty",
        title: "focused",
        createdIdentifier: "focused-id",
      )
    )

    check model.focusedWindowId() == 10
    check model.activeWorkspaceFocusId() == 10

    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 11,
        appId: "kitty",
        title: "later",
        createdIdentifier: "later-id",
      )
    )

    check model.focusedWindowId() == 10
    check model.activeWorkspaceFocusId() == 10
    check model.focusHistory == @[WindowId(2), WindowId(1)]

  test "Non-scroller layouts ignore workspace viewport offsets":
    for mode in [LayoutMode.Grid, LayoutMode.Deck]:
      var baseline = cameraModel()
      baseline.seedCameraWindows(3)
      baseline.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))
      let baselineGeom = baseline.instructionGeom(1)

      var shifted = cameraModel()
      shifted.seedCameraWindows(3)
      shifted.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))
      shifted.setViewport(
        1, targetX = 100.0, currentX = 100.0, targetY = 25.0, currentY = 25.0
      )
      let shiftedGeom = shifted.instructionGeom(1)

      check shifted.viewport(1).currentViewportXOffset == 100.0'f32
      check shifted.viewport(1).currentViewportYOffset == 25.0'f32
      check shiftedGeom.x == baselineGeom.x
      check shiftedGeom.y == baselineGeom.y

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
