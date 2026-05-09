import json, options, sequtils, strutils, tables
import unittest
import ../src/core/msg as core_msg
import ../src/core/model_utils
import ../src/core/niri_state
import ../src/core/shell_state
import ../src/core/triad_state
import ../src/core/update as legacy_update
import ../src/entities/dod_ops
import ../src/state/dod_adapter
import ../src/state/entity_manager
import ../src/state/dod_invariants
import ../src/state/dod_iterators
import ../src/state/dod_queries
import ../src/state/dod_snapshot
import ../src/state/id_gen
import ../src/systems/dod_focus
import ../src/systems/dod_layout
import ../src/systems/dod_outputs
import ../src/systems/dod_placement
import ../src/systems/dod_window_lifecycle
import ../src/systems/dod_window_state
import ../src/systems/dod_workspaces
import ../src/systems/layout_state
import ../src/types/core
import ../src/types/dod_model
from ../src/types/legacy_model import nil

type
  TestEntity = object
    id*: WindowId
    value*: string

proc dodFocusHistory(dod: DodModel): seq[legacy_model.WindowId] =
  for winId in dod.focusHistory:
    let winOpt = dod.windowData(winId)
    if winOpt.isSome:
      result.add(legacy_model.WindowId(uint32(winOpt.get().externalId)))

proc dodWorkspaceHistory(dod: DodModel): seq[uint32] =
  for tagId in dod.workspaceHistory:
    let tagOpt = dod.tagData(tagId)
    if tagOpt.isSome:
      result.add(tagOpt.get().slot)

proc checkDodParity(source: legacy_model.Model): DodModel =
  result = source.dodFromLegacy()
  check result.validateInvariants().ok

  let legacySnapshot = shellSnapshot(source)
  let dodSnapshot = dodShellSnapshot(result)

  check dodSnapshot == legacySnapshot
  check triadStateJson(dodSnapshot) == triadStateJson(legacySnapshot)
  check triadLayoutStateJson(dodSnapshot) ==
    triadLayoutStateJson(legacySnapshot)
  check niriWorkspacesJson(dodSnapshot) == niriWorkspacesJson(legacySnapshot)
  check niriWindowsJson(dodSnapshot) == niriWindowsJson(legacySnapshot)
  check niriOutputsJson(dodSnapshot) == niriOutputsJson(legacySnapshot)
  check niriOverviewJson(dodSnapshot) == niriOverviewJson(legacySnapshot)
  check result.dodFocusHistory() == source.focusHistory
  check result.dodWorkspaceHistory() == source.workspaceHistory

proc checkLayoutParity(source: legacy_model.Model) =
  var legacyModel = source
  var dod = source.dodFromLegacy()

  check dod.validateInvariants().ok
  check legacyModel.layoutInstructions() == dod.dodLayoutInstructions()

  let legacySnapshot = shellSnapshot(legacyModel)
  let dodSnapshot = dodShellSnapshot(dod)
  check dodSnapshot == legacySnapshot

proc checkFocusParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory

