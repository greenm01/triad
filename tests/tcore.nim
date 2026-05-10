import json, options, sequtils, strutils, tables, unittest
import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/render_visibility
import ../src/core/restore_state
import ../src/state/engine
import ../src/systems/layout_projection
import ../src/systems/runtime_facade
import ../src/systems/update
import ../src/types/model
import ../src/types/runtime_values except WindowId
import tag_semantics_checks

proc configuredModel(): Model =
  initRuntimeStateFromConfig(Config(
    layout: LayoutConfig(
      gaps: 10,
      defaultColumnWidth: 0.7,
      defaultWindowWidth: 0.8,
      defaultWindowHeight: 0.6,
      defaultMasterCount: 2,
      defaultMasterRatio: 0.65),
    workspaces: WorkspaceConfig(defaultCount: 3),
    windowRules: @[
      WindowRule(appIdMatch: "float-me", openFloating: true),
      WindowRule(appIdMatch: "qemu", keyboardShortcutsInhibit: true)
    ])).model

proc cameraModel(): Model =
  initRuntimeStateFromConfig(Config(
    layout: LayoutConfig(
      gaps: 10,
      defaultColumnWidth: 0.7,
      centerFocusedColumn: "always",
      enableAnimations: true,
      animationSpeed: 0.5),
    workspaces: WorkspaceConfig(defaultCount: 3))).model

proc applyMsg(model: var Model; msg: Msg) =
  let (nextModel, _) = model.update(msg)
  model = nextModel

proc focusedWindowId(model: Model): uint32 =
  for win in model.shellSnapshot().windows:
    if win.isFocused:
      return uint32(win.id)
  0'u32

proc activeWorkspaceFocusId(model: Model): uint32 =
  for workspace in model.shellSnapshot().workspaces:
    if workspace.isActive:
      return uint32(workspace.focusedWindow)
  0'u32

proc updateModel(model: var Model; msg: Msg): seq[Effect] =
  let (nextModel, effects) = model.update(msg)
  model = nextModel
  effects

proc hasFocusEffect(effects: seq[Effect]; id: uint32): bool =
  effects.anyIt(it.kind == EffectKind.EffFocusWindow and
    uint32(it.focusId) == id)

proc viewport(model: Model; slot: uint32): ViewportState =
  let tagId = model.tagForSlot(slot)
  let tag = model.tagData(tagId).get()
  ViewportState(
    targetViewportXOffset: tag.targetViewportXOffset,
    currentViewportXOffset: tag.currentViewportXOffset,
    targetViewportYOffset: tag.targetViewportYOffset,
    currentViewportYOffset: tag.currentViewportYOffset)

proc setViewport(
    model: var Model; slot: uint32; targetX, currentX: float32;
    targetY = 0.0'f32; currentY = 0.0'f32) =
  let tagId = model.tagForSlot(slot)
  discard model.setTagViewportTarget(tagId, targetX, targetY)
  discard model.setTagViewportCurrent(tagId, currentX, currentY)

proc seedCameraWindows(model: var Model; count = 3'u32) =
  model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
    width: 1000, height: 700))
  for id in 1'u32 .. count:
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: id,
      appId: "app", title: "Window " & $id))

