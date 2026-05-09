import json, options, sequtils, tables, unittest
import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/restore_state
import ../src/ipc/commands
import ../src/ipc/niri_compat
import ../src/layouts/scroller
import ../src/layouts/tiling
import ../src/state/invariants
import ../src/state/snapshot
import ../src/systems/daemon_view
import ../src/systems/runtime_facade
import ../src/systems/update
import ../src/types/runtime_values
import ../src/types/shell_snapshot
import ../src/utils/session_env

proc baseSnapshot(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[Scroller, Grid],
    workspaces: @[
      ShellWorkspace(
        tagId: 1,
        workspaceIdx: 1,
        layoutMode: Scroller,
        isActive: true,
        outputName: "triad-0",
        masterCount: 1,
        masterSplitRatio: 0.5)
    ],
    outputs: @[ShellOutput(name: "triad-0", w: 1920, h: 1080)])

suite "Crash hardening":
  test "daemon startup rejects missing Wayland session environment":
    check waylandSessionProblem("", "wayland-1") ==
      "XDG_RUNTIME_DIR is not set"
    check waylandSessionProblem("/run/user/1000", "") ==
      "WAYLAND_DISPLAY is not set"
    check waylandSessionProblem("/run/user/1000", "wayland-1") == ""

  test "duplicate window create keeps a single shell window":
    var model = initRuntimeStateFromConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 3))).model
    for title in ["old", "new"]:
      let (next, _) = model.update(Msg(
        kind: WlWindowCreated,
        windowId: 10,
        appId: "app",
        title: title))
      model = next

    let snapshot = model.shellSnapshot()
    check model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 10
    check snapshot.windows[0].title == "new"

  test "stale focus command paths are no-ops, not crashes":
    var model = initRuntimeStateFromConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 3))).model

    for msg in [
      Msg(kind: CmdMoveToScratchpad),
      Msg(kind: CmdConsumeWindow),
      Msg(kind: CmdExpelWindow),
      Msg(kind: CmdZoom),
      Msg(kind: CmdMoveWindowLeft),
      Msg(kind: CmdMoveWindowRight),
      Msg(kind: CmdToggleFloating),
      Msg(kind: CmdToggleFullscreen)
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok
      check model.shellSnapshot().windows.len == 0

  test "river output and fullscreen events tolerate removal":
    var model = initRuntimeStateFromConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 3))).model
    for msg in [
      Msg(kind: WlOutputDimensions, outputId: 42, width: 1280, height: 720),
      Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "title"),
      Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: 7,
        fullscreenOutputId: 0)
    ]:
      let (next, _) = model.update(msg)
      model = next

    var effects: seq[Effect]
    (model, effects) = model.update(Msg(
      kind: WlOutputRemoved,
      removedOutputId: 42))
    check model.validateInvariants().ok
    check effects.anyIt(
      it.kind == EffSetFullscreen and it.fsWinId == 7 and
      not it.isFullscreen)

  test "dimension hints are normalized for daemon bounds":
    var model = initRuntimeStateFromConfig(Config()).model
    let (next, _) = model.update(Msg(
      kind: WlWindowCreated,
      windowId: 7,
      appId: "app",
      title: "title"))
    model = next
    let (hinted, _) = model.update(Msg(
      kind: WlWindowDimensionsHint,
      hintWindowId: 7,
      minWidth: -10,
      minHeight: 200,
      maxWidth: 100,
      maxHeight: 50))
    let win = hinted.windowDataForRiverId(7).get()

    check win.minWidth == 0
    check win.minHeight == 200
    check win.maxWidth == 100
    check win.maxHeight == 200
    check win.boundedDimensions(50, 50) == (w: 50'i32, h: 200'i32)
    check win.boundedDimensions(500, 500) == (w: 100'i32, h: 200'i32)

  test "Niri compatibility rejects malformed IPC without crashing":
    let malformed = niri_compat.handleNiriRequest("{", baseSnapshot())
    check malformed.handled
    check parseJson(malformed.reply)["Err"].getStr().len > 0

    let unknown = niri_compat.handleNiriRequest(
      """{"Action":{"NotARealAction":{}}}""",
      baseSnapshot())
    check unknown.handled
    check parseJson(unknown.reply)["Err"].getStr().len > 0

  test "text command parser tolerates malformed commands":
    check parseTextCommand("").isNone
    check parseTextCommand("focus-workspace nope").isNone
    check parseTextCommand("focus-workspace 2").get().kind ==
      CmdFocusWorkspaceIndex

  test "native live restore parser rejects invalid or old payloads":
    check parseLiveRestoreJson("").isNone
    check parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""").isNone
    let parsed = parseLiveRestoreJson("""
{
  "schema": "triad-live-restore-v2",
  "active_tag": 1,
  "tags": [{"id": 1, "layout_mode": "scroller"}]
}
""")
    check parsed.isSome
    check parsed.get().activeTag == 1

  test "layout functions handle nonnegative rectangles":
    let screen = Rect(x: 0, y: 0, w: 100, h: 80)
    var tag = TagState(
      tagId: 1,
      layoutMode: Scroller,
      focusedWindow: 1,
      masterCount: 1,
      masterSplitRatio: 0.5)
    tag.columns.add(Column(windows: @[WindowId(1), 2], widthProportion: 0.5))

    let scroller = layoutScroller(tag, initTable[WindowId, WindowData](),
      screen, 4, 2, false, false, "never")
    let tiled = layoutMasterStack(tag, screen, 4, 2)

    for instruction in scroller & tiled:
      check instruction.geom.w >= 0
      check instruction.geom.h >= 0