proc checkPlacementParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc checkStateParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc baseParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1920,
    screenHeight: 1080,
    overviewActive: true
  )
  result.workspaces.defaultCount = 3
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.Grid, legacy_model.Monocle
  ]
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Grid, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.8))
  result.tags[2].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10,
    appId: "kitty",
    title: "Terminal",
    widthProportion: 0.5,
    heightProportion: 1.0,
    actualW: 900,
    actualH: 1000
  )
  result.windows[20] = legacy_model.WindowData(
    id: 20,
    appId: "brave",
    title: "Browser",
    widthProportion: 0.8,
    heightProportion: 1.0,
    isMaximized: true
  )
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1920, h: 1080)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, x: 1920, y: 0, w: 1920, h: 1080)
  result.primaryOutput = 42
  result.outputTags[43] = 2
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc dynamicParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 9,
    screenWidth: 2560,
    screenHeight: 1440
  )
  result.workspaces.defaultCount = 3
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.MasterStack,
    legacy_model.VerticalGrid
  ]
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[2] = initTagState(2, legacy_model.VerticalScroller, "web")
  result.tags[3] = initTagState(3, legacy_model.Grid, "files")
  result.tags[9] = initTagState(9, legacy_model.Deck, "media")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.7))
  result.tags[2].focusedWindow = 20
  result.tags[9].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(90)], widthProportion: 0.35))
  result.tags[9].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(91)], widthProportion: 0.9))
  result.tags[9].focusedWindow = 91
  result.tags[9].targetViewportXOffset = 128.0'f32
  result.tags[9].currentViewportXOffset = 64.0'f32
  result.tags[9].targetViewportYOffset = 42.0'f32
  result.tags[9].currentViewportYOffset = 21.0'f32
  result.tags[9].masterCount = 2
  result.tags[9].masterSplitRatio = 0.65'f32

  result.windows[20] = legacy_model.WindowData(
    id: 20,
    appId: "brave",
    title: "Docs",
    widthProportion: 0.7,
    heightProportion: 1.0,
    isMinimized: true
  )
  result.windows[90] = legacy_model.WindowData(
    id: 90,
    appId: "mpv",
    title: "Video",
    widthProportion: 0.35,
    heightProportion: 0.8,
    isFullscreen: true,
    fullscreenOutput: 43,
    actualW: 1280,
    actualH: 720
  )
  result.windows[91] = legacy_model.WindowData(
    id: 91,
    appId: "kitty",
    title: "Mixer",
    widthProportion: 0.9,
    heightProportion: 1.0,
    isFloating: true,
    isMaximized: true,
    floatingGeom: legacy_model.Rect(x: 40, y: 50, w: 900, h: 700),
    keyboardShortcutsInhibit: true
  )
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1280, h: 720)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, name: "HDMI-A-1", x: 1280, y: 0, w: 1280, h: 720)
  result.primaryOutput = 42
  result.outputTags[43] = 9
  result.focusHistory = @[legacy_model.WindowId(20), 90, 91]
  result.workspaceHistory = @[1'u32, 2, 9]

proc tiledLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800,
    outerGaps: 20,
    innerGaps: 10
  )
  result.tags[1] = initTagState(1, legacy_model.MasterStack, "main")
  result.tags[1].masterCount = 1
  result.tags[1].masterSplitRatio = 0.6'f32
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "term", title: "term")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "web", title: "web")

proc scrollerLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1000,
    screenHeight: 700,
    outerGaps: 10,
    innerGaps: 8,
    scrollerFocusCenter: true,
    centerFocusedColumn: "always"
  )
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10, heightProportion: 1.0)
  result.windows[20] = legacy_model.WindowData(
    id: 20, heightProportion: 1.0)

proc floatingLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.windows[20].isFloating = true
  result.windows[20].floatingGeom =
    legacy_model.Rect(x: 100, y: 120, w: 500, h: 360)

proc maximizedLayoutModel(): legacy_model.Model =
  result = floatingLayoutModel()
  result.tags[1].focusedWindow = 20
  result.windows[20].isMaximized = true

proc overviewLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.overviewActive = true
  result.overview.outerGap = 18
  result.overview.innerGapMultiplier = 2.0'f32
  result.tags[2] = initTagState(2, legacy_model.Grid, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(30)], widthProportion: 1.0))
  result.windows[30] = legacy_model.WindowData(
    id: 30, appId: "chat", title: "chat")

proc smartGapLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1000,
    screenHeight: 700,
    outerGaps: 30,
    innerGaps: 20,
    smartGaps: true
  )
  result.tags[1] = initTagState(1, legacy_model.Grid, "single")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 1.0))
  result.tags[1].focusedWindow = 10
  result.windows[10] = legacy_model.WindowData(id: 10)

