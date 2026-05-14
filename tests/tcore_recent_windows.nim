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

suite "Core Runtime Logic: recent windows":
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
