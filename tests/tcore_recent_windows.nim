import std/math
import tcore_support

proc recentConfig(debounceMs = 0'i32, openDelayMs = 0'i32): RecentWindowsConfig =
  RecentWindowsConfig(
    enabled: true,
    debounceMs: debounceMs,
    openDelayMs: openDelayMs,
    highlight: RecentWindowsHighlightConfig(
      activeColor: 0x999999ff'u32, urgentColor: 0xff9999ff'u32, padding: 30
    ),
    previews: RecentWindowsPreviewConfig(maxHeight: 480, maxScale: 0.5),
  )

proc recentModel(debounceMs = 0'i32, openDelayMs = 0'i32): Model =
  initRuntimeStateFromConfig(
    Config(
      workspaces: WorkspaceConfig(defaultCount: 3),
      recentWindows: recentConfig(debounceMs, openDelayMs),
    )
  ).model

proc backgroundOpenedRecentModel(): Model =
  result = initRuntimeStateFromConfig(
    Config(
      workspaces: WorkspaceConfig(defaultCount: 3),
      recentWindows: recentConfig(),
      windowRules:
        @[
          WindowRule(
            appIdMatch: "background",
            defaultWorkspace: 2,
            openFocusedSet: true,
            openFocused: false,
          )
        ],
    )
  ).model
  result.applyMsg(
    Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1200, height: 800)
  )
  result.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "one")
  )
  result.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "two")
  )
  result.applyMsg(
    Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "background", title: "bg")
  )