suite "Core Runtime Logic":
  test "Triad reload command emits restart effect":
    var model = Model()
    let (_, effects) = model.update(Msg(kind: MsgKind.CmdTriadReload))
    check effects.len == 1
    check effects[0].kind == EffectKind.EffTriadReload

  test "Targeted layout command updates requested slot only":
    var model = configuredModel()
    let (nextModel, effects) =
      model.update(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck,
        layoutTargetTag: 2))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.activeTag == 1
    check snapshot.workspaces[0].layoutMode == LayoutMode.Scroller
    check snapshot.workspaces[1].layoutMode == LayoutMode.Deck
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and
      it.jsonPayload.contains("layout-state-changed"))

  test "Render visibility suppresses clipped scroller border rails":
    let screen = runtime_values.Rect(x: 0, y: 0, w: 100, h: 80)

    let full = renderVisibility(
      runtime_values.Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)
    check full.visible
    check not full.clipped
    check full.borderEdges == RenderAllEdges

    let leftClip =
      renderVisibility(
        runtime_values.Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    check leftClip.visible
    check leftClip.clipped
    check (leftClip.borderEdges and RenderEdgeLeft) == 0
    check (leftClip.borderEdges and RenderEdgeRight) == 0
    let leftClips = leftClip.renderClipBoxes(3)
    check leftClips.contentX == 20
    check leftClips.contentY == 0
    check leftClips.contentW == 40
    check leftClips.contentH == 30
    check leftClips.windowX == 20
    check leftClips.windowW == 40
    check leftClips.windowY == -3
    check leftClips.windowH == 36

    let sliver =
      renderVisibility(
        runtime_values.Rect(x: -98, y: 10, w: 100, h: 30), screen, 4)
    check not sliver.visible
    check sliver.borderEdges == 0

  test "Forced cell clipping preserves border space":
    let screen = runtime_values.Rect(x: 0, y: 0, w: 100, h: 80)
    let cell = renderVisibility(
      runtime_values.Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)

    let clips = cell.renderClipBoxes(3)
    check clips.contentX == 0
    check clips.contentY == 0
    check clips.contentW == 40
    check clips.contentH == 30
    check clips.windowX == -3
    check clips.windowY == -3
    check clips.windowW == 46
    check clips.windowH == 36

    let clipped = renderVisibility(
      runtime_values.Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    let clippedBoxes = clipped.renderClipBoxes(3)
    check clippedBoxes.contentX == 20
    check clippedBoxes.contentW == 40
    check clippedBoxes.windowX == 20
    check clippedBoxes.windowW == 40
    check clippedBoxes.windowY == -3
    check clippedBoxes.windowH == 36

  test "Window lifecycle mutates state and emits shell updates":
    var model = configuredModel()
    let (nextModel, effects) = model.update(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 100,
      appId: "firefox",
      title: "Mozilla Firefox"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 100
    check snapshot.windows[0].appId == "firefox"
    check snapshot.workspaces[0].focusedWindow == 100
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))

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
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Two"))

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

  test "Opening overview initializes visible selection":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Overview shell focus clear preserves selected window":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged,
      newFocusedId: 0))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.len == 0

  test "Overview direction selection follows visual grid":
    var model = configuredModel()
    for id in 1'u32 .. 5'u32:
      model.applyMsg(Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: id,
        appId: "app",
        title: "Window " & $id))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let activeTag = model.activeTag
    let activeFocus = model.activeWorkspaceFocusId()
    let focusHistory = model.focusHistory
    let workspaceHistory = model.workspaceHistory

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let rightEffects = model.updateModel(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirRight))
    check model.selectedOverviewWindow() == WindowId(2)
    check model.activeWorkspaceFocusId() == activeFocus
    let previewSnapshot = model.shellSnapshot()
    check previewSnapshot.overviewSelectedWindow == 2
    check model.focusedWindowId() == activeFocus
    check rightEffects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check not rightEffects.anyIt(it.kind == EffectKind.EffFocusWindow)
    check not rightEffects.anyIt(it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowFocusChanged"))
    check not rightEffects.anyIt(it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WorkspacesChanged"))
    check not rightEffects.anyIt(it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowsChanged"))
    check rightEffects.anyIt(it.kind == EffectKind.EffBroadcastTriadJson and
      it.triadEventName == "state")

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirLeft))
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirDown))
    check model.selectedOverviewWindow() == WindowId(5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirUp))
    check model.selectedOverviewWindow() == WindowId(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirDown))
    check model.selectedOverviewWindow() == WindowId(5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection,
      direction: Direction.DirRight))
    check model.selectedOverviewWindow() == WindowId(5)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusNext))
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusPrev))
    check model.selectedOverviewWindow() == WindowId(5)

    check model.activeTag == activeTag
    check model.activeWorkspaceFocusId() == activeFocus
    check model.focusHistory == focusHistory
    check model.workspaceHistory == workspaceHistory

    let closeEffects = model.updateModel(Msg(kind: MsgKind.CmdCloseOverview))
    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == activeFocus
    check closeEffects.anyIt(it.kind == EffectKind.EffFocusWindow and
      uint32(it.focusId) == activeFocus)

  test "Overview ignores workspace focus commands":
    var model = configuredModel()
    for id in 1'u32 .. 5'u32:
      model.applyMsg(Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: id,
        appId: "app",
        title: "Window " & $id))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let activeTag = model.activeTag
    let activeWorkspaceIdx = model.shellSnapshot().activeWorkspaceIdx
    let focusHistory = model.focusHistory
    let workspaceHistory = model.workspaceHistory

    check model.selectedOverviewWindow() == WindowId(5)
    check model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2)).len == 0
    check model.updateModel(Msg(kind: MsgKind.CmdFocusTag,
      focusTag: 2)).len == 0
    check model.updateModel(Msg(kind: MsgKind.CmdFocusOccupiedTagRight)).len == 0
    check model.updateModel(Msg(kind: MsgKind.CmdFocusTagRight)).len == 0

    check model.activeTag == activeTag
    check model.shellSnapshot().activeWorkspaceIdx == activeWorkspaceIdx
    check model.selectedOverviewWindow() == WindowId(5)
    check model.focusHistory == focusHistory
    check model.workspaceHistory == workspaceHistory

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let downEffects = model.updateModel(Msg(
      kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.selectedOverviewWindow() == WindowId(5)
    check model.activeTag == activeTag
    check downEffects.anyIt(it.kind == EffectKind.EffManageDirty)
    check downEffects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Selecting overview window commits focus":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Two"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdSelectWindow))

    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == 2
    check model.activeTag == model.tagForSlot(2)
    check effects.anyIt(it.kind == EffectKind.EffFocusWindow and
      uint32(it.focusId) == 2)

  test "Clicking overview window commits focus":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Two"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged,
      newFocusedId: 2))

    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2
    check effects.anyIt(it.kind == EffectKind.EffFocusWindow and
      uint32(it.focusId) == 2)

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
    check model.viewport(1).targetViewportXOffset !=
      beforeViewport.targetViewportXOffset

  test "Overview select retargets target workspace camera":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Two"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 3,
      appId: "app", title: "Three"))
    model.setViewport(2, targetX = 250.0, currentX = 175.0)
    let workspace2Viewport = model.viewport(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
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

  test "Closing overview restores original camera":
    var model = cameraModel()
    model.seedCameraWindows()
    model.setViewport(1, targetX = 300.0, currentX = 100.0)
    let beforeViewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    discard model.updateModel(Msg(kind: MsgKind.CmdTick))
    model.applyMsg(Msg(kind: MsgKind.CmdCloseOverview))

    check model.viewport(1) == beforeViewport

  test "Workspace round trip preserves each camera":
    var model = cameraModel()
    model.seedCameraWindows(1)
    model.setViewport(1, targetX = 300.0, currentX = 0.0)
    let workspace1Viewport = model.viewport(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Two"))
    model.setViewport(2, targetX = 75.0, currentX = 75.0)
    let workspace2Viewport = model.viewport(2)

    for _ in 0 ..< 4:
      discard model.updateModel(Msg(kind: MsgKind.CmdTick))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))

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

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged,
      newFocusedId: 1))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 1
    check effects.anyIt(it.kind == EffectKind.EffFocusWindow and
      uint32(it.focusId) == 1)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check model.viewport(1).targetViewportXOffset != 0.0'f32

  test "Shell snapshot exposes active workspace focus globally":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "term", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "browser", title: "Two"))

    var snapshot = model.shellSnapshot()
    let focused = snapshot.windows.filterIt(it.isFocused)
    check snapshot.activeWorkspaceIdx == 2
    check focused.len == 1
    check focused[0].id == 2
    check focused[0].workspaceIdx == 2
    check snapshot.workspaces[0].focusedWindow == 1
    check snapshot.workspaces[1].focusedWindow == 2

    let tag2 = model.tagForSlot(2)
    let col2 = model.columnAt(tag2, 0)
    model.placeWindow(tag2, col2, WindowId(1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

    snapshot = model.shellSnapshot()
    let activeFocused = snapshot.windows.filterIt(it.isFocused)
    check activeFocused.len == 1
    check activeFocused[0].id == 1
    check activeFocused[0].workspaceIdx == 2
    check activeFocused[0].tagId.isSome
    check activeFocused[0].tagId.get() == 2
    model.requireTagShellSemantics("active workspace focus scenario")

  test "Workspace focus broadcasts workspace and window snapshots":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "term", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "browser", title: "Two"))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
    check effects.anyIt(it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WorkspacesChanged"))
    check effects.anyIt(it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowsChanged"))
    model.requireTagShellSemantics("workspace focus broadcast scenario")

  test "Empty dynamic workspaces prune after focus leaves":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "term", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))

    var snapshot = model.shellSnapshot()
    check snapshot.activeTag == 4
    check snapshot.workspaces.anyIt(it.tagId == 4)
    model.requireTagShellSemantics("empty dynamic active scenario")

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    snapshot = model.shellSnapshot()
    check snapshot.activeTag == 2
    check not snapshot.workspaces.anyIt(it.tagId == 4)
    model.requireTagShellSemantics("empty dynamic pruned scenario")

  test "Scratchpad restore returns window to active tag":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "term", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToScratchpad))
    model.requireTagShellSemantics("scratchpad hidden scenario")

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdRestoreScratchpad))

    let snapshot = model.shellSnapshot()
    let focused = snapshot.windows.filterIt(it.isFocused)
    check focused.len == 1
    check focused[0].id == 1
    check focused[0].workspaceIdx == 2
    model.requireTagShellSemantics("scratchpad restored scenario")

  test "Overview order deduplicates multi-tag windows":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    let tag2 = model.tagForSlot(2)
    let col2 = model.addColumn(tag2)
    model.placeWindow(tag2, col2, WindowId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewWindowIds() == @[WindowId(1)]
    check model.selectedOverviewWindow() == WindowId(1)

  test "Configured defaults place floating windows":
    var model = configuredModel()
    let (nextModel, _) = model.update(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 130,
      appId: "float-me",
      title: "Tool"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].widthProportion == 0.8'f32
    check snapshot.windows[0].heightProportion == 0.6'f32
    check snapshot.windows[0].isFloating
    check snapshot.workspaces[0].masterCount == 2
    check snapshot.workspaces[0].masterSplitRatio == 0.65'f32
    check snapshot.workspaces[0].columns[0].widthProportion == 0.7'f32

  test "Window rule marks matching windows as shortcut-inhibiting":
    var model = configuredModel()
    let (nextModel, _) = model.update(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 140,
      appId: "qemu-system-x86_64",
      title: "Void"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].keyboardShortcutsInhibit

  test "Live restore parser accepts native schema only":
    let native = parseLiveRestoreJson("""
{
  "schema": "triad-live-restore-v2",
  "active_tag": 2,
  "focused_window": 10,
  "tags": [
    {"id": 2, "layout_mode": "Deck", "columns": [
      {"windows": [10], "width_proportion": 0.6}
    ]}
  ],
  "windows": [{"id": 10, "tag_id": 2, "app_id": "term"}]
}
""")
    check native.isSome
    check native.get().activeTag == 2
    check native.get().tags[2].layoutMode == LayoutMode.Deck
    check native.get().windows[10].appId == "term"

    let invalid = parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""")
    check invalid.isNone

  test "Niri window event includes focused workspace state":
    var model = configuredModel()
    let (_, effects) = model.update(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 120,
      appId: "alacritty",
      title: "Alacritty"))
    let event = effects.filterIt(
      it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))[0]
    let win = parseJson(event.jsonPayload)["WindowOpenedOrChanged"]["window"]

    check win["id"].getInt() == 120
    check win["workspace_id"].getInt() == 1
    check win["is_focused"].getBool()
