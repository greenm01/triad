import std/[asyncdispatch, json, options, os, sequtils, strutils, tables,
  unittest]
import ../src/config/parser
import ../src/core/[effects, msg, render_visibility, restore_state]
import ../src/state/engine
import ../src/systems/[hotkey_overlay, layout_projection, runtime_facade,
  update, window_lifecycle]
import ../src/types/model
import ../src/types/runtime_values except WindowId
import ../src/utils/[overview_hit_test, screenshot_capture]
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

proc hasFullscreenEffect(
    effects: seq[Effect]; id: uint32; fullscreen: bool): bool =
  effects.anyIt(it.kind == EffectKind.EffSetFullscreen and
    uint32(it.fsWinId) == id and it.isFullscreen == fullscreen)

proc hasMaximizedEffect(
    effects: seq[Effect]; id: uint32; maximized: bool): bool =
  effects.anyIt(it.kind == EffectKind.EffSetMaximized and
    uint32(it.maxWinId) == id and it.isMaximized == maximized)

proc viewport(model: Model; slot: uint32): ViewportState =
  let tagId = model.tagForSlot(slot)
  let tag = model.tagData(tagId).get()
  ViewportState(
    targetViewportXOffset: tag.targetViewportXOffset,
    currentViewportXOffset: tag.currentViewportXOffset,
    targetViewportYOffset: tag.targetViewportYOffset,
    currentViewportYOffset: tag.currentViewportYOffset)

proc instructionGeom(model: Model; id: uint32): runtime_values.Rect =
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if uint32(instr.windowId) == id:
      return instr.geom
  runtime_values.Rect()

proc snapshotWindow(model: Model; id: uint32): ShellWindow =
  for win in model.shellSnapshot().windows:
    if uint32(win.id) == id:
      return win
  ShellWindow()

proc restoreWindowJson(model: Model; id: uint32): JsonNode =
  let root = parseJson(model.liveRestoreJson())
  for node in root["windows"]:
    if node["id"].getInt() == int(id):
      return node
  newJNull()

proc columnHeads(model: Model; slot: uint32): seq[uint32] =
  let tagId = model.tagForSlot(slot)
  for columnId, _ in model.columnsOnTagWithId(tagId):
    for winId, _ in model.windowsOnColumnWithId(columnId):
      result.add(uint32(model.windowData(winId).get().externalId))
      break

proc setViewport(
    model: var Model; slot: uint32; targetX, currentX: float32;
    targetY = 0.0'f32; currentY = 0.0'f32) =
  let tagId = model.tagForSlot(slot)
  discard model.setTagViewportTarget(tagId, targetX, targetY)
  discard model.setTagViewportCurrent(tagId, currentX, currentY)
  discard model.clearTagViewportRetarget(tagId)

proc seedCameraWindows(model: var Model; count = 3'u32) =
  model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
    width: 1000, height: 700))
  for id in 1'u32 .. count:
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: id,
      appId: "app", title: "Window " & $id))

proc directionalModel(mode: LayoutMode; count = 5'u32): Model =
  result = cameraModel()
  result.seedCameraWindows(count)
  result.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))

proc focusExternal(model: var Model; id: uint32) =
  model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: id))

proc focusDirection(model: var Model; direction: Direction): uint32 =
  model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: direction))
  model.focusedWindowId()

proc restoreMatchingModel(): Model =
  initRuntimeStateFromConfig(Config(
    workspaces: WorkspaceConfig(defaultCount: 3),
    windowRules: @[
      WindowRule(appIdMatch: "generic-app", defaultTag: 2)
    ])).model

proc addRestoredWindow(
    restore: var PendingRestoreState; externalId: ExternalWindowId;
    slot: uint32; appId, title: string; isMaximized = false;
    identifier = "") =
  restore.windows[externalId] = RestoredWindowData(
    slot: slot,
    appId: appId,
    title: title,
    identifier: identifier,
    widthProportion: 0.8,
    heightProportion: 0.6,
    isMaximized: isMaximized)
  restore.tagByWindow[externalId] = slot
  restore.tags[slot] = RestoredTagData(
    slot: slot,
    layoutMode: LayoutMode.Scroller,
    focusedWindow: externalId,
    columns: @[
      RestoredColumnData(
        windows: @[externalId],
        widthProportion: 0.7)
    ],
    masterCount: 1,
    masterSplitRatio: 0.5)