suite "Core Runtime Logic: recent windows":
  test "stale pending recent focus clears on tick":
    var model = recentModel(debounceMs = 1)
    model.pendingRecentFocusWindow = WindowId(99)
    model.pendingRecentFocusElapsedMs = 1

    check not model.tickRecentWindows(1)
    check model.pendingRecentFocusWindow == NullWindowId
    check model.pendingRecentFocusElapsedMs == 0

  test "recent-window-next opens on the previous MRU window and confirms on modifier release":
    var model = recentModel()
    model.seedCameraWindows(3)

    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))
    check model.recentWindowsActive
    check uint32(model.selectedRecentWindow()) == 2

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlModifiersChanged, oldModifiers: 8'u32, newModifiers: 0)
    )
    check not model.recentWindowsActive
    check model.focusedWindowId() == 2
    check effects.hasFocusEffect(2)

  test "recent-window candidates include background opens before older visits":
    var model = backgroundOpenedRecentModel()

    check model.focusedWindowId() == 2
    check model.recentWindowCandidates().mapIt(uint32(it)) == @[3'u32, 2'u32, 1'u32]

  test "recent-window startup navigation anchors to current focus":
    var model = backgroundOpenedRecentModel()

    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))
    check model.recentWindowsActive
    check uint32(model.selectedRecentWindow()) == 1

    discard model.cancelRecentWindows()
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowPrev))
    check model.recentWindowsActive
    check uint32(model.selectedRecentWindow()) == 3

  test "recent-window app-id filter skips other applications":
    var model = recentModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1200, height: 800)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "editor", title: "one")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "browser", title: "two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "editor", title: "three")
    )

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdRecentWindowNext,
        recentFilter: RecentWindowFilter.AppId,
        recentFilterSet: true,
      )
    )

    check model.recentWindowsActive
    check uint32(model.selectedRecentWindow()) == 1

  test "recent-window history debounces quick focus changes":
    var model = recentModel(debounceMs = 750)
    model.seedCameraWindows(3)
    model.focusExternal(1)

    check model.focusHistory[^1] == WindowId(1)
    check model.recentWindowHistory[^1] == WindowId(3)
    for _ in 0 ..< 47:
      discard model.updateModel(Msg(kind: MsgKind.CmdTick))
    check model.recentWindowHistory[^1] == WindowId(1)

  test "recent-window debounce uses elapsed tick time":
    var model = recentModel(debounceMs = 750)
    model.seedCameraWindows(3)
    model.focusExternal(1)

    discard model.updateModel(Msg(kind: MsgKind.CmdTick, tickElapsedMs: 749))
    check model.recentWindowHistory[^1] == WindowId(3)
    discard model.updateModel(Msg(kind: MsgKind.CmdTick, tickElapsedMs: 1))
    check model.recentWindowHistory[^1] == WindowId(1)

  test "duplicate pending recent focus does not reset debounce":
    var model = recentModel(debounceMs = 750)
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))

    discard model.updateModel(Msg(kind: MsgKind.CmdTick, tickElapsedMs: 400))
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdTick, tickElapsedMs: 350))

    check model.recentWindowHistory[^1] == WindowId(1)
    check model.pendingRecentFocusWindow == NullWindowId

  test "duplicate committed recent focus does not arm debounce":
    var model = recentModel(debounceMs = 750)
    model.seedCameraWindows(3)
    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))
    discard model.updateModel(Msg(kind: MsgKind.CmdTick, tickElapsedMs: 750))

    model.applyMsg(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 1))

    check model.recentWindowHistory[^1] == WindowId(1)
    check model.pendingRecentFocusWindow == NullWindowId

  test "recent-window scope can restrict candidates to active workspace":
    var model = recentModel()
    model.seedCameraWindows(2)
    model.focusExternal(1)
    model.applyMsg(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    discard model.updateModel(
      Msg(
        kind: MsgKind.CmdRecentWindowNext,
        recentScope: RecentWindowScope.Workspace,
        recentScopeSet: true,
      )
    )

    check model.recentWindowsActive
    check uint32(model.selectedRecentWindow()) == 2

  test "recent-window pointer hover selects a visible preview":
    var model = recentModel()
    model.seedCameraWindows(3)
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let previews = model.recentWindowPreviews(model.primaryScreen())
    check previews.len == 3
    let target = previews[0]
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlRecentWindowPointerMotion,
        recentPointerX: target.geom.x + target.geom.w div 2,
        recentPointerY: target.geom.y + target.geom.h div 2,
      )
    )
    check model.selectedRecentWindow() == target.winId

  test "recent-window previews reserve highlight padding between neighbors":
    var model = recentModel()
    model.seedCameraWindows(3)
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let previews = model.recentWindowPreviews(model.primaryScreen())
    check previews.len == 3
    let requiredGap = model.recentWindows.highlight.padding * 2 + 2'i32 * 2'i32 + 16'i32
    for idx in 0 ..< previews.len - 1:
      let gap = previews[idx + 1].geom.x - (previews[idx].geom.x + previews[idx].geom.w)
      check gap >= requiredGap

  test "recent-window previews are bounded by output-aware niri sizing":
    var model = recentModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "wide", title: "Wide")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 1,
        actualWidth: 4000,
        actualHeight: 500,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "tall", title: "Tall")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 2,
        actualWidth: 500,
        actualHeight: 4000,
      )
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let previews = model.recentWindowPreviews(model.primaryScreen())
    let boundedMaxH = min(
      model.recentWindows.previews.maxHeight,
      int32(
        round(float32(model.primaryScreen().h) * model.recentWindows.previews.maxScale)
      ),
    )
    let aspectMaxW = int32(
      round(
        float32(boundedMaxH * model.primaryScreen().w) / float32(
          model.primaryScreen().h
        )
      )
    )
    for preview in previews:
      check preview.geom.h <= boundedMaxH
      check preview.geom.w <= aspectMaxW

  test "recent-window presentation dimensions do not overwrite source dimensions":
    var model = recentModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "one", title: "One")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 1,
        actualWidth: 1200,
        actualHeight: 800,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "two", title: "Two")
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let selected = model.selectedRecentWindow()
    let before = model.windowData(selected).get()
    let external = uint32(before.externalId)
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: external,
        actualWidth: 16,
        actualHeight: 16,
      )
    )
    let after = model.windowData(selected).get()

    check before.actualW == 1200
    check before.actualH == 800
    check after.actualW == before.actualW
    check after.actualH == before.actualH

  test "recent-window previews recover from poisoned minimum source dimensions":
    var model = recentModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "poisoned", title: "Tiny")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 1,
        actualWidth: 16,
        actualHeight: 16,
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "normal", title: "Normal")
    )
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let poisoned = model.recentWindowPreviews(model.primaryScreen()).filterIt(
      uint32(it.winId) == 1
    )[0]

    check poisoned.geom.w > 16
    check poisoned.geom.h > 16

  test "recent-window previews suppress normal compositor borders":
    var model = recentModel()
    model.borderWidth = 3
    model.seedCameraWindows(2)
    let focused = model.selectedRecentWindow()

    check model.renderWindowBorder(focused, true).width == 3

    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    check model.recentWindowsVisible()
    check model.renderWindowBorder(model.selectedRecentWindow(), true).width == 0

  test "overview keeps normal compositor borders":
    var model = recentModel()
    model.borderWidth = 3
    model.seedCameraWindows(2)
    discard model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check model.renderWindowBorder(model.selectedRecentWindow(), true).width == 3

  test "recent-window pointer hover freezes strip position":
    var model = recentModel()
    model.seedCameraWindows(4)
    discard model.updateModel(Msg(kind: MsgKind.CmdRecentWindowNext))

    let before = model.recentWindowPreviews(model.primaryScreen())
    let target = before.filterIt(not it.selected)[0]
    discard model.updateModel(
      Msg(
        kind: MsgKind.WlRecentWindowPointerMotion,
        recentPointerX: target.geom.x + target.geom.w div 2,
        recentPointerY: target.geom.y + target.geom.h div 2,
      )
    )
    let after = model.recentWindowPreviews(model.primaryScreen())

    check model.selectedRecentWindow() == target.winId
    check after[0].geom.x == before[0].geom.x
