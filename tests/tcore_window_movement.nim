import tcore_support
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/systems/runtime

suite "Core Runtime Logic: window movement":
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
        tagRules:
          @[
            TagRule(
              tagId: 2, defaultLayoutSet: true, defaultLayout: LayoutMode.Scroller
            ),
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
        tagRules:
          @[
            TagRule(
              tagId: 2, defaultLayoutSet: true, defaultLayout: LayoutMode.Scroller
            ),
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
        windowRules:
          @[
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
        windowRules:
          @[
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
        windowRules:
          @[
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
        windowRules:
          @[
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