proc usableOutputLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.screenWidth = 3000
  result.screenHeight = 2000
  result.outputs[42] = legacy_model.OutputData(
    id: 42,
    x: 0,
    y: 0,
    w: 2560,
    h: 1440,
    usableX: 10,
    usableY: 20,
    usableW: 1200,
    usableH: 700,
    hasUsable: true)
  result.primaryOutput = 42

proc focusParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[
      legacy_model.WindowId(10),
      legacy_model.WindowId(11)
    ],
    widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(12)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.75))
  result.tags[2].focusedWindow = 20
  result.tags[3] = initTagState(3, legacy_model.Grid, "files")
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "term", title: "one")
  result.windows[11] = legacy_model.WindowData(
    id: 11, appId: "term", title: "two")
  result.windows[12] = legacy_model.WindowData(
    id: 12, appId: "term", title: "three")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "web", title: "browser")
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc minimizedFocusModel(): legacy_model.Model =
  result = focusParityModel()
  result.activeTag = 1
  result.windows[20].isMinimized = true

proc trailingWorkspaceFocusModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 3,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[3] = initTagState(3, legacy_model.Scroller, "files")
  result.tags[3].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(30)], widthProportion: 0.5))
  result.tags[3].focusedWindow = 30
  result.windows[30] = legacy_model.WindowData(
    id: 30, appId: "files", title: "files")
  result.focusHistory = @[legacy_model.WindowId(30)]
  result.workspaceHistory = @[3'u32]

proc closedFocusedWindowModel(): legacy_model.Model =
  result = focusParityModel()
  result.activeTag = 2
  result.tags[2].focusedWindow = 20
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc placementParityModel(): legacy_model.Model =
  result = focusParityModel()
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.MasterStack, legacy_model.Grid
  ]
  result.defaultColumnWidth = 0.7'f32
  result.tags[1].layoutMode = legacy_model.Scroller
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(13)], widthProportion: 0.6))
  result.windows[13] = legacy_model.WindowData(
    id: 13, appId: "term", title: "four")

proc focusWindowInPlacementModel(winId: legacy_model.WindowId):
    legacy_model.Model =
  result = placementParityModel()
  result.tags[1].focusedWindow = winId
  result.focusHistory = @[legacy_model.WindowId(10), 20, winId]

proc activeSecondPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.activeTag = 2
  result.tags[2].focusedWindow = 20
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc masterPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.tags[1].layoutMode = legacy_model.MasterStack
  result.tags[1].masterCount = 1
  result.tags[1].masterSplitRatio = 0.5'f32

proc verticalPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.tags[1].layoutMode = legacy_model.VerticalScroller
  result.windows[10].widthProportion = 0.5'f32

proc stateParityModel(): legacy_model.Model =
  result = placementParityModel()
  result.screenWidth = 1200
  result.screenHeight = 800
  result.floating.xRatio = 0.1'f32
  result.floating.yRatio = 0.2'f32
  result.floating.widthRatio = 0.4'f32
  result.floating.heightRatio = 0.3'f32
  result.floating.minWidth = 80
  result.floating.minHeight = 90
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1200, h: 800)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, name: "HDMI-A-1", x: 1200, y: 0, w: 1000, h: 700)
  result.primaryOutput = 42
  result.outputTags[42] = 1
  result.outputTags[43] = 2
  result.tags[1].focusedWindow = 10

proc fullscreenOutputStateModel(): legacy_model.Model =
  result = stateParityModel()
  result.windows[10].isFullscreen = true
  result.windows[10].fullscreenOutput = 43

proc lifecycleParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.defaultColumnWidth = 0.6'f32
  result.defaultWindowWidth = 0.7'f32
  result.defaultWindowHeight = 0.8'f32
  result.defaultMasterCount = 2
  result.defaultMasterRatio = 0.65'f32
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].masterCount = 2
  result.tags[1].masterSplitRatio = 0.65'f32
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.6))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[2].masterCount = 2
  result.tags[2].masterSplitRatio = 0.65'f32
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.6))
  result.tags[2].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "foot", title: "one")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "brave", title: "web")
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc lifecycleFallbackModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 0,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3

