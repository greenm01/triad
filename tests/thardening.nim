import std/[json, options, os, sequtils, tables, unittest]
import ../src/config/parser
import ../src/core/[effects, msg, restore_state]
from ../src/daemon/state import consumeMaximizedAck, expectMaximizedAck, initTriadDaemon
import ../src/ipc/[commands, niri_compat]
import ../src/layouts/[scroller, tiling]
import ../src/state/[invariants, snapshot]
import ../src/systems/[daemon_view, runtime_facade, update]
import ../src/types/[runtime_values, shell_snapshot]
import ../src/utils/session_env

proc baseSnapshot(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[LayoutMode.Scroller, LayoutMode.Grid],
    workspaces:
      @[
        ShellWorkspace(
          tagId: 1,
          workspaceIdx: 1,
          layoutMode: LayoutMode.Scroller,
          isActive: true,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        )
      ],
    outputs: @[ShellOutput(name: "triad-0", w: 1920, h: 1080)],
  )

suite "Crash hardening":
  test "daemon startup rejects missing Wayland session environment":
    check waylandSessionProblem("", "wayland-1") == "XDG_RUNTIME_DIR is not set"
    check waylandSessionProblem("/run/user/1000", "") == "WAYLAND_DISPLAY is not set"
    check waylandSessionProblem("/run/user/1000", "wayland-1") == ""

  test "daemon consumes only matching self-generated maximize acknowledgements":
    var daemon = initTriadDaemon()

    daemon.expectMaximizedAck(42, false)
    check not daemon.consumeMaximizedAck(42, true)
    check daemon.consumeMaximizedAck(42, false)
    check not daemon.consumeMaximizedAck(42, false)

  test "duplicate window create keeps a single shell window":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    for title in ["old", "new"]:
      let (next, _) = model.update(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: title)
      )
      model = next

    let snapshot = model.shellSnapshot()
    check model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 10
    check snapshot.windows[0].title == "new"

  test "stale focus command paths are no-ops, not crashes":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model

    for msg in [
      Msg(kind: MsgKind.CmdMoveToScratchpad),
      Msg(kind: MsgKind.CmdConsumeWindow),
      Msg(kind: MsgKind.CmdExpelWindow),
      Msg(kind: MsgKind.CmdZoom),
      Msg(kind: MsgKind.CmdMoveWindowLeft),
      Msg(kind: MsgKind.CmdMoveWindowRight),
      Msg(kind: MsgKind.CmdToggleFloating),
      Msg(kind: MsgKind.CmdToggleFullscreen),
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok
      check model.shellSnapshot().windows.len == 0

  test "river output and fullscreen events tolerate removal":
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 42, width: 1280, height: 720),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "app", title: "title"),
      Msg(
        kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: 7,
        fullscreenOutputId: 0,
      ),
    ]:
      let (next, _) = model.update(msg)
      model = next

    var effects: seq[Effect]
    (model, effects) =
      model.update(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 42))
    check model.validateInvariants().ok
    check effects.anyIt(
      it.kind == EffectKind.EffSetFullscreen and it.fsWinId == 7 and not it.isFullscreen
    )

  test "dimension hints are normalized for daemon bounds":
    var model = initRuntimeStateFromConfig(Config()).model
    let (next, _) = model.update(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "app", title: "title")
    )
    model = next
    let (hinted, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: 7,
        minWidth: -10,
        minHeight: 200,
        maxWidth: 100,
        maxHeight: 50,
      )
    )
    let win = hinted.windowDataForRiverId(7).get()

    check win.minWidth == 0
    check win.minHeight == 200
    check win.maxWidth == 100
    check win.maxHeight == 200
    check win.boundedDimensions(50, 50) == (w: 50'i32, h: 200'i32)
    check win.boundedDimensions(500, 500) == (w: 100'i32, h: 200'i32)
    check win.proposalDimensions(50, 50, honorMinimums = false) == (
      w: 50'i32, h: 50'i32
    )
    check win.proposalDimensions(500, 500, honorMinimums = false) ==
      (w: 100'i32, h: 200'i32)
    check win.needsCellClip(100, 100)
    check not win.needsCellClip(100, 220)

  test "Niri compatibility rejects malformed IPC without crashing":
    let malformed = niri_compat.handleNiriRequest("{", baseSnapshot())
    check malformed.handled
    check parseJson(malformed.reply)["Err"].getStr().len > 0

    let unknown = niri_compat.handleNiriRequest(
      """{"Action":{"NotARealAction":{}}}""", baseSnapshot()
    )
    check unknown.handled
    check parseJson(unknown.reply)["Err"].getStr().len > 0

  test "text command parser tolerates malformed commands":
    check parseTextCommand("").isNone
    check parseTextCommand("focus-workspace nope").isNone
    check parseTextCommand("focus-workspace 2").get().kind ==
      MsgKind.CmdFocusWorkspaceIndex

  test "native live restore parser rejects invalid or old payloads":
    check parseLiveRestoreJson("").isNone
    check parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""").isNone
    check not liveRestorePayloadApplied(
      """{"restore_status":"applied","active_tag":1}"""
    )
    let parsed = parseLiveRestoreJson(
      """
{
  "schema": "triad-live-restore-v2",
  "active_tag": 1,
  "tags": [{"id": 1, "layout_mode": "scroller"}]
}
"""
    )
    check parsed.isSome
    check parsed.get().activeTag == 1

  test "live restore completion preserves applied diagnostic snapshot":
    let path =
      getTempDir() / ("triad-live-restore-test-" & $getCurrentProcessId() & ".json")
    try:
      writeFile(
        path,
        """
{
  "schema": "triad-live-restore-v2",
  "restore_status": "pending",
  "active_tag": 1,
  "tags": [{"id": 1, "layout_mode": "scroller"}]
}
""",
      )
      check loadLiveRestoreState(path).isSome
      check completeLiveRestoreState(path)
      check fileExists(path)
      check liveRestoreStateApplied(path)
      check loadLiveRestoreState(path).isNone

      let applied = parseJson(readFile(path))
      check applied["restore_status"].getStr() == LiveRestoreStatusApplied
      check applied.hasKey("applied_at_unix_ms")
      check applied.hasKey("applied_by_pid")
    finally:
      if fileExists(path):
        removeFile(path)

  test "live restore collapse guard detects same-window collapse":
    var previous = LiveRestoreState(activeTag: 2)
    previous.windows[WindowId(10)] = RestoredWindowState(tagId: 1)
    previous.windows[WindowId(20)] = RestoredWindowState(tagId: 2)

    var candidate = LiveRestoreState(activeTag: 1)
    candidate.windows[WindowId(10)] = RestoredWindowState(tagId: 1)
    candidate.windows[WindowId(20)] = RestoredWindowState(tagId: 1)

    check previous.suspiciousLiveRestoreCollapse(candidate)

    candidate.windows[WindowId(20)] = RestoredWindowState(tagId: 2)
    check not previous.suspiciousLiveRestoreCollapse(candidate)

  test "layout functions handle nonnegative rectangles":
    let screen = Rect(x: 0, y: 0, w: 100, h: 80)
    var tag = TagState(
      tagId: 1,
      layoutMode: LayoutMode.Scroller,
      focusedWindow: 1,
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    tag.columns.add(Column(windows: @[WindowId(1), 2], widthProportion: 0.5))

    let scroller = layoutScroller(
      tag, initTable[WindowId, WindowData](), screen, 4, 2, false, false, "never"
    )
    let tiled = layoutMasterStack(tag, screen, 4, 2)

    for instruction in scroller & tiled:
      check instruction.geom.w >= 0
      check instruction.geom.h >= 0