suite "Core Runtime Logic":
  test "Triad reload command emits restart effect":
    var model = Model()
    let (_, effects) = model.update(Msg(kind: MsgKind.CmdTriadReload))
    check effects.len == 1
    check effects[0].kind == EffectKind.EffTriadReload

  test "Session unlock clears stale layer focus and restores active focus":
    var model = configuredModel()
    model.seedCameraWindows(2)
    check model.focusedWindowId() == 2

    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusExclusive))
    discard model.updateModel(Msg(kind: MsgKind.WlSessionLocked))
    check model.sessionLocked
    check model.layerFocusExclusive

    let lockedEffects = model.updateModel(Msg(
      kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))
    check model.focusedWindowId() == 2
    check lockedEffects.len == 0

    let unlockEffects = model.updateModel(Msg(kind: MsgKind.WlSessionUnlocked))
    check not model.sessionLocked
    check not model.layerFocusExclusive
    check model.focusedWindowId() == 2
    check unlockEffects.hasFocusEffect(2)

  test "Screenshot command emits explicit capture effect":
    var model = Model()
    let (_, effects) = model.update(Msg(
      kind: MsgKind.CmdScreenshot,
      screenshotKind: ScreenshotKind.ShotWindow,
      screenshotPath: "/tmp/window.png",
      screenshotPointerMode: ScreenshotPointerMode.PointerShow,
      screenshotWriteToDisk: true,
      screenshotCopyToClipboard: false))

    check effects.len == 1
    check effects[0].kind == EffectKind.EffScreenshot
    check effects[0].screenshotKind == ScreenshotKind.ShotWindow
    check effects[0].screenshotPath == "/tmp/window.png"
    check effects[0].screenshotPointerMode ==
      ScreenshotPointerMode.PointerShow
    check effects[0].screenshotWriteToDisk
    check not effects[0].screenshotCopyToClipboard

  test "Screenshot command builder preserves shell snippets and quotes data":
    let config = ScreenshotConfig(
      captureCommand: "grim -t png",
      regionSelectorCommand: "slurp -d",
      clipboardCommand: "wl-copy --type image/png")
    let screen = runtime_values.Rect(x: 0, y: 0, w: 1920, h: 1080)
    let win = runtime_values.Rect(x: 40, y: 50, w: 800, h: 600)

    check screenshotCaptureCommand(ScreenshotKind.ShotRegion,
      "/tmp/region shot.png", config, screen, win,
      ScreenshotPointerMode.PointerDefault) ==
        "grim -t png -g \"$(slurp -d)\" '/tmp/region shot.png'"
    check screenshotCaptureCommand(ScreenshotKind.ShotScreen,
      "/tmp/screen.png", config, screen, win,
      ScreenshotPointerMode.PointerShow) ==
        "grim -t png -c -g '0,0 1920x1080' '/tmp/screen.png'"
    check screenshotCaptureCommand(ScreenshotKind.ShotWindow,
      "/tmp/window.png", config, screen, win,
      ScreenshotPointerMode.PointerHide) ==
        "grim -t png -g '40,50 800x600' '/tmp/window.png'"
    check screenshotClipboardCommand("/tmp/window.png", config) ==
      "wl-copy --type image/png < '/tmp/window.png'"

  test "Screenshot paths expand home directory absolutely":
    let home = getHomeDir().strip(leading = false, trailing = true,
      chars = {'/'})
    let config = ScreenshotConfig(
      directory: "~/Pictures/Screenshots",
      filenamePrefix: "screenshot")
    let path = screenshotPathOrDefault("", config)

    check expandUserPath("~") == home
    check expandUserPath("~/") == home
    check expandUserPath("~/Pictures/Screenshots") ==
      home / "Pictures" / "Screenshots"
    check expandUserPath("/tmp/shot.png") == "/tmp/shot.png"
    check path.startsWith(home / "Pictures" / "Screenshots" /
      "screenshot-")
    check not path.startsWith("home/")

  test "Async shell command runner yields while process runs":
    var ticked = false

    proc markTick() {.async.} =
      await sleepAsync(20)
      ticked = true

    proc runSlow(): Future[int] {.async.} =
      asyncCheck markTick()
      result = await runShellCommandAsync("sleep 0.1", pollMs = 10)

    check waitFor(runSlow()) == 0
    check ticked
    check waitFor(runShellCommandAsync("exit 7", pollMs = 10)) == 7

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

  test "Hotkey overlay commands update runtime state":
    var model = initRuntimeStateFromConfig(Config(
      hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true),
      workspaces: WorkspaceConfig(defaultCount: 3))).model

    var effects = model.updateModel(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
    check model.hotkeyOverlayOpen
    check model.hotkeyOverlayShownOnce
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
    check model.hotkeyOverlayOpen
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdToggleHotkeyOverlay))
    check not model.hotkeyOverlayOpen
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

    effects = model.updateModel(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
    check not model.hotkeyOverlayOpen
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Hotkey overlay rows honor custom and hidden binding titles":
    var model = initRuntimeStateFromConfig(Config(
      hotkeyOverlay: HotkeyOverlayConfig(hideNotBound: true),
      keyBindings: @[
        KeyBindingConfig(
          key: "Slash",
          modifiers: 65'u32,
          command: "toggle-hotkey-overlay",
          hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleCustom,
          hotkeyOverlayTitle: "Show Important Hotkeys"),
        KeyBindingConfig(
          key: "q",
          modifiers: 64'u32,
          command: "close-window",
          hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleHidden),
        KeyBindingConfig(
          key: "Return",
          modifiers: 64'u32,
          command: "spawn-terminal")
      ])).model
    let rows = model.hotkeyOverlayRows()

    check rows.anyIt(it.key == "Super + Shift + /" and
      it.label == "Show Important Hotkeys")
    check not rows.anyIt(it.label == "Close Focused Window")
    check rows.anyIt(it.key == "Super + Enter" and it.label == "Open Terminal")
    check not rows.anyIt(it.key == "(not bound)")

  test "Grid directional focus follows rendered rows":
    var model = directionalModel(LayoutMode.Grid)

    model.focusExternal(2)
    check model.focusDirection(Direction.DirDown) == 5
    check model.focusDirection(Direction.DirUp) == 2

    model.focusExternal(3)
    check model.focusDirection(Direction.DirDown) == 5

  test "Vertical grid directional focus follows rendered columns":
    var model = directionalModel(LayoutMode.VerticalGrid)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirDown) == 2
    check model.focusDirection(Direction.DirUp) == 1

    model.focusExternal(2)
    check model.focusDirection(Direction.DirRight) == 5
    check model.focusDirection(Direction.DirLeft) == 2

  test "Vertical scroller directional focus follows visual rows":
    var model = directionalModel(LayoutMode.VerticalScroller, 3)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirDown) == 2
    check model.focusDirection(Direction.DirUp) == 1

    let tagId = model.activeTag
    let firstColumn = model.columnAt(tagId, 0)
    let second = model.windowForExternal(ExternalWindowId(2))
    discard model.moveWindowToColumn(tagId, second, firstColumn, 1)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirRight) == 2
    check model.focusDirection(Direction.DirLeft) == 1

  test "Master layouts use visual directional focus":
    var tile = directionalModel(LayoutMode.MasterStack, 3)
    tile.focusExternal(1)
    check tile.focusDirection(Direction.DirRight) == 3
    check tile.focusDirection(Direction.DirUp) == 2

    var vertical = directionalModel(LayoutMode.VerticalTile, 3)
    vertical.focusExternal(1)
    check vertical.focusDirection(Direction.DirDown) == 3

    var rightTile = directionalModel(LayoutMode.RightTile, 3)
    rightTile.focusExternal(1)
    check rightTile.focusDirection(Direction.DirLeft) == 3

    var centerTile = directionalModel(LayoutMode.CenterTile, 5)
    centerTile.focusExternal(1)
    check centerTile.focusDirection(Direction.DirLeft) == 4
    centerTile.focusExternal(1)
    check centerTile.focusDirection(Direction.DirRight) == 5

  test "Overlapping layouts use ordered directional fallback":
    var deck = directionalModel(LayoutMode.Deck, 3)
    deck.focusExternal(2)
    check deck.focusDirection(Direction.DirDown) == 3
    check deck.focusDirection(Direction.DirUp) == 2

    var verticalDeck = directionalModel(LayoutMode.VerticalDeck, 3)
    verticalDeck.focusExternal(2)
    check verticalDeck.focusDirection(Direction.DirRight) == 3
    check verticalDeck.focusDirection(Direction.DirLeft) == 2

    var monocle = directionalModel(LayoutMode.Monocle, 3)
    monocle.focusExternal(1)
    check monocle.focusDirection(Direction.DirRight) == 2
    check monocle.focusDirection(Direction.DirLeft) == 1

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

  test "New active-tag window focuses and retargets camera":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, appId: "app", title: "Two"))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "New active-tag window records focus under layer focus":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusExclusive))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, appId: "app", title: "Two"))
    discard model.updateModel(Msg(kind: MsgKind.WlLayerFocusNone))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32

  test "Deferred admission hides unparented River window until settled":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2,
      appId: "app",
      title: "Two",
      deferAdmission: true))

    let childId = model.windowForExternal(ExternalWindowId(2))
    check model.windowData(childId).get().admissionState ==
      WindowAdmissionState.PendingAdmission
    check model.focusedWindowId() == 1
    check not model.layoutProjection().instructions.mapIt(
      uint32(it.windowId)).contains(2'u32)
    check model.snapshotWindow(2).id == 0'u32

    model.applyMsg(Msg(kind: MsgKind.WlWindowAdmissionSettled,
      admissionWindowId: 2))

    check model.windowData(childId).get().admissionState ==
      WindowAdmissionState.Admitted
    check model.focusedWindowId() == 2
    check model.layoutProjection().instructions.mapIt(
      uint32(it.windowId)).contains(2'u32)

  test "Late parent admits deferred child directly as floating popup":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2,
      appId: "xdg-desktop-portal-gtk",
      title: "Open Document",
      deferAdmission: true))

    check not model.layoutProjection().instructions.mapIt(
      uint32(it.windowId)).contains(2'u32)

    model.applyMsg(Msg(kind: MsgKind.WlWindowParent,
      childWindowId: 2, parentWindowId: 1))

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
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.4,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.6),
      workspaces: WorkspaceConfig(defaultCount: 3))).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "okular", title: "Document"))
    let parentGeom = model.instructionGeom(1)

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2,
      appId: "xdg-desktop-portal-gtk",
      title: "Open Document",
      deferAdmission: true))
    model.applyMsg(Msg(kind: MsgKind.WlWindowParent,
      childWindowId: 2, parentWindowId: 1))

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w
    check childGeom.x == parentGeom.x
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Late parent reclassifies admitted child as floating popup":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2,
      appId: "xdg-desktop-portal-gtk",
      title: "Open Document",
      deferAdmission: true))
    model.applyMsg(Msg(kind: MsgKind.WlWindowAdmissionSettled,
      admissionWindowId: 2))
    check model.layoutProjection().instructions.mapIt(
      uint32(it.windowId)).contains(2'u32)

    model.applyMsg(Msg(kind: MsgKind.WlWindowParent,
      childWindowId: 2, parentWindowId: 1))

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check child.isFloating
    check child.parentExternalId == ExternalWindowId(1)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2

  test "Parented window opens floating over parent without moving camera":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    let parentGeom = model.instructionGeom(1)
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))
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

  test "Auto parented popup fits parent when default floating is wider":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.4,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.6),
      workspaces: WorkspaceConfig(defaultCount: 3))).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "okular", title: "Document"))
    let parentGeom = model.instructionGeom(1)

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "xdg-desktop-portal-gtk", title: "Open Document"))

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w
    check childGeom.x == parentGeom.x
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Late parent event floats child without moving camera":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "pinentry", title: "Passphrase"))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowParent,
      childWindowId: 2, parentWindowId: 1))
    discard model.layoutInstructions()

    let childId = model.windowForExternal(ExternalWindowId(2))
    let child = model.windowData(childId).get()
    check child.parentExternalId == ExternalWindowId(1)
    check child.isFloating
    check model.focusedWindowId() == 2
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check not model.viewportRetargetRequested(model.activeTag)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffBroadcastTriadJson and
      it.triadEventName == "layout")

  test "Parented inactive-workspace window stays on parent workspace silently":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))
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
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))

    let beforeChildGeom = model.instructionGeom(2)
    let parentId = model.windowForExternal(ExternalWindowId(1))
    discard model.setWindowFloating(
      parentId, true, runtime_values.Rect(x: 300, y: 100, w: 400, h: 300))

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2
    check childGeom != beforeChildGeom

  test "Parented floating window follows scroller camera":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))
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
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))
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
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    check not model.layoutProjection().instructions.mapIt(
      uint32(it.windowId)).contains(4'u32)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
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
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))

    let parentGeom = model.instructionGeom(2)
    let childGeom = model.instructionGeom(4)
    check model.focusedWindowId() == 4
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2

  test "Parented popup tree remains while focus is on nested child":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 5, createdParentWindowId: 2,
      appId: "pinentry", title: "Second"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 6, createdParentWindowId: 4,
      appId: "pinentry", title: "Nested"))

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check model.focusedWindowId() == 6
    check order.contains(4'u32)
    check order.contains(5'u32)
    check order.contains(6'u32)

  test "Parented popup root restores explicitly focused parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 5, createdParentWindowId: 2,
      appId: "pinentry", title: "Second"))

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    check model.focusedWindowId() == 2
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))

    check model.focusedWindowId() == 2

  test "Parented popup root restores last explicitly focused child":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 5, createdParentWindowId: 2,
      appId: "pinentry", title: "Second"))

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))

    check model.focusedWindowId() == 4

  test "Closing focused popup falls back within popup tree":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.setViewport(1, targetX = 400.0, currentX = 400.0)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 5, createdParentWindowId: 2,
      appId: "pinentry", title: "Second"))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed,
      destroyedId: 4))

    check model.focusedWindowId() == 5

  test "Closing last focused popup falls back to parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed,
      destroyedId: 4))

    check model.focusedWindowId() == 2

  test "Focused popup retargets scroller camera to parent":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    discard model.layoutInstructions()
    let parentTarget = model.viewport(1).targetViewportXOffset
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 4))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 4
    check model.viewport(1).targetViewportXOffset == parentTarget

  test "Parented floating window hides with obscured maximized parent":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 3, createdParentWindowId: 2,
      appId: "pinentry", title: "Passphrase"))

    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))
    discard model.updateModel(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 1))

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.contains(1'u32)
    check not order.contains(2'u32)
    check not order.contains(3'u32)

  test "Manual parented popup wider than parent stays centered and clamped":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Wide dialog"))
    let parentId = model.windowForExternal(ExternalWindowId(1))
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard model.setWindowFloating(
      parentId, true, runtime_values.Rect(x: 300, y: 100, w: 400, h: 300))
    discard model.setWindowFloating(
      childId, true, runtime_values.Rect(x: 0, y: 0, w: 800, h: 500))

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(2)
    check childGeom.w == 800
    check childGeom.h == 500
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2
    check childGeom.x <= parentGeom.x + parentGeom.w
    check childGeom.x + childGeom.w >= parentGeom.x

  test "Size-forced parented popup can overhang parent":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Wide dialog"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 2,
      minWidth: parentGeom.w + 120,
      minHeight: 140,
      maxWidth: 0,
      maxHeight: 0))

    let childGeom = model.instructionGeom(2)
    check childGeom.w == parentGeom.w + 120
    check childGeom.x == 0
    check childGeom.x <= parentGeom.x + parentGeom.w
    check childGeom.x + childGeom.w >= parentGeom.x

  test "Manual parented popup resize disables parent auto fit":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Dialog"))

    let childId = model.windowForExternal(ExternalWindowId(2))
    check model.windowData(childId).get().parentAutoFloating
    model.applyMsg(Msg(kind: MsgKind.CmdResizeFloating,
      deltaFW: 120, deltaFH: 0))

    let parentId = model.windowForExternal(ExternalWindowId(1))
    discard model.setWindowFloating(
      parentId, true, runtime_values.Rect(x: 300, y: 100, w: 400, h: 300))

    let child = model.windowData(childId).get()
    let childGeom = model.instructionGeom(2)
    check not child.parentAutoFloating
    check childGeom.w == child.floatingGeom.w
    check childGeom.w > model.instructionGeom(1).w

  test "Parented popup larger than screen shrinks to screen":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Oversized dialog"))
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard model.setWindowFloating(
      childId, true, runtime_values.Rect(x: 0, y: 0, w: 1400, h: 900))

    let childGeom = model.instructionGeom(2)
    check childGeom == model.primaryScreen()

  test "Parented popup hides when parent leaves camera":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))

    model.setViewport(1, targetX = 900.0, currentX = 900.0)

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.contains(1'u32)
    check not order.contains(4'u32)

  test "Parented popup hides until partly visible parent is fully visible":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 1,
      appId: "pinentry", title: "Wide dialog"))
    let childId = model.windowForExternal(ExternalWindowId(4))
    discard model.setWindowFloating(
      childId, true, runtime_values.Rect(x: 0, y: 0, w: 800, h: 500))

    model.setViewport(1, targetX = 350.0, currentX = 350.0)

    let parentGeom = model.instructionGeom(1)
    let childGeom = model.instructionGeom(4)
    check parentGeom.x < 0
    check parentGeom.x + parentGeom.w > 0
    check childGeom.w == 0

    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let visibleParentGeom = model.instructionGeom(1)
    let visibleChildGeom = model.instructionGeom(4)
    check visibleParentGeom.x >= 0
    check visibleChildGeom.w == 800
    check visibleChildGeom.x == 0
    check visibleChildGeom.x <= visibleParentGeom.x + visibleParentGeom.w

  test "Parented floating stack keeps children and newer siblings above":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 3, createdParentWindowId: 1,
      appId: "pinentry", title: "Second"))

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.find(1'u32) < order.find(2'u32)
    check order.find(2'u32) < order.find(3'u32)

  test "Focused popup rises above newer sibling in stack history":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "First"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 3, createdParentWindowId: 1,
      appId: "pinentry", title: "Second"))

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))

    let order = model.layoutProjection().instructions.mapIt(uint32(it.windowId))
    check order.find(3'u32) < order.find(2'u32)

  test "Large parented primary surface tiles after size hint":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "editor", title: "Detached"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 2,
      minWidth: int32(float32(parentGeom.w) * 0.95'f32),
      minHeight: int32(float32(parentGeom.h) * 0.95'f32),
      maxWidth: 0,
      maxHeight: 0))

    let child = model.snapshotWindow(2)
    check not child.isFloating
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    check model.focusedWindowId() == 1

  test "Manual tiled parented child is not refloated by later hints":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))
    let childId = model.windowForExternal(ExternalWindowId(2))
    discard model.setWindowFloating(childId, false)

    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 2, minWidth: 260, minHeight: 140,
      maxWidth: 260, maxHeight: 140))

    check not model.snapshotWindow(2).isFloating

  test "Offscreen parented popup defers focus until parent is visible":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "pinentry", title: "Passphrase"))
    discard model.layoutInstructions()

    check not effects.hasFocusEffect(4)
    check model.focusedWindowId() == 1
    check model.viewport(1).targetViewportXOffset == 0.0'f32
    check model.pendingDialogFocusWindows.len == 1
    check model.instructionGeom(4).w == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    discard model.layoutInstructions()
    let parentViewport = model.viewport(1)
    model.setViewport(
      1,
      targetX = parentViewport.targetViewportXOffset,
      currentX = parentViewport.targetViewportXOffset)
    let flushEffects = model.updateModel(Msg(kind: MsgKind.CmdTick))

    check flushEffects.hasFocusEffect(4)
    check model.focusedWindowId() == 4
    check model.pendingDialogFocusWindows.len == 0

  test "Parented popup viewport jump rule focuses and snaps":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "keepassxc", dialogViewportJump: true)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Window 1"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Window 2"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 3,
      appId: "keepassxc", title: "KeePassXC"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "pinentry", title: "Passphrase"))
    discard model.layoutInstructions()

    check effects.hasFocusEffect(4)
    check model.focusedWindowId() == 4
    check model.pendingDialogFocusWindows.len == 0
    check model.viewport(1).targetViewportXOffset > 0.0'f32
    check model.viewport(1).currentViewportXOffset ==
      model.viewport(1).targetViewportXOffset

  test "Parented popup open-focused false suppresses viewport jump":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "keepassxc", dialogViewportJump: true),
        WindowRule(appIdMatch: "pinentry", openFocusedSet: true,
          openFocused: false)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Window 1"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "app", title: "Window 2"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 3,
      appId: "keepassxc", title: "KeePassXC"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "pinentry", title: "Passphrase"))
    discard model.layoutInstructions()

    check not effects.hasFocusEffect(4)
    check model.focusedWindowId() == 1
    check model.pendingDialogFocusWindows.len == 0
    check model.viewport(1).targetViewportXOffset == 0.0'f32

  test "Queued parented popup is cleared when parent closes":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "pinentry", title: "Passphrase"))

    check model.pendingDialogFocusWindows.len == 1

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 3))

    check model.pendingDialogFocusWindows.len == 0

  test "Deck popup from background parent defers focus":
    var model = directionalModel(LayoutMode.Deck, 3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let beforeParentGeom = model.instructionGeom(3)

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "pinentry", title: "Passphrase"))

    let parentGeom = model.instructionGeom(3)
    let childGeom = model.instructionGeom(4)
    check parentGeom == beforeParentGeom
    check childGeom.w == 0
    check model.focusedWindowId() == 1
    check model.pendingDialogFocusWindows.len == 1

  test "TGMix popup anchors in tile-sized parent zone":
    var model = directionalModel(LayoutMode.TGMix, 3)
    let parentGeom = model.instructionGeom(1)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))

    let childGeom = model.instructionGeom(4)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "TGMix popup anchors in grid-sized parent zone":
    var model = directionalModel(LayoutMode.TGMix, 4)
    let parentGeom = model.instructionGeom(4)
    model.focusExternal(4)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 5, createdParentWindowId: 4,
      appId: "pinentry", title: "Passphrase"))

    let childGeom = model.instructionGeom(5)
    check childGeom.w > 0
    check childGeom.x == parentGeom.x + (parentGeom.w - childGeom.w) div 2
    check childGeom.y == parentGeom.y + (parentGeom.h - childGeom.h) div 2

  test "Parented window rules can suppress focus and floating":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(
          appIdMatch: "pinentry",
          openFloatingSet: true,
          openFloating: false,
          openFocusedSet: true,
          openFocused: false)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))
    let child = model.snapshotWindow(2)

    check not child.isFloating
    check model.focusedWindowId() == 1
    check not effects.hasFocusEffect(2)

  test "Explicit default-tag can override parent workspace":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(gaps: 10, defaultColumnWidth: 0.7),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "pinentry", defaultTag: 2)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))

    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))
    let child = model.snapshotWindow(2)

    check child.tagId.isSome and child.tagId.get() == 2
    check child.workspaceIdx == 2

    model.applyMsg(Msg(kind: MsgKind.WlWindowParent,
      childWindowId: 2, parentWindowId: 1))
    let afterParentEvent = model.snapshotWindow(2)
    check afterParentEvent.tagId.isSome and afterParentEvent.tagId.get() == 2
    check afterParentEvent.workspaceIdx == 2

  test "Fixed-size hint opens normal window as floating":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "dialog", title: "Tool"))

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 1, minWidth: 260, minHeight: 140,
      maxWidth: 260, maxHeight: 140))
    discard model.layoutInstructions()

    let winId = model.windowForExternal(ExternalWindowId(1))
    let win = model.windowData(winId).get()
    check win.isFloating
    check win.floatingGeom.w == 260
    check win.floatingGeom.h == 140
    check not model.viewportRetargetRequested(model.activeTag)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffBroadcastTriadJson and
      it.triadEventName == "layout")

  test "New active-tag window focuses after live restore settles":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    var restore = PendingRestoreState(
      activeSlot: 1,
      focusedWindow: ExternalWindowId(1),
      focusHistory: @[ExternalWindowId(1)])
    restore.windows[ExternalWindowId(1)] = RestoredWindowData(
      slot: 1,
      appId: "app",
      title: "One",
      widthProportion: 0.5,
      heightProportion: 1.0)
    restore.tagByWindow[ExternalWindowId(1)] = 1
    model.applyLiveRestore(restore)
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    check not model.restoreFocusedWindowPending()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, appId: "app", title: "Two"))
    discard model.layoutInstructions()

    check model.focusedWindowId() == 2
    check model.activeWorkspaceFocusId() == 2
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(2)

  test "New scroller window opens beside focused window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
    model.setViewport(1, targetX = 0.0, currentX = 0.0)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, appId: "app", title: "Window 4"))
    discard model.layoutInstructions()

    check model.columnHeads(1) == @[1'u32, 2, 4, 3]
    check model.focusedWindowId() == 4
    check model.viewport(1).targetViewportXOffset != 0.0'f32
    check effects.hasFocusEffect(4)

  test "Live restore JSON records moved maximized window":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10,
      appId: "generic-app", title: "Window"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 10))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 1))

    let win = model.restoreWindowJson(10)

    check win.kind == JObject
    check win["tag_id"].getInt() == 1
    check win["is_maximized"].getBool()

  test "Moving focused window follows target and refocuses source":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    model.seedCameraWindows(3)
    let outputId = model.outputForExternal(ExternalOutputId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

    check model.activeWorkspaceFocusId() == 3
    check model.focusedWindowId() == 3
    check model.outputTags[outputId] == model.tagForSlot(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2
    check model.outputTags[outputId] == model.tagForSlot(1)

  test "Moving focused window to another workspace reasserts focus":
    var model = cameraModel()
    model.seedCameraWindows(1)

    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

    check model.activeTag == model.tagForSlot(2)
    check model.snapshotWindow(1).workspaceIdx == 2
    check model.focusedWindowId() == 1
    check effects.hasFocusEffect(1)

  test "Focusing workspace updates primary output tag":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    let outputId = model.outputForExternal(ExternalOutputId(1))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))

    check outputId != NullOutputId
    check model.activeTag == model.tagForSlot(2)
    check model.outputTags[outputId] == model.activeTag

  test "Moving only source window follows target and leaves source empty":
    var model = cameraModel()
    model.seedCameraWindows(1)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

    check model.activeWorkspaceFocusId() == 1
    check model.focusedWindowId() == 1

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 0
    check model.focusedWindowId() == 0

  test "Adjacent tag move follows target":
    var model = cameraModel()
    model.seedCameraWindows(2)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToTagRight))

    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
    check model.activeWorkspaceFocusId() == 1
    check model.focusedWindowId() == 1

  test "Moving window preserves target column width":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let sourceTag = model.tagForSlot(1)
    let sourceColumn = model.columnAt(sourceTag, 0)
    discard model.setColumnWidth(sourceColumn, 0.42'f32)

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

    let targetTag = model.tagForSlot(2)
    let targetColumn = model.columnAt(targetTag, 0)
    check model.columnData(targetColumn).get().widthProportion == 0.42'f32

  test "Moving normal window to empty grid workspace preserves source layout":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(defaultColumnWidth: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      tagRules: @[
        TagRule(tagId: 2, defaultLayout: LayoutMode.Scroller),
        TagRule(tagId: 3, defaultLayout: LayoutMode.Grid)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 6,
      appId: "sublime_text", title: "Sublime Text"))

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 3))
    let targetTag = model.tagForSlot(3)
    let screen = model.primaryScreen()
    let geom = model.instructionGeom(6)

    check model.tagData(targetTag).get().layoutMode == LayoutMode.Scroller
    check not model.snapshotWindow(6).isMaximized
    check geom.w < screen.w

  test "Moving to occupied grid workspace keeps target layout":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(defaultColumnWidth: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      tagRules: @[
        TagRule(tagId: 2, defaultLayout: LayoutMode.Scroller),
        TagRule(tagId: 3, defaultLayout: LayoutMode.Grid)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 3,
      appId: "files", title: "Files"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 6,
      appId: "sublime_text", title: "Sublime Text"))

    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 3))

    check model.tagData(model.tagForSlot(3)).get().layoutMode ==
      LayoutMode.Grid

  test "Moving fullscreen window through dynamic workspace preserves state":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 1, fullscreenOutputId: 1))

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
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToTagRight))

    let tgmixEffects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.TGMix))
    check model.activeTag == model.tagForSlot(4)
    check model.tagData(model.activeTag).get().layoutMode == LayoutMode.TGMix
    check model.snapshotWindow(1).isMaximized
    check tgmixEffects.hasMaximizedEffect(1, false)
    check tgmixEffects.hasFocusEffect(1)

    let scrollerEffects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Scroller))
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

  test "Column resize clears maximize column state":
    var model = cameraModel()
    model.seedCameraWindows(1)
    let tagId = model.activeTag
    let columnId = model.columnAt(tagId, 0)

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    check model.columnData(columnId).get().isFullWidth

    discard model.updateModel(Msg(kind: MsgKind.CmdSetColumnWidth,
      targetWidth: 0.5'f32))
    check not model.columnData(columnId).get().isFullWidth
    check model.columnData(columnId).get().widthProportion == 0.5'f32

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard model.updateModel(Msg(kind: MsgKind.CmdResizeWidth,
      deltaW: 0.1'f32))
    check not model.columnData(columnId).get().isFullWidth

  test "Moving full-width column preserves column presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)

    discard model.updateModel(Msg(kind: MsgKind.CmdMaximizeColumn))
    discard model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

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
    discard model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Grid))

    let win = model.snapshotWindow(1)
    check model.activeTag == model.tagForSlot(4)
    check win.workspaceIdx == 4
    check win.isFloating
    check win.floatingGeom == before

  test "Moving editor from grid to scroller preserves runtime attributes":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "kitty", title: "Terminal"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 6,
      appId: "sublime_text", title: "Sublime Text"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensions,
      dimensionsWindowId: 6, actualWidth: 900, actualHeight: 600))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 6, minWidth: 300, minHeight: 200,
      maxWidth: 1600, maxHeight: 1200))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDecorationHint,
      decorationWindowId: 6, decorationHint: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowPresentationHint,
      presentationWindowId: 6, presentationHint: 3))
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 6))

    let before = model.windowData(
      model.windowForExternal(ExternalWindowId(6))).get()
    let effects = model.updateModel(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))
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
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 1,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Grid))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 6,
      appId: "sublime_text", title: "Sublime Text"))
    discard model.updateModel(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 6))

    let toGridEffects = model.updateModel(Msg(
      kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 3))
    check model.activeTag == model.tagForSlot(3)
    check model.tagData(model.activeTag).get().layoutMode ==
      LayoutMode.Scroller
    check model.snapshotWindow(6).isMaximized
    check not toGridEffects.hasMaximizedEffect(6, false)

    let toScrollerEffects = model.updateModel(Msg(
      kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))
    check model.activeTag == model.tagForSlot(2)
    check model.snapshotWindow(6).isMaximized
    check toScrollerEffects.hasMaximizedEffect(6, true)
    check toScrollerEffects.hasFocusEffect(6)

  test "Targeted layout ignores missing empty dynamic workspace":
    var model = cameraModel()
    model.seedCameraWindows(1)

    let (nextModel, effects) =
      model.update(Msg(kind: MsgKind.CmdSetLayout,
        newLayout: LayoutMode.Deck,
        layoutTargetTag: 4))

    check nextModel.tagForSlot(4) == NullTagId
    check not effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Duplicate window create preserves moved window attributes":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10,
      appId: "kitty", title: "Terminal"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensions,
      dimensionsWindowId: 10, actualWidth: 640, actualHeight: 480))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: 10, minWidth: 200, minHeight: 100,
      maxWidth: 1200, maxHeight: 900))
    model.applyMsg(Msg(kind: MsgKind.WlWindowDecorationHint,
      decorationWindowId: 10, decorationHint: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowPresentationHint,
      presentationWindowId: 10, presentationHint: 3))
    model.applyMsg(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 10))
    model.applyMsg(Msg(kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 10, fullscreenOutputId: 0))
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex,
      workspaceIndex: 2))

    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10,
      appId: "kitty", title: "Terminal renamed"))

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

  test "Live restore preserves popup parent relationship":
    var model = cameraModel()
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, createdParentWindowId: 1,
      appId: "pinentry", title: "Passphrase"))

    let win = model.restoreWindowJson(2)
    let restore = parseLiveRestoreJson(model.liveRestoreJson()).get()

    var restoredModel = cameraModel()
    restoredModel.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    restoredModel.applyLiveRestore(restore.pendingRestoreState())
    restoredModel.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "Parent"))
    restoredModel.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "pinentry", title: "Passphrase"))

    check win["parent_id"].getInt() == 1
    check restoredModel.snapshotWindow(2).parentId == 1
    check restoredModel.instructionGeom(2).w > 0

  test "Live restore matches unique app id after title changes":
    var model = restoreMatchingModel()
    var restore = PendingRestoreState(
      activeSlot: 1,
      focusedWindow: ExternalWindowId(50))
    restore.addRestoredWindow(
      ExternalWindowId(50),
      1,
      "generic-app",
      "Old title",
      isMaximized = true)
    model.applyLiveRestore(restore)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 70, appId: "generic-app", title: "New title"))
    let win = model.snapshotWindow(70)

    check win.id == 70
    check win.workspaceIdx == 1
    check win.isMaximized
    check effects.hasMaximizedEffect(70, true)

  test "Live restore does not guess between duplicate app ids":
    var model = restoreMatchingModel()
    var restore = PendingRestoreState(activeSlot: 1)
    restore.addRestoredWindow(
      ExternalWindowId(50),
      1,
      "generic-app",
      "Old title A",
      isMaximized = true)
    restore.addRestoredWindow(
      ExternalWindowId(51),
      3,
      "generic-app",
      "Old title B",
      isMaximized = true)
    model.applyLiveRestore(restore)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 70, appId: "generic-app", title: "New title"))
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
      identifier = "stable-target")
    restore.addRestoredWindow(
      ExternalWindowId(51),
      3,
      "generic-app",
      "Old title B",
      identifier = "stable-other")
    model.applyLiveRestore(restore)

    discard model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 70, appId: "generic-app", title: "New title"))
    check model.snapshotWindow(70).workspaceIdx == 2

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowIdentifier,
      identifierWindowId: 70, identifier: "stable-target"))
    let win = model.snapshotWindow(70)

    check win.workspaceIdx == 1
    check win.isMaximized
    check effects.hasMaximizedEffect(70, true)

  test "Rule-placed new window does not steal active camera":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "chat", defaultTag: 2)
      ])).model
    model.applyMsg(Msg(kind: MsgKind.WlOutputDimensions, outputId: 0,
      width: 1000, height: 700))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "app", title: "One"))
    discard model.layoutInstructions()
    model.setViewport(1, targetX = 0.0, currentX = 0.0)
    let beforeViewport = model.viewport(1)

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 2, appId: "chat", title: "Chat"))
    discard model.layoutInstructions()
    let snapshot = model.shellSnapshot()

    check snapshot.activeTag == 1
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check snapshot.workspaces[1].focusedWindow == 2
    check model.viewport(1) == beforeViewport
    check not effects.hasFocusEffect(2)

  test "Fullscreen presentation follows active focus":
    var model = cameraModel()
    model.seedCameraWindows(2)

    let fullscreenEffects = model.updateModel(Msg(
      kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 2,
      fullscreenOutputId: 0))
    check fullscreenEffects.hasFullscreenEffect(2, true)

    let leaveEffects = model.updateModel(Msg(
      kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))
    check leaveEffects.hasFullscreenEffect(2, false)

    let returnEffects = model.updateModel(Msg(
      kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
    check returnEffects.hasFullscreenEffect(2, true)

  test "Grid suspends maximized presentation without clearing state":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 2))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Grid))
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
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 2))
    discard model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Grid))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
      newLayout: LayoutMode.Scroller))
    let screen = model.primaryScreen()

    check model.snapshotWindow(2).isMaximized
    check effects.hasMaximizedEffect(2, true)
    check model.instructionGeom(2) == screen

  test "Non-scroller layouts do not present maximized windows":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 2))

    for mode in [LayoutMode.MasterStack, LayoutMode.Deck,
        LayoutMode.Monocle]:
      let effects = model.updateModel(Msg(kind: MsgKind.CmdSetLayout,
        newLayout: mode))
      check model.snapshotWindow(2).isMaximized
      check effects.hasMaximizedEffect(2, false)
      check model.instructionGeom(2) != model.primaryScreen()

  test "Minimize preserves desired maximized state":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 2))

    let minimizeEffects = model.updateModel(Msg(kind: MsgKind.CmdMinimize))
    let minimized = model.snapshotWindow(2)

    check minimized.isMaximized
    check minimized.isMinimized
    check minimizeEffects.hasMaximizedEffect(2, false)

    let restoreEffects = model.updateModel(Msg(
      kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
    let restored = model.snapshotWindow(2)

    check restored.isMaximized
    check not restored.isMinimized
    check restoreEffects.hasMaximizedEffect(2, true)

  test "Floating popup preserves maximized backing windows":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "pinentry", openFloating: true)
      ])).model
    model.seedCameraWindows(2)

    let firstMaxEffects = model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
    let secondMaxEffects = model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 2))

    check model.snapshotWindow(1).isMaximized
    check firstMaxEffects.hasMaximizedEffect(1, false)
    check secondMaxEffects.hasMaximizedEffect(2, true)

    let popupEffects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 3, appId: "pinentry", title: "Password"))
    let screen = model.primaryScreen()

    check not popupEffects.hasMaximizedEffect(1, false)
    check not popupEffects.hasMaximizedEffect(2, false)
    check popupEffects.hasMaximizedEffect(1, true)
    check model.instructionGeom(1) == screen
    check model.instructionGeom(2) == screen
    check model.instructionGeom(3).w > 0
    check model.focusedWindowId() == 3

  test "Parented popup ignores unrelated maximized backing window":
    var model = cameraModel()
    model.seedCameraWindows(3)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 3))

    let popupEffects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "xdg-desktop-portal-gtk", title: "Open Document"))
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
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 3))
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 3))

    let popupEffects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 4, createdParentWindowId: 3,
      appId: "xdg-desktop-portal-gtk", title: "Open Document"))
    let screen = model.primaryScreen()
    let popupGeom = model.instructionGeom(4)

    check popupEffects.hasMaximizedEffect(1, false)
    check not popupEffects.hasMaximizedEffect(3, false)
    check model.instructionGeom(1) != screen
    check model.instructionGeom(3) == screen
    check popupGeom.w > 0
    check model.focusedWindowId() == 4

  test "Floating popup preserves fullscreen presentation":
    var model = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        defaultColumnWidth: 0.7,
        centerFocusedColumn: "always",
        enableAnimations: true,
        animationSpeed: 0.5),
      workspaces: WorkspaceConfig(defaultCount: 3),
      windowRules: @[
        WindowRule(appIdMatch: "pinentry", openFloating: true)
      ])).model
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 2,
      fullscreenOutputId: 0))

    let popupEffects = model.updateModel(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 3, appId: "pinentry", title: "Password"))
    let screen = model.primaryScreen()

    check not popupEffects.hasFullscreenEffect(2, false)
    check model.instructionGeom(2) == screen
    check model.instructionGeom(3).w > 0
    check model.focusedWindowId() == 3

  test "Overview suspends fullscreen presentation":
    var model = cameraModel()
    model.seedCameraWindows(1)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 1,
      fullscreenOutputId: 0))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check effects.hasFullscreenEffect(1, false)

  test "Targeted fullscreen IPC can repair a non-focused window":
    var model = cameraModel()
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(
      kind: MsgKind.WlWindowFullscreenRequested,
      fullscreenRequestId: 2,
      fullscreenOutputId: 0))
    discard model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 1))

    let effects = model.updateModel(Msg(
      kind: MsgKind.CmdExitFullscreenById,
      fullscreenWindowId: 2))
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

  test "Overview hit testing uses topmost preview under pointer":
    let instructions = @[
      RenderInstruction(
        windowId: 1,
        geom: runtime_values.Rect(x: 0, y: 0, w: 100, h: 100)),
      RenderInstruction(
        windowId: 2,
        geom: runtime_values.Rect(x: 50, y: 50, w: 100, h: 100)),
      RenderInstruction(
        windowId: 3,
        geom: runtime_values.Rect(x: 200, y: 50, w: 100, h: 100))
    ]

    check overviewHitTest(instructions, 10, 10) == 1
    check overviewHitTest(instructions, 60, 60) == 2
    check overviewHitTest(instructions, 220, 70) == 3
    check overviewHitTest(instructions, 400, 400) == 0

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

  test "Closing transient window keeps focus on active workspace":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "brave", title: "Browser"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "thunar", title: "Pictures"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 3,
      appId: "kitty", title: "Terminal A"))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 4,
      appId: "kitty", title: "Terminal B"))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById,
      focusWindowId: 2))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 5,
      appId: "image-viewer", title: "Screenshot"))

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed,
      destroyedId: 5))

    check model.shellSnapshot().activeTag == 1
    check model.activeWorkspaceFocusId() == 2
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)
    check not effects.hasFocusEffect(3)
    check not effects.hasFocusEffect(4)
    model.requireTagShellSemantics("transient close local focus scenario")

  test "Closing last dynamic workspace window still collapses workspace":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 1,
      appId: "term", title: "One"))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 2,
      appId: "term", title: "Dynamic"))

    let effects = model.updateModel(Msg(kind: MsgKind.WlWindowDestroyed,
      destroyedId: 2))
    let snapshot = model.shellSnapshot()

    check snapshot.activeTag == 3
    check not snapshot.workspaces.anyIt(it.tagId == 4)
    check not effects.hasFocusEffect(1)
    model.requireTagShellSemantics("dynamic close collapse scenario")

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
      {"windows": [10], "width_proportion": 0.6, "is_full_width": true}
    ]}
  ],
  "windows": [{"id": 10, "tag_id": 2, "app_id": "term"}]
}
""")
    check native.isSome
    check native.get().activeTag == 2
    check native.get().tags[2].layoutMode == LayoutMode.Deck
    check native.get().tags[2].columns[0].isFullWidth
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
