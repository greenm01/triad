import unittest, tables, os, sequtils
import ../src/core/model
import ../src/core/model_utils
import ../src/core/msg
import ../src/core/update
import ../src/layouts/scroller
import ../src/layouts/tiling
import ../src/config/parser

proc baseModel(): Model =
  result = Model(activeTag: 1, screenWidth: 1920, screenHeight: 1080, outerGaps: 10, innerGaps: 5)
  result.tags[1] = initTagState(1)

suite "Crash hardening":
  test "duplicate window create keeps a single placement":
    var model = baseModel()
    model.tags[1].columns.add(Column(windows: @[WindowId(10)], widthProportion: 0.5))
    model.tags[1].focusedWindow = 10
    model.windows[10] = WindowData(id: 10, appId: "old", title: "old")

    let (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 10, appId: "app", title: "new"))

    check nextModel.windows[10].title == "new"
    check nextModel.validateModel().len == 0
    check nextModel.tags[1].flattenWindows() == @[WindowId(10)]

  test "stale focus command paths are no-ops, not crashes":
    var model = baseModel()
    model.tags[1].focusedWindow = 99

    for kind in [CmdMoveToScratchpad, CmdConsumeWindow, CmdExpelWindow, CmdZoom, CmdMoveWindowLeft, CmdMoveWindowRight]:
      let (nextModel, _) = update(model, Msg(kind: kind))
      check nextModel.tags[1].columns.len == 0

  test "select and overview focus tolerate missing active tag":
    var model = Model(activeTag: 9, overviewActive: true)
    model.tags[1] = initTagState(1)
    model.tags[1].columns.add(Column(windows: @[WindowId(1)], widthProportion: 0.5))
    model.tags[1].focusedWindow = 1
    model.windows[1] = WindowData(id: 1, appId: "terminal", title: "Terminal")

    var (nextModel, _) = update(model, Msg(kind: CmdSelectWindow))
    check nextModel.activeTag == 1
    check nextModel.overviewActive == false

    model.overviewActive = true
    let (focusedModel, _) = update(model, Msg(kind: CmdFocusNext))
    check focusedModel.activeTag == 1
    check focusedModel.tags[1].focusedWindow == 1

  test "river output events track primary output without crashing":
    var model = baseModel()

    var (nextModel, _) = update(model, Msg(kind: WlOutputPosition, positionOutputId: 42, outputX: 100, outputY: 50))
    check nextModel.primaryOutput == 42
    check nextModel.screenWidth == 1920
    check nextModel.screenHeight == 1080
    check nextModel.outputs[42].x == 100
    check nextModel.outputs[42].y == 50

    (nextModel, _) = update(nextModel, Msg(kind: WlOutputDimensions, outputId: 42, width: 1280, height: 720))
    check nextModel.screenWidth == 1280
    check nextModel.screenHeight == 720
    check nextModel.outputs[42].w == 1280
    check nextModel.outputs[42].h == 720

    (nextModel, _) = update(nextModel, Msg(kind: WlOutputUsable, usableOutputId: 42, usableX: 100, usableY: 90, usableW: 1280, usableH: 680))
    check nextModel.outputs[42].hasUsable
    check nextModel.outputs[42].usableY == 90
    check nextModel.outputs[42].usableH == 680

    (nextModel, _) = update(nextModel, Msg(kind: WlOutputRemoved, removedOutputId: 42))
    check nextModel.primaryOutput == 0
    check not nextModel.outputs.hasKey(42)

  test "river identifiers and fullscreen requests update model state":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title", createdIdentifier: "river-id"))
    check nextModel.windows[7].identifier == "river-id"

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: 7, fullscreenOutputId: 42))
    check nextModel.windows[7].isFullscreen
    check nextModel.windows[7].fullscreenOutput == 42

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowExitFullscreenRequested, exitFullscreenRequestId: 7))
    check not nextModel.windows[7].isFullscreen
    check nextModel.windows[7].fullscreenOutput == 0

  test "river late metadata updates live window state":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "old", title: "old"))

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowAppId, appIdWindowId: 7, updatedAppId: "new-app"))
    check nextModel.windows[7].appId == "new-app"

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowTitle, titleWindowId: 7, updatedTitle: "new title"))
    check nextModel.windows[7].title == "new title"

  test "river output removal clears affected fullscreen state":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlOutputDimensions, outputId: 42, width: 1280, height: 720))
    (nextModel, _) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title"))
    (nextModel, _) = update(nextModel, Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: 7, fullscreenOutputId: 0))
    check nextModel.windows[7].fullscreenOutput == 42

    var effects: seq[Effect]
    (nextModel, effects) = update(nextModel, Msg(kind: WlOutputRemoved, removedOutputId: 42))

    check not nextModel.windows[7].isFullscreen
    check nextModel.windows[7].fullscreenOutput == 0
    check effects.anyIt(it.kind == EffSetFullscreen and it.fsWinId == 7 and not it.isFullscreen)

  test "river dimensions hints are normalized and bound proposals":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title"))

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowDimensionsHint, hintWindowId: 7, minWidth: -10, minHeight: 200, maxWidth: 100, maxHeight: 50))

    let win = nextModel.windows[7]
    check win.minWidth == 0
    check win.minHeight == 200
    check win.maxWidth == 100
    check win.maxHeight == 200
    check win.boundedDimensions(50, 50) == (w: 50'i32, h: 200'i32)
    check win.boundedDimensions(500, 500) == (w: 100'i32, h: 200'i32)

  test "river actual dimensions are stored for shell compatibility":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title"))

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowDimensions, dimensionsWindowId: 7, actualWidth: 801, actualHeight: 599))

    check nextModel.windows[7].actualW == 801
    check nextModel.windows[7].actualH == 599

  test "river maximize and minimize requests update model and focus":
    var model = baseModel()
    var (nextModel, effects) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title"))
    (nextModel, _) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 8, appId: "app", title: "other"))

    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowMaximizeRequested, maximizeRequestId: 7))
    check nextModel.windows[7].isMaximized
    check effects.anyIt(it.kind == EffSetMaximized and it.maxWinId == 7 and it.isMaximized)

    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowUnmaximizeRequested, unmaximizeRequestId: 7))
    check not nextModel.windows[7].isMaximized
    check effects.anyIt(it.kind == EffSetMaximized and it.maxWinId == 7 and not it.isMaximized)

    nextModel.tags[1].focusedWindow = 7
    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowMinimizeRequested, minimizeRequestId: 7))
    check nextModel.windows[7].isMinimized
    check not nextModel.windows[7].isMaximized
    check nextModel.tags[1].focusedWindow == 8

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusWindowById, focusWindowId: 7))
    check not nextModel.windows[7].isMinimized
    check nextModel.tags[1].focusedWindow == 7

  test "layer focus events suppress and restore normal focus policy":
    var model = baseModel()

    var (nextModel, effects) = update(model, Msg(kind: WlLayerFocusExclusive))
    check nextModel.layerFocusExclusive
    check effects.anyIt(it.kind == EffManageDirty)

    (nextModel, effects) = update(nextModel, Msg(kind: WlLayerFocusNone))
    check not nextModel.layerFocusExclusive
    check effects.anyIt(it.kind == EffManageDirty)

  test "consume ignores empty next columns":
    var model = baseModel()
    model.tags[1].columns = @[
      Column(windows: @[WindowId(1)], widthProportion: 0.5),
      Column(windows: @[], widthProportion: 0.5)
    ]
    model.tags[1].focusedWindow = 1
    model.windows[1] = WindowData(id: 1)

    let (nextModel, _) = update(model, Msg(kind: CmdConsumeWindow))
    check nextModel.tags[1].columns.len == 2

  test "malformed config fields preserve defaults and valid fields":
    let path = getCurrentDir() / "bad_config.kdl"
    writeFile(path, """
layout {
  gaps
  animation-speed 8.0
  center-focused-column "invalid"
  smart-gaps #true
}
tag-rules {
  tag -1 default-layout="grid"
  tag 2 default-layout="bad"
}
window-rule {
  default-tag -3
  forced-layout "bad"
}
""")
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.gaps == 16
    check config.layout.animationSpeed == 1.0
    check config.layout.centerFocusedColumn == "never"
    check config.layout.smartGaps == true
    check config.tagRules.len == 1
    check config.tagRules[0].tagId == 2
    check config.tagRules[0].defaultLayout == Scroller
    check config.windowRules[0].defaultTag == 0
    check config.windowRules[0].forcedLayout == 0

  test "layouts never emit negative geometry for tiny screens and huge gaps":
    let screen = Rect(x: 0, y: 0, w: 20, h: 10)
    var tag = initTagState(1, Scroller)
    tag.focusedWindow = 1
    tag.columns.add(Column(windows: @[WindowId(1), 2], widthProportion: 0.0))
    var windows = initTable[WindowId, WindowData]()
    windows[1] = WindowData(id: 1, heightProportion: 0.0)
    windows[2] = WindowData(id: 2, heightProportion: 0.0)

    for instr in layoutScroller(tag, windows, screen, 100, 100, false, false, "never"):
      check instr.geom.w >= 0
      check instr.geom.h >= 0

    let layouts = [
      layoutMasterStack(tag, screen, 100, 100),
      layoutGrid(tag, screen, 100, 100),
      layoutMonocle(tag, screen, 100)
    ]
    for rendered in layouts:
      for instr in rendered:
        check instr.geom.w >= 0
        check instr.geom.h >= 0
