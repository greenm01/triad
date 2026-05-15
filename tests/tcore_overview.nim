import std/algorithm
import tcore_support

proc geomWithinPreview(geom, preview: runtime_values.Rect): bool =
  geom.x >= preview.x and geom.y >= preview.y and
    geom.x + geom.w <= preview.x + preview.w and geom.y + geom.h <= preview.y + preview.h

proc markColumnsFullWidth(model: var Model, slot: uint32) =
  let tagId = model.tagForSlot(slot)
  for columnId, _ in model.columnsOnTagWithId(tagId):
    discard model.setColumnFullWidth(columnId, true)

suite "Core Runtime Logic: overview navigation":
  test "Opening overview initializes visible selection":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    let effects = model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Overview shell focus clear preserves selected window":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 0))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.len == 0

  test "Overview hit testing uses topmost preview under pointer":
    let instructions =
      @[
        RenderInstruction(
          windowId: 1, geom: runtime_values.Rect(x: 0, y: 0, w: 100, h: 100)
        ),
        RenderInstruction(
          windowId: 2, geom: runtime_values.Rect(x: 50, y: 50, w: 100, h: 100)
        ),
        RenderInstruction(
          windowId: 3, geom: runtime_values.Rect(x: 200, y: 50, w: 100, h: 100)
        ),
      ]

    check overviewHitTest(instructions, 10, 10) == 1
    check overviewHitTest(instructions, 60, 60) == 2
    check overviewHitTest(instructions, 220, 70) == 3
    check overviewHitTest(instructions, 400, 400) == 0

  test "Overview hit testing ignores clipped preview overflow":
    let instructions =
      @[
        RenderInstruction(
          windowId: 1,
          geom: runtime_values.Rect(x: 0, y: 0, w: 100, h: 200),
          clipSet: true,
          clip: runtime_values.Rect(x: 0, y: 0, w: 100, h: 100),
        ),
        RenderInstruction(
          windowId: 2,
          geom: runtime_values.Rect(x: 0, y: 100, w: 100, h: 100),
          clipSet: true,
          clip: runtime_values.Rect(x: 0, y: 100, w: 100, h: 100),
        ),
      ]

    check overviewHitTest(instructions, 10, 50) == 1
    check overviewHitTest(instructions, 10, 150) == 2

  test "Scroller overview projects workspace previews":
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

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let one = projection.instructions.filterIt(uint32(it.windowId) == 1)[0].geom
    let two = projection.instructions.filterIt(uint32(it.windowId) == 2)[0].geom
    let activePreview = model.workspacePreviewRect(screen, slots, 0)
    let secondPreview = model.workspacePreviewRect(screen, slots, 1)

    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check one.x >= activePreview.x
    check one.y >= activePreview.y
    check one.x + one.w <= activePreview.x + activePreview.w
    check one.y + one.h <= activePreview.y + activePreview.h
    check two.x >= secondPreview.x
    check two.y >= secondPreview.y
    check two.x + two.w <= secondPreview.x + secondPreview.w
    check two.y + two.h <= secondPreview.y + secondPreview.h

  test "Scroller overview fits the full horizontal strip":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.markColumnsFullWidth(1)
    model.setViewport(1, targetX = 1000.0, currentX = 1000.0)
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let workspaceOne =
      projection.instructions.filterIt(uint32(it.windowId) in @[1'u32, 2'u32, 3'u32])
    var geoms = workspaceOne.mapIt(it.geom)
    geoms.sort(
      proc(a, b: runtime_values.Rect): int =
        cmp(a.x, b.x)
    )

    check workspaceOne.len == 3
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == activePreview)
    check geoms.allIt(it.geomWithinPreview(activePreview))
    check geoms[0].x < geoms[1].x
    check geoms[1].x < geoms[2].x

  test "Vertical scroller overview fits the full vertical strip":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.markColumnsFullWidth(1)
    model.setViewport(
      1, targetX = 0.0, currentX = 0.0, targetY = 700.0, currentY = 700.0
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let workspaceOne =
      projection.instructions.filterIt(uint32(it.windowId) in @[1'u32, 2'u32, 3'u32])
    var geoms = workspaceOne.mapIt(it.geom)
    geoms.sort(
      proc(a, b: runtime_values.Rect): int =
        cmp(a.y, b.y)
    )

    check workspaceOne.len == 3
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == activePreview)
    check geoms.allIt(it.geomWithinPreview(activePreview))
    check geoms[0].y < geoms[1].y
    check geoms[1].y < geoms[2].y

  test "Overview clips overflowing workspace preview contents":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 2'u32 .. 4'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.setViewport(
      2, targetX = 0.0, currentX = 0.0, targetY = -700.0, currentY = -700.0
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let secondPreview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let workspaceTwo =
      projection.instructions.filterIt(uint32(it.windowId) in @[2'u32, 3'u32, 4'u32])

    check workspaceTwo.len == 3
    check workspaceTwo.allIt(it.clipSet)
    check workspaceTwo.allIt(it.clip == secondPreview)
    check workspaceTwo.allIt(it.geom.geomWithinPreview(secondPreview))

  test "Non-scroller overview projects workspace previews":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, 0)

    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check model.overviewUsesWorkspacePreviews()
    check projection.instructions.len == 2
    check projection.instructions.allIt(it.geom.x >= activePreview.x)
    check projection.instructions.allIt(it.geom.y >= activePreview.y)
    check projection.instructions.allIt(
      it.geom.x + it.geom.w <= activePreview.x + activePreview.w
    )
    check projection.instructions.allIt(
      it.geom.y + it.geom.h <= activePreview.y + activePreview.h
    )

  test "Unified overview direction focus follows workspace layout":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    for id in 1'u32 .. 5'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let activeTag = model.activeTag

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let rightEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
    )
    check model.selectedOverviewWindow() == WindowId(2)
    check model.activeWorkspaceFocusId() == 2
    let previewSnapshot = model.shellSnapshot()
    check previewSnapshot.overviewSelectedWindow == 2
    check rightEffects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check not rightEffects.anyIt(it.kind == EffectKind.EffFocusWindow)
    check rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowFocusChanged")
    )
    check not rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )
    check not rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowsChanged")
    )
    check rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and it.triadEventName == "state"
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
    check model.selectedOverviewWindow() == WindowId(5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
    check model.selectedOverviewWindow() == WindowId(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
    check model.selectedOverviewWindow() == WindowId(5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
    check model.selectedOverviewWindow() == WindowId(3)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusNext))
    check model.selectedOverviewWindow() == WindowId(4)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusPrev))
    check model.selectedOverviewWindow() == WindowId(3)

    check model.activeTag == activeTag

    let closeEffects = model.updateModel(Msg(kind: MsgKind.CmdCloseOverview))
    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == 3
    check closeEffects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 3
    )

  test "Unified overview keeps workspace focus commands live":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == WindowId(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

    let downEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(3)
    check model.selectedOverviewWindow() == NullWindowId
    check downEffects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Unified overview workspace crossing updates shell workspaces":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let windowEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check windowEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )

    let navEffects = model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(3)
    check navEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )

  test "Unified overview fallback up key stays inside grid before workspace edge":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    for id in 1'u32 .. 4'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(3)
    check model.selectedOverviewWindow() == WindowId(1)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Unified overview workspace navigation visits visible previews and wraps":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(2)
    check model.activeWorkspaceFocusId() == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(3)
    check model.activeWorkspaceFocusId() == 3

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(4)
    check model.activeWorkspaceFocusId() == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
    check model.activeTag == model.tagForSlot(4)
    check model.activeWorkspaceFocusId() == 0

  test "Unified overview keeps workspace navigation live":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2
    check model.overviewSelectedWindow == NullWindowId
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Unified overview keeps preview style after navigating to grid workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid, layoutTargetTag: 2)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check model.overviewUsesWorkspacePreviews()

  test "Selecting empty overview workspace enters it without window fallback":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == NullWindowId

    let effects = model.updateModel(Msg(kind: MsgKind.CmdSelectWindow))
    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 0
    check model.activeWorkspaceFocusId() == 0
    check not effects.anyIt(it.kind == EffectKind.EffFocusWindow)

  test "Selecting overview window commits focus":
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

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdSelectWindow))

    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == 2
    check model.activeTag == model.tagForSlot(2)
    check effects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 2
    )
