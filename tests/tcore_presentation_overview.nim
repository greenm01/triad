import ../src/systems/daemon_view
import tcore_support

suite "Core Runtime Logic: presentation overview":
  test "Open-fullscreen window rule creates tiled fullscreen window":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "video",
              openFloatingSet: true,
              openFloating: true,
              openFullscreenSet: true,
              openFullscreen: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "video", title: "Movie")
    )
    let win = model.snapshotWindow(2)

    check win.isFullscreen
    check win.fullscreenOutput == 1
    check not win.isFloating
    check effects.hasFullscreenEffect(2, true)

  test "Open-maximized-to-edges window rule creates tiled edge-maximized window":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "editor",
              openFloatingSet: true,
              openFloating: true,
              openMaximizedToEdgesSet: true,
              openMaximizedToEdges: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "editor", title: "Main")
    )
    let win = model.snapshotWindow(2)

    check win.isMaximized
    check not win.isFloating
    check effects.hasMaximizedEffect(2, true)
    check model.instructionGeom(2) == model.primaryScreen()

  test "Edge-maximized presentation suppresses compositor border":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(borderWidth: 4),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "editor", title: "Main")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdToggleMaximized))

    let screen = model.primaryScreen()
    let projection = model.layoutProjection()
    let instr = projection.instructions.filterIt(it.windowId == 2'u32)[0]
    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    let state = daemon.desiredRenderWindowState(2, instr.geom, screen, false)

    check model.windowUsesBorderlessPresentation(
      model.windowForExternal(ExternalWindowId(2))
    )
    check model.renderWindowBorder(model.windowForExternal(ExternalWindowId(2)), true).width ==
      0
    check instr.geom == screen
    check state.visible
    check state.borderWidth == 0
    check state.renderBorderWidth == 0
    check state.borderEdges == 0

  test "Fullscreen presentation suppresses compositor border":
    var model = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(borderWidth: 4),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "video", title: "Movie")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdToggleFullscreen))

    let screen = model.primaryScreen()
    let projection = model.layoutProjection()
    let instr = projection.instructions.filterIt(it.windowId == 2'u32)[0]
    var daemon = initTriadDaemon()
    daemon.runtimeState.model = model
    let state = daemon.desiredRenderWindowState(2, instr.geom, screen, false)

    check model.windowUsesBorderlessPresentation(
      model.windowForExternal(ExternalWindowId(2))
    )
    check model.renderWindowBorder(model.windowForExternal(ExternalWindowId(2)), true).width ==
      0
    check instr.geom == screen
    check state.visible
    check state.borderWidth == 0
    check state.renderBorderWidth == 0
    check state.borderEdges == 0

  test "Open-maximized window rule opens full-width scroller column":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "docs",
              openFloatingSet: true,
              openFloating: true,
              openMaximizedSet: true,
              openMaximized: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "docs", title: "Manual")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))
    let win = model.snapshotWindow(2)

    check placement.found
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check model.columnData(columnId).get().isFullWidth
    check not win.isMaximized
    check not win.isFloating
    check not effects.hasMaximizedEffect(2, true)

  test "Open-maximized window rule is ignored outside scroller layouts":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Grid),
        windowRules:
          @[WindowRule(appIdMatch: "docs", openMaximizedSet: true, openMaximized: true)],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "docs", title: "Manual")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))

    check placement.found
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check not model.columnData(columnId).get().isFullWidth
    check not model.snapshotWindow(2).isMaximized

  test "Open state rule precedence chooses fullscreen then edges then column":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3, defaultLayout: LayoutMode.Scroller),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "conflict",
              openFloatingSet: true,
              openFloating: true,
              openFullscreenSet: true,
              openFullscreen: true,
              openMaximizedSet: true,
              openMaximized: true,
              openMaximizedToEdgesSet: true,
              openMaximizedToEdges: true,
            )
          ],
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "conflict", title: "Main")
    )
    let placement =
      model.firstWindowPosition(model.windowForExternal(ExternalWindowId(2)))
    let win = model.snapshotWindow(2)

    check win.isFullscreen
    check not win.isMaximized
    check not win.isFloating
    check placement.found
    let columnId = model.columnAt(placement.tagId, int(placement.colIdx) - 1)
    check not model.columnData(columnId).get().isFullWidth

  test "Live restore state wins over open state rules":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 3),
        windowRules:
          @[
            WindowRule(
              appIdMatch: "generic-app",
              openFullscreenSet: true,
              openFullscreen: true,
              openFloatingSet: true,
              openFloating: true,
            )
          ],
      )
    ).model
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(
      ExternalWindowId(50), 1, "generic-app", "Old title", isMaximized = true
    )
    model.applyLiveRestore(restore)

    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 50,
        appId: "generic-app",
        title: "Old title",
      )
    )
    let win = model.snapshotWindow(50)

    check win.isMaximized
    check not win.isFullscreen
    check not win.isFloating
    check not effects.hasFullscreenEffect(50, true)

  test "Fullscreen presentation follows active focus":
    var model = cameraModel()
    model.seedCameraWindows(2)

    let fullscreenEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 2,
        fullscreenOutputId: 0,
      )
    )
    check fullscreenEffects.hasFullscreenEffect(2, true)

    let leaveEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    check leaveEffects.hasFullscreenEffect(2, false)

    let returnEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    check returnEffects.hasFullscreenEffect(2, true)

  test "Grid suspends maximized presentation without clearing state":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    let screen = model.primaryScreen()
    let win = model.snapshotWindow(2)
    let geom = model.instructionGeom(2)

    check win.isMaximized
    check effects.hasMaximizedEffect(2, false)
    check geom != screen
    check geom.w < screen.w

  test "Scroller restores suspended maximized presentation":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )
    discard
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
    let screen = model.primaryScreen()

    check model.snapshotWindow(2).isMaximized
    check effects.hasMaximizedEffect(2, true)
    check model.instructionGeom(2) == screen

  test "Non-scroller layouts do not present maximized windows":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )

    for mode in [LayoutMode.MasterStack, LayoutMode.Deck, LayoutMode.Monocle]:
      let effects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))
      check model.snapshotWindow(2).isMaximized
      check effects.hasMaximizedEffect(2, false)
      check model.instructionGeom(2) != model.primaryScreen()

  test "Minimize preserves desired maximized state":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )

    let minimizeEffects = model.updateModel(Msg(kind: MsgKind.CmdMinimize))
    let minimized = model.snapshotWindow(2)

    check minimized.isMaximized
    check minimized.isMinimized
    check minimizeEffects.hasMaximizedEffect(2, false)

    let restoreEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let restored = model.snapshotWindow(2)

    check restored.isMaximized
    check not restored.isMinimized
    check restoreEffects.hasMaximizedEffect(2, true)

  test "Floating popup preserves maximized backing windows":
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
        windowRules: @[WindowRule(appIdMatch: "pinentry", openFloating: true)],
      )
    ).model
    model.seedCameraWindows(2)

    let firstMaxEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let secondMaxEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )

    check model.snapshotWindow(1).isMaximized
    check firstMaxEffects.hasMaximizedEffect(1, false)
    check secondMaxEffects.hasMaximizedEffect(2, true)

    let popupEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 3, appId: "pinentry", title: "Password"
      )
    )
    let screen = model.primaryScreen()

    check not popupEffects.hasMaximizedEffect(1, false)
    check not popupEffects.hasMaximizedEffect(2, false)
    check popupEffects.hasMaximizedEffect(1, true)
    check model.instructionGeom(1) == screen
    check model.instructionGeom(2) == screen
    check model.instructionGeom(3).w > 0
    check model.focusedWindowId() == 3

  test "Scratchpad preserves backing window presentation":
    var maximizedModel = cameraModel()
    maximizedModel.seedCameraWindows(2)
    discard maximizedModel.updateModel(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1)
    )
    discard maximizedModel.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard maximizedModel.updateModel(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2)
    )
    discard maximizedModel.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let scratchpadEffects =
      maximizedModel.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))

    check maximizedModel.focusedWindowId() == 2
    check scratchpadEffects.hasFocusEffect(2)
    check scratchpadEffects.hasMaximizedEffect(1, true)
    check not scratchpadEffects.hasMaximizedEffect(1, false)

    var fullscreenModel = cameraModel()
    fullscreenModel.seedCameraWindows(2)
    discard fullscreenModel.updateModel(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1)
    )
    discard fullscreenModel.updateModel(
      Msg(kind: MsgKind.WlWindowFullscreenRequested, fullscreenRequestId: 1)
    )
    discard fullscreenModel.updateModel(
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2)
    )
    discard fullscreenModel.updateModel(Msg(kind: MsgKind.CmdMoveToScratchpad))

    let fullscreenScratchpadEffects =
      fullscreenModel.updateModel(Msg(kind: MsgKind.CmdToggleScratchpad))

    check fullscreenModel.focusedWindowId() == 2
    check fullscreenScratchpadEffects.hasFocusEffect(2)
    check fullscreenScratchpadEffects.hasFullscreenEffect(1, true)
    check not fullscreenScratchpadEffects.hasFullscreenEffect(1, false)

  test "Parented popup ignores unrelated maximized backing window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))

    let popupEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
      )
    )
    let screen = model.primaryScreen()
    discard model.layoutInstructions()
    let viewportTarget = model.viewport(1).targetViewportXOffset
    model.setViewport(1, targetX = viewportTarget, currentX = viewportTarget)
    let parentGeom = model.instructionGeom(3)
    let popupGeom = model.instructionGeom(4)

    check popupEffects.hasMaximizedEffect(1, false)
    check model.snapshotWindow(1).isMaximized
    check model.instructionGeom(1) != screen
    check parentGeom != screen
    check popupGeom.x == parentGeom.x + (parentGeom.w - popupGeom.w) div 2
    check popupGeom.y == parentGeom.y + (parentGeom.h - popupGeom.h) div 2
    check model.focusedWindowId() == 4

  test "Parented popup preserves maximized parent backing":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    discard model.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 3)
    )

    let popupEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 4,
        createdParentWindowId: 3,
        appId: "xdg-desktop-portal-gtk",
        title: "Open Document",
      )
    )
    let screen = model.primaryScreen()
    let popupGeom = model.instructionGeom(4)

    check popupEffects.hasMaximizedEffect(1, false)
    check not popupEffects.hasMaximizedEffect(3, false)
    check model.instructionGeom(1) != screen
    check model.instructionGeom(3) == screen
    check popupGeom.w > 0
    check model.focusedWindowId() == 4

  test "Floating popup preserves fullscreen presentation":
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
        windowRules: @[WindowRule(appIdMatch: "pinentry", openFloating: true)],
      )
    ).model
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 2,
        fullscreenOutputId: 0,
      )
    )

    let popupEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 3, appId: "pinentry", title: "Password"
      )
    )
    let screen = model.primaryScreen()

    check not popupEffects.hasFullscreenEffect(2, false)
    check model.instructionGeom(2) == screen
    check model.instructionGeom(3).w > 0
    check model.focusedWindowId() == 3

  test "Overlay window preserves fullscreen presentation":
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
        windowRules: @[WindowRule(appIdMatch: "hud", openOverlay: true)],
      )
    ).model
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 2,
        fullscreenOutputId: 0,
      )
    )

    let overlayEffects = model.updateModel(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "hud", title: "HUD")
    )
    let screen = model.primaryScreen()

    check model.windowData(model.windowForExternal(ExternalWindowId(3))).get().isOverlay
    check not model
    .windowData(model.windowForExternal(ExternalWindowId(3)))
    .get().isFloating
    check not overlayEffects.hasFullscreenEffect(2, false)
    check model.instructionGeom(2) == screen
    check model.instructionGeom(3).w > 0
    check model.focusedWindowId() == 3

  test "Overview suspends fullscreen presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 1,
        fullscreenOutputId: 0,
      )
    )

    let effects = model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check effects.hasFullscreenEffect(1, false)

  test "Overview shows edge-maximized scroller window like full-width column":
    var edgeModel = cameraModel()
    edgeModel.seedCameraWindows(1)
    discard edgeModel.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard edgeModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    var columnModel = cameraModel()
    columnModel.seedCameraWindows(1)
    discard columnModel.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard columnModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    let tagId = edgeModel.activeTag
    let columnId = edgeModel.columnAt(tagId, 0)
    check not edgeModel.columnData(columnId).get().isFullWidth
    check edgeModel.instructionGeom(1) == columnModel.instructionGeom(1)

  test "Overview shows edge-maximized vertical scroller window like full-width column":
    var edgeModel = cameraModel()
    edgeModel.seedCameraWindows(1)
    discard edgeModel.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    discard edgeModel.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 1)
    )
    discard edgeModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    var columnModel = cameraModel()
    columnModel.seedCameraWindows(1)
    discard columnModel.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    discard columnModel.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard columnModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check edgeModel.instructionGeom(1) == columnModel.instructionGeom(1)

  test "Overview does not apply scroller maximize sizing to grid":
    var normalModel = cameraModel()
    normalModel.seedCameraWindows(2)
    discard normalModel.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid)
    )
    discard normalModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    var maximizedModel = cameraModel()
    maximizedModel.seedCameraWindows(2)
    discard maximizedModel.updateModel(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid)
    )
    discard maximizedModel.updateModel(
      Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 2)
    )
    discard maximizedModel.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check maximizedModel.instructionGeom(2) == normalModel.instructionGeom(2)

  test "Targeted fullscreen IPC can repair a non-focused window":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 2,
        fullscreenOutputId: 0,
      )
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdExitFullscreenById, fullscreenWindowId: 2))
    let winId = model.windowForExternal(ExternalWindowId(2))

    check winId != NullWindowId
    check not model.windowData(winId).get().isFullscreen
    check effects.hasFullscreenEffect(2, false)

  test "Moving focused window across columns preserves focus":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveWindowLeft))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Moving focused stacked window preserves focus":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )

    let tagId = model.tagForSlot(1)
    let firstColumn = model.columnAt(tagId, 0)
    let winId = model.windowForExternal(ExternalWindowId(2))
    discard model.moveWindowToColumn(tagId, winId, firstColumn, 1)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveWindowUp))

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "No-op focused window move does not reassert focus":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveWindowUp))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 1
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check not effects.hasFocusEffect(1)
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Moving focused column retargets camera":
    var model = cameraModel()
    model.seedCameraWindows(2)
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveColumnLeft))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