proc lifecycleRuleModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.floating.xRatio = 0.1'f32
  result.floating.yRatio = 0.2'f32
  result.floating.widthRatio = 0.4'f32
  result.floating.heightRatio = 0.3'f32
  result.tagRules.add(legacy_model.TagRule(
    tagId: 4,
    name: "chat",
    defaultLayout: legacy_model.MasterStack
  ))
  result.windowRules.add(legacy_model.WindowRule(
    appIdMatch: "discord",
    defaultTag: 4,
    openFloating: true,
    keyboardShortcutsInhibit: true,
    forcedLayout: ord(legacy_model.Grid) + 1
  ))

proc lifecycleTagRuleModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.tagRules.add(legacy_model.TagRule(
    tagId: 5,
    name: "media",
    defaultLayout: legacy_model.Deck
  ))
  result.windowRules.add(legacy_model.WindowRule(
    appIdMatch: "mpv",
    defaultTag: 5
  ))

proc lifecycleDuplicateModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.activeTag = 1
  result.tags[2].columns[0].windows.add(legacy_model.WindowId(10))
  result.tags[2].focusedWindow = 10

proc lifecycleDynamicDestroyModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.activeTag = 4
  result.tags[4] = initTagState(4, legacy_model.Scroller, "temp")
  result.tags[4].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(40)], widthProportion: 0.6))
  result.tags[4].focusedWindow = 40
  result.windows[40] = legacy_model.WindowData(
    id: 40, appId: "scratch", title: "temp")
  result.focusHistory = @[legacy_model.WindowId(10), 40]

proc lifecycleCollapseDestroyModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 4,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[4] = initTagState(4, legacy_model.Scroller, "temp")
  result.tags[4].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(40)], widthProportion: 0.5))
  result.tags[4].focusedWindow = 40
  result.windows[40] = legacy_model.WindowData(
    id: 40, appId: "scratch", title: "temp")

