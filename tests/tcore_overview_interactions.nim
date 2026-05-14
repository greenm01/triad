import tcore_support

suite "Core Runtime Logic: overview interactions":
  test "Dragging unified overview preview moves window without closing":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let start = model.instructionGeom(1).rectCenter()
    let slots = model.previewSlots()
    let target =
      model.workspacePreviewRect(model.primaryScreen(), slots, 1).rectCenter()
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlOverviewPointerDragRequested,
        overviewDragWinId: 1,
        overviewDragX: start.x,
        overviewDragY: start.y,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlPointerDelta, dx: target.x - start.x, dy: target.y - start.y)
    )
    model.applyMsg(Msg(kind: MsgKind.WlPointerRelease))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(1)
    check model.activeWorkspaceFocusId() == 0
    check model.firstWindowPosition(WindowId(1)).tagId == model.tagForSlot(2)

  test "Right-dragging unified overview pans hovered workspace camera":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    let beforeViewport = model.viewport(1)

    let start = model.instructionGeom(1).rectCenter()
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlOverviewPointerScrollRequested,
        overviewScrollX: start.x,
        overviewScrollY: start.y,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlPointerDelta, dx: 50, dy: 0))
    model.applyMsg(Msg(kind: MsgKind.WlPointerRelease))

    check model.overviewActive
    check model.viewport(1).currentViewportXOffset ==
      beforeViewport.currentViewportXOffset - 100.0'f32
    check model.viewport(1).targetViewportXOffset ==
      beforeViewport.targetViewportXOffset - 100.0'f32
    check model.pointerOp.kind == PointerOpKind.OpNone

  test "Wheel over unified overview switches workspaces vertically":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let slots = model.previewSlots()
    let target = model
      .workspacePreviewRect(model.primaryScreen(), slots, slots.find(1'u32))
      .rectCenter()
    let effects = model.updateModel(
      Msg(
        kind: MsgKind.WlOverviewWheel,
        overviewWheelX: target.x,
        overviewWheelY: target.y,
        overviewWheelHorizontal: 0,
        overviewWheelVertical: 1,
      )
    )

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == WindowId(2)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )

  test "Wheel over unified overview focuses columns horizontally":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let slots = model.previewSlots()
    let target = model
      .workspacePreviewRect(model.primaryScreen(), slots, slots.find(1'u32))
      .rectCenter()
    let horizontalEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlOverviewWheel,
        overviewWheelX: target.x,
        overviewWheelY: target.y,
        overviewWheelHorizontal: 1,
        overviewWheelVertical: 0,
      )
    )

    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(2)
    check not horizontalEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )

    model.applyMsg(
      Msg(kind: MsgKind.WlModifiersChanged, oldModifiers: 0'u32, newModifiers: 1'u32)
    )
    let shiftEffects = model.updateModel(
      Msg(
        kind: MsgKind.WlOverviewWheel,
        overviewWheelX: target.x,
        overviewWheelY: target.y,
        overviewWheelHorizontal: 0,
        overviewWheelVertical: 1,
      )
    )

    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(3)
    check not shiftEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )

  test "Holding unified overview drag over workspace activates drop":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let start = model.instructionGeom(1).rectCenter()
    let slots = model.previewSlots()
    let target =
      model.workspacePreviewRect(model.primaryScreen(), slots, 1).rectCenter()
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOverviewPointerDragRequested,
        overviewDragWinId: 1,
        overviewDragX: start.x,
        overviewDragY: start.y,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlPointerDelta, dx: target.x - start.x, dy: target.y - start.y)
    )
    for _ in 0 ..< 47:
      model.applyMsg(Msg(kind: MsgKind.CmdTick))

    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.activeWorkspaceFocusId() == 1

  test "Clicking overview window commits focus":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))

    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2
    check effects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 2
    )

  test "Clicking blank unified overview workspace activates workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let slots = model.previewSlots()
    let target = model.workspacePreviewRect(model.primaryScreen(), slots, 1)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOverviewPointerDragRequested,
        overviewDragWinId: 0,
        overviewDragX: target.x + 1,
        overviewDragY: target.y + 1,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlPointerRelease))

    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2

  test "Clicking blank trailing dynamic overview workspace enters it":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let slots = model.previewSlots()
    let target =
      model.workspacePreviewRect(model.primaryScreen(), slots, slots.find(4'u32))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlOverviewPointerDragRequested,
        overviewDragWinId: 0,
        overviewDragX: target.x + 1,
        overviewDragY: target.y + 1,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.WlPointerRelease))

    check not model.overviewActive
    check model.activeTag == model.tagForSlot(4)
    check model.focusedWindowId() == 0
    check model.activeWorkspaceFocusId() == 0

  test "Overview select retargets same-workspace camera":
    var model = cameraModel()
    model.seedCameraWindows()
    model.setViewport(1, targetX = 125.0, currentX = 125.0)

    let beforeViewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdSelectWindow))

    check model.focusedWindowId() == 1
    check model.viewport(1) == beforeViewport
    discard model.layoutInstructions()
    check model.viewport(1).currentViewportXOffset ==
      beforeViewport.currentViewportXOffset
    check model.viewport(1).targetViewportXOffset != beforeViewport.targetViewportXOffset

  test "Unified overview camera retarget animates while overview is open":
    var model = cameraModel()
    model.seedCameraWindows()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    let target = model.viewport(1).targetViewportXOffset

    check model.overviewActive
    check target != 0.0'f32
    check model.viewport(1).currentViewportXOffset == 0.0'f32

    discard model.updateModel(Msg(kind: MsgKind.CmdTick))

    check model.viewport(1).currentViewportXOffset != 0.0'f32
    check model.viewport(1).currentViewportXOffset != target
    let afterTick = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdCloseOverview))

    check not model.overviewActive
    check model.viewport(1) == afterTick

  test "Unified overview ticks non-active preview workspace cameras":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.setViewport(2, targetX = 0.0, currentX = 0.0)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    discard model.layoutInstructions()
    let target = model.viewport(2).targetViewportXOffset
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(1)
    check target != 0.0'f32
    check model.viewport(2).currentViewportXOffset == 0.0'f32

    discard model.updateModel(Msg(kind: MsgKind.CmdTick))

    check model.viewport(2).currentViewportXOffset != 0.0'f32
    check model.viewport(2).currentViewportXOffset != target

  test "Overview select retargets target workspace camera":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.setViewport(2, targetX = 250.0, currentX = 175.0)
    let workspace2Viewport = model.viewport(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.setViewport(1, targetX = 80.0, currentX = 80.0)
    let workspace1Viewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdSelectWindow))

    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2
    check model.viewport(1) == workspace1Viewport
    check model.viewport(2) == workspace2Viewport
    discard model.layoutInstructions()
    check model.viewport(1) == workspace1Viewport
    check model.viewport(2).currentViewportXOffset ==
      workspace2Viewport.currentViewportXOffset
    check model.viewport(2).targetViewportXOffset !=
      workspace2Viewport.targetViewportXOffset

  test "Closing unified overview preserves camera changes":
    var model = cameraModel()
    model.seedCameraWindows()
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.setViewport(1, targetX = 300.0, currentX = 100.0)
    let beforeViewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    discard model.updateModel(Msg(kind: MsgKind.CmdTick))
    let afterTick = model.viewport(1)
    model.applyMsg(Msg(kind: MsgKind.CmdCloseOverview))

    check model.viewport(1) == afterTick
    check model.viewport(1) != beforeViewport

  test "Workspace round trip preserves each camera":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.setViewport(1, targetX = 300.0, currentX = 0.0)
    let workspace1Viewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.setViewport(2, targetX = 75.0, currentX = 75.0)
    let workspace2Viewport = model.viewport(2)

    for _ in 0 ..< 4:
      discard model.updateModel(Msg(kind: MsgKind.CmdTick))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    check model.viewport(1) == workspace1Viewport
    check model.viewport(2) == workspace2Viewport

  test "Normal focus navigation can retarget camera":
    var model = cameraModel()
    model.seedCameraWindows()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()

    check model.viewport(1).targetViewportXOffset != 0.0'f32

  test "External focus observation uses normal focus path":
    var model = cameraModel()
    model.seedCameraWindows()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 1
    check effects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 1
    )
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check model.viewport(1).targetViewportXOffset != 0.0'f32