suite "DOD state primitives":
  test "logical IDs are monotonic and reserve zero":
    var counters = IdCounters()

    let firstWindow = counters.generateWindowId()
    let secondWindow = counters.generateWindowId()
    let firstTag = counters.generateTagId()

    check firstWindow == WindowId(1)
    check secondWindow == WindowId(2)
    check firstTag == TagId(1)
    check firstWindow != NullWindowId
    check firstTag != NullTagId

  test "entity manager adds, updates, and deletes densely":
    var manager: EntityManager[WindowId, TestEntity]

    manager.insert(TestEntity(id: WindowId(1), value: "one"))
    manager.insert(TestEntity(id: WindowId(2), value: "two"))
    manager.insert(TestEntity(id: WindowId(3), value: "three"))

    check manager.len == 3
    check manager.contains(WindowId(2))
    manager.mEntity(WindowId(2)).value = "updated"
    check manager.entity(WindowId(2)).get().value == "updated"

    check manager.delete(WindowId(2))
    check manager.len == 2
    check not manager.contains(WindowId(2))
    check manager.contains(WindowId(3))
    check manager.entity(WindowId(3)).get().value == "three"
    check manager.hasDenseIndex()

  test "entity manager rejects duplicate IDs":
    var manager: EntityManager[WindowId, TestEntity]

    manager.insert(TestEntity(id: WindowId(1), value: "one"))

    expect ValueError:
      manager.insert(TestEntity(id: WindowId(1), value: "dupe"))

  test "tag masks are bounded and composable":
    var mask = EmptyTagMask
    let first = tagBit(1)
    let last = tagBit(MaxTagBits)

    check mask.isEmpty()
    mask.incl(first)
    check mask.contains(first)
    check not mask.contains(last)
    mask.incl(last)
    check mask.contains(last)
    mask.excl(first)
    check not mask.contains(first)
    check mask.contains(last)

    expect ValueError:
      discard tagBit(0)
    expect ValueError:
      discard tagBit(MaxTagBits + 1)

  test "DOD placement supports multi-tag windows and destroy cleanup":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tagOne = model.addTag(1, "one")
    let tagTwo = model.addTag(2, "two")
    let colOne = model.addColumn(tagOne, 0.5)
    let colTwo = model.addColumn(tagTwo, 0.75)
    let win = model.addWindow(
      ExternalWindowId(10), appId = "term", title = "Terminal")

    model.placeWindow(tagOne, colOne, win)
    model.placeWindow(tagTwo, colTwo, win)

    var tagOneWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tagOne):
      tagOneWindows.add(winId)
    var tagTwoWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tagTwo):
      tagTwoWindows.add(winId)
    var colOneWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnColumnWithId(colOne):
      colOneWindows.add(winId)
    var colTwoWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnColumnWithId(colTwo):
      colTwoWindows.add(winId)

    check model.windowTags[win].contains(tagBit(1))
    check model.windowTags[win].contains(tagBit(2))
    check tagOneWindows == @[win]
    check tagTwoWindows == @[win]
    check colOneWindows == @[win]
    check colTwoWindows == @[win]
    check model.placementForWindowOnTag(tagOne, win).get().windowIdx == 1
    check model.firstWindowPosition(win).slot == 1
    check model.validateInvariants().ok

    check model.destroyWindow(win)
    check not model.windows.contains(win)
    check not model.externalWindowIds.hasKey(ExternalWindowId(10))
    check model.tagHasLiveWindows(tagOne) == false
    check model.tagHasLiveWindows(tagTwo) == false
    check model.validateInvariants().ok

  test "DOD iterators skip dangling relationship rows":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tag = model.addTag(1, "one")
    let column = model.addColumn(tag, 0.5)
    let win = model.addWindow(ExternalWindowId(10), appId = "term")

    model.placeWindow(tag, column, win)
    check model.windows.delete(win)

    var yieldedWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tag):
      yieldedWindows.add(winId)

    check yieldedWindows.len == 0

  test "DOD queries sort shell-facing ids by external id":
    var model = DodModel(defaultWorkspaceCount: 3)
    let left = model.addOutput(ExternalOutputId(20), name = "left")
    let right = model.addOutput(ExternalOutputId(10), name = "right")
    let second = model.addWindow(ExternalWindowId(20), appId = "term")
    let first = model.addWindow(ExternalWindowId(10), appId = "browser")

    check model.sortedOutputIdsByExternal() == @[right, left]
    check model.sortedWindowIdsByExternal() == @[first, second]

  test "DOD invariants report broken relationship indexes":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tag = model.addTag(1, "one")
    discard model.addColumn(tag, 0.5)
    model.windowsByTag[tag].add(WindowId(999))

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(it.message.contains("missing window"))

  test "legacy adapter preserves shell snapshots and existing IPC ids":
    let dod = checkDodParity(baseParityModel())
    check uint32(dod.windows.entity(WindowId(1)).get().externalId) == 10
    check uint32(dod.windows.entity(WindowId(2)).get().externalId) == 20

    let dodSnapshot = dodShellSnapshot(dod)
    let windows = triadStateJson(dodSnapshot)["windows"]
    check windows[0]["id"].getInt() == 10
    check windows[1]["id"].getInt() == 20

  test "legacy adapter preserves dynamic workspace and output parity":
    let dod = checkDodParity(dynamicParityModel())
    let snapshot = dodShellSnapshot(dod)
    let workspaces = niriWorkspacesJson(snapshot)
    let windows = niriWindowsJson(snapshot)

    check workspaces.len == 5
    check workspaces[3]["id"].getInt() == 9
    check workspaces[4]["id"].getInt() == 10
    check windows[1]["is_fullscreen"].getBool()
    check windows[2]["is_floating"].getBool()
    check windows[2]["is_maximized"].getBool()

  test "DOD layout projection matches tiled legacy layout":
    checkLayoutParity(tiledLayoutModel())

  test "DOD layout projection matches scroller viewport updates":
    checkLayoutParity(scrollerLayoutModel())

  test "DOD layout projection matches floating windows":
    checkLayoutParity(floatingLayoutModel())

  test "DOD layout projection matches fullscreen and maximized override":
    checkLayoutParity(maximizedLayoutModel())

  test "DOD layout projection matches overview grid":
    checkLayoutParity(overviewLayoutModel())

  test "DOD layout projection matches smart gaps":
    checkLayoutParity(smartGapLayoutModel())

  test "DOD layout projection matches usable output geometry":
    checkLayoutParity(usableOutputLayoutModel())

  test "DOD focus tag matches legacy focus behavior":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusTag, focusTag: 2),
      proc(dod: var DodModel) =
        discard dod.focusWorkspaceSlot(2)
    )

  test "DOD focus workspace index matches trailing workspace behavior":
    checkFocusParity(
      trailingWorkspaceFocusModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusWorkspaceIndex,
        workspaceIndex: 4),
      proc(dod: var DodModel) =
        discard dod.focusWorkspaceIndex(4)
    )

  test "DOD focus external window unminimizes like legacy":
    checkFocusParity(
      minimizedFocusModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusWindowById,
        focusWindowId: 20),
      proc(dod: var DodModel) =
        discard dod.focusExternalWindow(ExternalWindowId(20))
    )

  test "DOD focus cycle matches legacy next and previous":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusNext),
      proc(dod: var DodModel) =
        discard dod.focusCycle(1)
    )
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusPrev),
      proc(dod: var DodModel) =
        discard dod.focusCycle(-1)
    )

  test "DOD directional focus matches legacy columns":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusDirection,
        direction: legacy_model.DirRight),
      proc(dod: var DodModel) =
        discard dod.focusByDirection(legacy_model.DirRight)
    )

  test "DOD overview vertical focus matches legacy workspace navigation":
    checkFocusParity(
      overviewLayoutModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusDirection,
        direction: legacy_model.DirDown),
      proc(dod: var DodModel) =
        discard dod.focusByDirection(legacy_model.DirDown)
    )

  test "DOD focus last matches legacy focus history":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusLast),
      proc(dod: var DodModel) =
        discard dod.focusLast()
    )

  test "DOD focus fallback after close matches legacy history":
    checkFocusParity(
      closedFocusedWindowModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        let winId = dod.windowForExternal(ExternalWindowId(20))
        discard dod.destroyWindow(winId)
        if not dod.focusMostRecentWindow():
          discard dod.focusMostRecentWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )

  test "DOD dynamic workspace pruning matches legacy":
    var legacyState = trailingWorkspaceFocusModel()
    legacyState.tags[4] = initTagState(4, legacy_model.Scroller, "tail")
    legacyState.tags[5] = initTagState(5, legacy_model.Scroller, "stale")
    var dod = legacyState.dodFromLegacy()

    discard legacyState.pruneDynamicWorkspaces()
    discard dod.pruneDynamicWorkspaces()

    check dod.validateInvariants().ok
    check dodShellSnapshot(dod) == shellSnapshot(legacyState)

  test "DOD layout command parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdSetLayout,
        newLayout: legacy_model.Deck,
        layoutTargetTag: 2),
      proc(dod: var DodModel) =
        discard dod.setLayoutForSlot(2, legacy_model.Deck)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSwitchLayout),
      proc(dod: var DodModel) =
        discard dod.switchLayout()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSetMasterCount, count: 3),
      proc(dod: var DodModel) =
        discard dod.setMasterCount(3)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdAdjustMasterCount, deltaMC: 2),
      proc(dod: var DodModel) =
        discard dod.adjustMasterCount(2)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdSetMasterRatio, ratio: 0.7),
      proc(dod: var DodModel) =
        discard dod.setMasterRatio(0.7'f32)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdAdjustMasterRatio, deltaMR: 0.1),
      proc(dod: var DodModel) =
        discard dod.adjustMasterRatio(0.1'f32)
    )

  test "DOD resize command parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdResizeWidth, deltaW: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeWidth(0.1'f32)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdResizeHeight, deltaH: -0.1),
      proc(dod: var DodModel) =
        discard dod.resizeHeight(-0.1'f32)
    )
    checkPlacementParity(
      verticalPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdResizeWidth, deltaW: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeWidth(0.1'f32)
    )
    checkPlacementParity(
      verticalPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdResizeHeight, deltaH: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeHeight(0.1'f32)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSetColumnWidth, targetWidth: 0.8),
      proc(dod: var DodModel) =
        discard dod.setFocusedColumnWidth(0.8'f32)
    )

  test "DOD window movement parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowRight),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowRight()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdMoveWindowLeft),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowLeft()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(11),
      core_msg.Msg(kind: core_msg.CmdMoveWindowUp),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowUp()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowDown),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowDown()
    )

  test "DOD edge window movement parity follows focused window":
    checkPlacementParity(
      activeSecondPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowUpOrToWorkspaceUp),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowUpOrWorkspace()
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(11),
      core_msg.Msg(kind: core_msg.CmdMoveWindowDownOrToWorkspaceDown),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowDownOrWorkspace()
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )

  test "DOD column movement parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveColumnRight),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnRight()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdMoveColumnLeft),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnLeft()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(13),
      core_msg.Msg(kind: core_msg.CmdMoveColumnToFirst),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnToFirst()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveColumnToLast),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnToLast()
    )

  test "DOD consume expel and zoom parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdConsumeWindow),
      proc(dod: var DodModel) =
        discard dod.consumeNextColumnWindow()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdExpelWindow),
      proc(dod: var DodModel) =
        discard dod.expelFocusedWindow()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdZoom),
      proc(dod: var DodModel) =
        discard dod.zoomFocusedWindow()
    )

  test "DOD move and swap tag parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveToTag, targetTag: 2),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowToSlot(2)
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSwapWindowToTag, targetTagSwap: 2),
      proc(dod: var DodModel) =
        discard dod.swapFocusedWindowToSlot(2)
    )

  test "DOD output lifecycle parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputDimensions,
        outputId: 0,
        width: -10,
        height: 900),
      proc(dod: var DodModel) =
        discard dod.setOutputDimensionsForExternal(
          NullExternalOutputId, -10, 900)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputDimensions,
        outputId: 44,
        width: 1600,
        height: 900),
      proc(dod: var DodModel) =
        discard dod.setOutputDimensionsForExternal(
          ExternalOutputId(44), 1600, 900)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputName,
        nameOutputId: 42,
        outputName: " DP-1-fixed "),
      proc(dod: var DodModel) =
        discard dod.setOutputNameForExternal(
          ExternalOutputId(42), " DP-1-fixed ")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputPosition,
        positionOutputId: 42,
        outputX: 10,
        outputY: 20),
      proc(dod: var DodModel) =
        discard dod.setOutputPositionForExternal(
          ExternalOutputId(42), 10, 20)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputUsable,
        usableOutputId: 42,
        usableX: 4,
        usableY: 8,
        usableW: -1,
        usableH: 700),
      proc(dod: var DodModel) =
        discard dod.setOutputUsableForExternal(
          ExternalOutputId(42), 4, 8, -1, 700)
    )
    checkStateParity(
      fullscreenOutputStateModel(),
      core_msg.Msg(kind: core_msg.WlOutputRemoved, removedOutputId: 43),
      proc(dod: var DodModel) =
        discard dod.removeOutputForExternal(ExternalOutputId(43))
    )

  test "DOD window metadata parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDimensions,
        dimensionsWindowId: 10,
        actualWidth: -100,
        actualHeight: 540),
      proc(dod: var DodModel) =
        discard dod.updateWindowDimensionsForExternal(
          ExternalWindowId(10), -100, 540)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDecorationHint,
        decorationWindowId: 10,
        decorationHint: 1),
      proc(dod: var DodModel) =
        discard dod.updateWindowDecorationHintForExternal(
          ExternalWindowId(10), 1)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowPresentationHint,
        presentationWindowId: 10,
        presentationHint: 2),
      proc(dod: var DodModel) =
        discard dod.updateWindowPresentationHintForExternal(
          ExternalWindowId(10), 2)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowParent,
        childWindowId: 10,
        parentWindowId: 20),
      proc(dod: var DodModel) =
        discard dod.updateWindowParentForExternal(
          ExternalWindowId(10), ExternalWindowId(20))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowIdentifier,
        identifierWindowId: 10,
        identifier: "kitty-window-10"),
      proc(dod: var DodModel) =
        discard dod.updateWindowIdentifierForExternal(
          ExternalWindowId(10), "kitty-window-10")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowAppId,
        appIdWindowId: 10,
        updatedAppId: "org.wezfurlong.wezterm"),
      proc(dod: var DodModel) =
        discard dod.updateWindowAppIdForExternal(
          ExternalWindowId(10), "org.wezfurlong.wezterm")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowTitle,
        titleWindowId: 10,
        updatedTitle: "shell"),
      proc(dod: var DodModel) =
        discard dod.updateWindowTitleForExternal(
          ExternalWindowId(10), "shell")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDimensionsHint,
        hintWindowId: 10,
        minWidth: 200,
        minHeight: 100,
        maxWidth: 50,
        maxHeight: 80),
      proc(dod: var DodModel) =
        discard dod.updateWindowDimensionsHintForExternal(
          ExternalWindowId(10), 200, 100, 50, 80)
    )

  test "DOD window state request parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowFullscreenRequested,
        fullscreenRequestId: 10,
        fullscreenOutputId: 43),
      proc(dod: var DodModel) =
        discard dod.requestFullscreenForExternal(
          ExternalWindowId(10), ExternalOutputId(43))
    )
    checkStateParity(
      fullscreenOutputStateModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowExitFullscreenRequested,
        exitFullscreenRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.exitFullscreenForExternal(ExternalWindowId(10))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowMaximizeRequested,
        maximizeRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.requestMaximizeForExternal(ExternalWindowId(10))
    )
    checkStateParity(
      maximizedLayoutModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowUnmaximizeRequested,
        unmaximizeRequestId: 20),
      proc(dod: var DodModel) =
        discard dod.requestUnmaximizeForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowMinimizeRequested,
        minimizeRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.requestMinimizeForExternal(ExternalWindowId(10))
    )

  test "DOD focused window toggles match legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleFloating),
      proc(dod: var DodModel) =
        discard dod.toggleFloatingFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleFullscreen),
      proc(dod: var DodModel) =
        discard dod.toggleFullscreenFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleMaximized),
      proc(dod: var DodModel) =
        discard dod.toggleMaximizedFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdMinimize),
      proc(dod: var DodModel) =
        discard dod.minimizeFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleKeyboardShortcutsInhibit),
      proc(dod: var DodModel) =
        discard dod.toggleKeyboardShortcutsInhibitFocused()
    )

  test "DOD window creation parity matches legacy":
    checkStateParity(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell",
        createdIdentifier: "kitty-30"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "kitty", "shell", "kitty-30")
    )
    checkStateParity(
      lifecycleFallbackModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "kitty", "shell")
    )

  test "DOD window creation applies rules like legacy":
    checkStateParity(
      lifecycleRuleModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "discord",
        title: "Discord"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "discord", "Discord")
    )
    checkStateParity(
      lifecycleTagRuleModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "mpv",
        title: "movie"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "mpv", "movie")
    )

  test "DOD duplicate window creation clears stale placement":
    checkStateParity(
      lifecycleDuplicateModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 10,
        appId: "kitty",
        title: "replacement"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(10), "kitty", "replacement")
    )

  test "DOD window destruction parity matches legacy":
    checkStateParity(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      closedFocusedWindowModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      lifecycleDynamicDestroyModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 40),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(40))
    )
    checkStateParity(
      lifecycleCollapseDestroyModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 40),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(40))
    )
