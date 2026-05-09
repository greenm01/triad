import unittest, tables, os, sequtils, options, asyncdispatch, asyncnet, json, strutils
from nativesockets import AF_UNIX, SOCK_STREAM, IPPROTO_IP
import ../src/core/model
import ../src/core/defaults
import ../src/core/model_utils
import ../src/core/msg
import ../src/core/restore_state
import ../src/core/update
import ../src/layouts/scroller
import ../src/layouts/tiling
import ../src/config/parser
import ../src/ipc/commands
import ../src/ipc/socket
import ../src/utils/session_env

proc baseModel(): Model =
  result = Model(activeTag: 1, screenWidth: 1920, screenHeight: 1080, outerGaps: 10, innerGaps: 5)
  result.tags[1] = initTagState(1)

proc waitForIpcReply(path, payload: string): string =
  var lastError = ""
  for _ in 0 ..< 50:
    try:
      return waitFor sendIpcRequest(path, payload)
    except CatchableError as e:
      lastError = e.msg
      waitFor sleepAsync(20)
  raise newException(IOError, "IPC server did not become ready: " & lastError)

proc waitForSubscribers(count: int): bool =
  for _ in 0 ..< 50:
    if subscribers.len >= count:
      return true
    waitFor sleepAsync(20)
  false

proc waitForTriadSubscribers(count: int): bool =
  for _ in 0 ..< 50:
    if triadSubscribers.len >= count:
      return true
    waitFor sleepAsync(20)
  false

suite "Crash hardening":
  test "daemon startup rejects missing Wayland session environment":
    check waylandSessionProblem("", "wayland-1") == "XDG_RUNTIME_DIR is not set"
    check waylandSessionProblem("/run/user/1000", "") == "WAYLAND_DISPLAY is not set"
    check waylandSessionProblem("/run/user/1000", "wayland-1") == ""

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

  test "session lock events suppress and restore normal focus policy":
    var model = baseModel()
    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "one"))
    (nextModel, _) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 8, appId: "app", title: "two"))
    nextModel.tags[1].focusedWindow = 7

    var effects: seq[Effect]
    (nextModel, effects) = update(nextModel, Msg(kind: WlSessionLocked))
    check nextModel.sessionLocked
    check effects.anyIt(it.kind == EffManageDirty)

    (nextModel, effects) = update(nextModel, Msg(kind: WlFocusChanged, newFocusedId: 8))
    check nextModel.tags[1].focusedWindow == 7
    check effects.len == 0

    (nextModel, effects) = update(nextModel, Msg(kind: CmdFocusNext))
    check nextModel.tags[1].focusedWindow == 7
    check effects.len == 0

    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 9, appId: "app", title: "locked"))
    check nextModel.tags[1].focusedWindow == 7

    (nextModel, effects) = update(nextModel, Msg(kind: WlManageStart))
    check nextModel.tags[1].focusedWindow == 7
    check not effects.anyIt(it.kind == EffFocusWindow)

    (nextModel, effects) = update(nextModel, Msg(kind: WlSessionUnlocked))
    check not nextModel.sessionLocked
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 7)
    check effects.anyIt(it.kind == EffManageDirty)

  test "lock-session command is non-fatal and argv based":
    var model = baseModel()

    var updated = update(model, Msg(kind: CmdLockSession))
    var effects = updated[1]
    check effects.anyIt(it.kind == EffLog)

    model.screenLock.command = @["lockme", "--dev-mode"]
    updated = update(model, Msg(kind: CmdLockSession))
    effects = updated[1]
    check effects.anyIt(it.kind == EffSpawnScreenLock and it.screenLockCommand == @["lockme", "--dev-mode"])

    let parsed = parseLegacyCommand("lock-session")
    check parsed.isSome
    check parsed.get().kind == CmdLockSession

  test "River protocol IPC commands are parsed and guarded":
    var parsed = parseLegacyCommand("warp-pointer 12 -4")
    check parsed.isSome
    check parsed.get().kind == CmdWarpPointer
    check parsed.get().warpX == 12
    check parsed.get().warpY == -4

    check parseLegacyCommand("eat-next-key").get().kind == CmdEatNextKey
    check parseLegacyCommand("cancel-eat-next-key").get().kind == CmdCancelEatNextKey
    check parseLegacyCommand("config-reload").get().kind == CmdConfigReload
    check parseLegacyCommand("triad-reload").get().kind == CmdTriadReload
    check parseLegacyCommand("reload-config").isNone
    check parseLegacyCommand("stop-manager").get().kind == CmdStopManager
    check parseLegacyCommand("focus-shell-ui").get().kind == CmdFocusShellUi
    check parseLegacyCommand("spawn fuzzel").get().spawnCommand == @["fuzzel"]
    check parseLegacyCommand("focus-left").get().kind == CmdFocusDirection
    check parseLegacyCommand("focus-left").get().direction == DirLeft
    check parseLegacyCommand("focus-last").get().kind == CmdFocusLast
    check parseLegacyCommand("focus-column-first").get().kind == CmdFocusColumnFirst
    check parseLegacyCommand("focus-window-or-workspace-down").get().kind == CmdFocusWindowOrWorkspaceDown
    check parseLegacyCommand("focus-occupied-tag-right").get().kind == CmdFocusOccupiedTagRight
    check parseLegacyCommand("move-to-tag-left").get().kind == CmdMoveToTagLeft
    check parseLegacyCommand("move-column-to-last").get().kind == CmdMoveColumnToLast
    check parseLegacyCommand("move-window-up-or-to-workspace-up").get().kind == CmdMoveWindowUpOrToWorkspaceUp
    check parseLegacyCommand("layout-deck").get().newLayout == Deck
    check parseLegacyCommand("layout-center-tile").get().newLayout == CenterTile
    check parseLegacyCommand("switch-layout").get().kind == CmdSwitchLayout
    check parseLegacyCommand("open-overview").get().kind == CmdOpenOverview
    check parseLegacyCommand("close-overview").get().kind == CmdCloseOverview
    check parseLegacyCommand("move-to-named-scratchpad terminal").get().scratchpadName == "terminal"
    check parseLegacyCommand("toggle-named-scratchpad music").get().scratchpadName == "music"
    check parseLegacyCommand("restore-scratchpad").get().kind == CmdRestoreScratchpad

    var model = baseModel()
    var (_, effects) = update(model, Msg(kind: CmdExitSession))
    check effects.anyIt(it.kind == EffLog)

    model.allowExitSession = true
    (_, effects) = update(model, Msg(kind: CmdExitSession))
    check effects.anyIt(it.kind == EffExitSession)

  test "IPC accepts request and command clients independently":
    let dir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-request")
    createDir(dir)
    let path = dir / "triad.sock"
    var messages: seq[Msg] = @[]
    var model = baseModel()

    proc onMsg(msg: Msg) {.gcsafe.} =
      {.cast(gcsafe).}:
        messages.add(msg)

    proc getModel(): Model {.gcsafe.} =
      {.cast(gcsafe).}:
        model

    asyncCheck startIpcServer(path, onMsg, getModel)

    let reply = parseJson(waitForIpcReply(path, "\"Outputs\""))
    check reply["Ok"].hasKey("Outputs")

    waitFor sendIpcMsg(path, "focus-next")
    for _ in 0 ..< 50:
      if messages.len > 0:
        break
      waitFor sleepAsync(20)

    check messages.len == 1
    check messages[0].kind == CmdFocusNext
    removeDir(dir)

  test "IPC event stream subscribers receive broadcasts and dead subscribers are pruned":
    let dir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-stream")
    createDir(dir)
    let path = dir / "triad.sock"
    var model = baseModel()

    proc onMsg(msg: Msg) {.gcsafe.} =
      discard msg

    proc getModel(): Model {.gcsafe.} =
      {.cast(gcsafe).}:
        model

    subscribers.setLen(0)
    asyncCheck startIpcServer(path, onMsg, getModel)
    discard waitForIpcReply(path, "\"Outputs\"")

    let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    waitFor client.connectUnix(path)
    waitFor client.send("event-stream\L")
    check waitForSubscribers(1)

    waitFor broadcastJson("""{"OverviewOpenedOrClosed":{"is_open":true}}""")
    let eventLine = client.recvLine()
    check waitFor withTimeout(eventLine, 1000)
    check eventLine.read().contains("OverviewOpenedOrClosed")

    if not client.isClosed:
      client.close()
    subscribers.setLen(0)
    subscribers.add(AsyncSocket(nil))
    waitFor broadcastJson("""{"OverviewOpenedOrClosed":{"is_open":false}}""")
    check subscribers.len == 0
    removeDir(dir)

  test "Native Triad event subscribers are filtered by event kind":
    let dir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-triad-stream")
    createDir(dir)
    let path = dir / "triad.sock"
    var model = baseModel()

    proc onMsg(msg: Msg) {.gcsafe.} =
      discard msg

    proc getModel(): Model {.gcsafe.} =
      {.cast(gcsafe).}:
        model

    triadSubscribers.setLen(0)
    asyncCheck startIpcServer(path, onMsg, getModel)
    discard waitForIpcReply(path, "\"Outputs\"")

    let stateClient = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    waitFor stateClient.connectUnix(path)
    waitFor stateClient.send("""{"triad":{"version":1,"request":"event-stream","events":["state"]}}""" & "\L")
    discard waitFor stateClient.recvLine()
    check (waitFor stateClient.recvLine()).contains("state-changed")

    let layoutClient = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    waitFor layoutClient.connectUnix(path)
    waitFor layoutClient.send("""{"triad":{"version":1,"request":"event-stream","events":["layout"]}}""" & "\L")
    discard waitFor layoutClient.recvLine()
    check (waitFor layoutClient.recvLine()).contains("layout-state-changed")
    check waitForTriadSubscribers(2)
    check triadSubscribers.countIt(it.state and not it.layout) == 1
    check triadSubscribers.countIt(it.layout and not it.state) == 1

    waitFor broadcastTriadJson("""{"triad":{"version":1,"event":"state-changed","state":{}}}""", "state")
    let stateEvent = stateClient.recvLine()
    check waitFor withTimeout(stateEvent, 1000)
    check stateEvent.read().contains("state-changed")

    waitFor broadcastTriadJson("""{"triad":{"version":1,"event":"layout-state-changed","state":{}}}""", "layout")
    let layoutEvent = layoutClient.recvLine()
    check waitFor withTimeout(layoutEvent, 1000)
    check layoutEvent.read().contains("layout-state-changed")

    if not stateClient.isClosed:
      stateClient.close()
    if not layoutClient.isClosed:
      layoutClient.close()
    triadSubscribers.setLen(0)
    removeDir(dir)

  test "IPC refuses active sockets and non-socket paths":
    let activeDir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-active")
    createDir(activeDir)
    let activePath = activeDir / "triad.sock"
    let activeServer = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    activeServer.bindUnix(activePath)
    activeServer.listen()
    waitFor startIpcServer(activePath, proc(msg: Msg) {.gcsafe.} = discard, baseModel)

    let activeClient = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    waitFor activeClient.connectUnix(activePath)
    activeClient.close()
    activeServer.close()
    removeFile(activePath)
    removeDir(activeDir)

    let fileDir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-file")
    createDir(fileDir)
    let filePath = fileDir / "triad.sock"
    writeFile(filePath, "not a socket")
    waitFor startIpcServer(filePath, proc(msg: Msg) {.gcsafe.} = discard, baseModel)
    check fileExists(filePath)
    removeFile(filePath)
    removeDir(fileDir)

  test "IPC removes stale sockets and rejects oversized request lines":
    let staleDir = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-stale")
    createDir(staleDir)
    let stalePath = staleDir / "triad.sock"
    block:
      let staleServer = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      staleServer.bindUnix(stalePath)
      staleServer.listen()
      staleServer.close()

    asyncCheck startIpcServer(stalePath, proc(msg: Msg) {.gcsafe.} = discard, baseModel)
    discard waitForIpcReply(stalePath, "\"Outputs\"")

    let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    waitFor client.connectUnix(stalePath)
    waitFor client.send(repeat("x", MaxIpcLineBytes + 1) & "\L")
    let response = waitFor client.recv(16)
    check response == ""
    client.close()

  test "IPC event stream subscriber cap is enforced":
    subscribers = @[]
    for _ in 0 ..< MaxIpcSubscribers:
      subscribers.add(newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP))

    let path = getTempDir() / ("triad-ipc-" & $getCurrentProcessId() & "-cap.sock")
    asyncCheck startIpcServer(path, proc(msg: Msg) {.gcsafe.} = discard, baseModel)
    let response = waitForIpcReply(path, "\"EventStream\"")
    check parseJson(response)["Err"].getStr() == "too many event-stream subscribers"

    for client in subscribers:
      if client != nil and not client.isClosed:
        client.close()
    subscribers = @[]

  test "River decoration presentation menu resize and modifier state are modeled":
    var model = baseModel()
    var (nextModel, effects) = update(model, Msg(kind: WlWindowCreated, windowId: 7, appId: "app", title: "one"))

    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowDecorationHint, decorationWindowId: 7, decorationHint: 0))
    check nextModel.windows[7].hasDecorationHint
    check nextModel.windows[7].decorationHint == 0'u32
    check effects.anyIt(it.kind == EffManageDirty)

    (nextModel, _) = update(nextModel, Msg(kind: WlWindowPresentationHint, presentationWindowId: 7, presentationHint: 1))
    check nextModel.windows[7].hasPresentationHint
    check nextModel.windows[7].presentationHint == 1'u32

    nextModel.windowMenu.command = @["menu-tool"]
    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowMenuRequested, menuWindowId: 7, menuX: 12, menuY: 34))
    check effects.anyIt(it.kind == EffSpawnWindowMenu and it.windowMenuCommand == @["menu-tool"] and it.windowMenuId == 7 and it.windowMenuX == 12 and it.windowMenuY == 34)

    (nextModel, _) = update(nextModel, Msg(kind: CmdToggleFloating))
    (nextModel, effects) = update(nextModel, Msg(kind: WlPointerResizeRequested, resizeWinId: 7, resizeSeat: nil, resizeEdges: 8))
    check effects.anyIt(it.kind == EffInformResizeStart and it.resizeLifecycleWinId == 7)
    (nextModel, effects) = update(nextModel, Msg(kind: WlPointerRelease))
    check effects.anyIt(it.kind == EffInformResizeEnd and it.resizeLifecycleWinId == 7)

    (nextModel, _) = update(nextModel, Msg(kind: WlModifiersChanged, oldModifiers: 0, newModifiers: 64))
    check nextModel.activeModifiers == 64'u32

    (nextModel, effects) = update(nextModel, Msg(kind: WlShellSurfaceInteraction, shellSurfaceId: 99))
    check effects.anyIt(it.kind == EffFocusShellSurface and it.focusShellSurfaceId == 99)

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
    check config.layout.centerFocusedColumn == DefaultCenterFocusedColumn
    check config.layout.smartGaps == true
    check config.tagRules.len == 1
    check config.tagRules[0].tagId == 2
    check config.tagRules[0].defaultLayout == Scroller
    check config.windowRules[0].defaultTag == 0
    check config.windowRules[0].forcedLayout == 0

  test "live restore snapshot parser keeps active tag and window tags":
    let parsed = parseLiveRestoreJson("""
{
  "workspaces": [
    {"id": 1, "is_active": false},
    {"id": 2, "is_active": true}
  ],
  "windows": [
    {
      "id": 10,
      "title": "Browser",
      "raw_app_id": "brave",
      "workspace_id": 2,
      "is_focused": true,
      "is_maximized": true,
      "layout": {
        "pos_in_scrolling_layout": [1, 1],
        "tile_size": [2000.0, 1000.0],
        "window_size": [1000, 900]
      }
    },
    {"id": 11, "workspace_id": null}
  ]
}
""")

    check parsed.isSome
    let state = parsed.get()
    check state.activeTag == 2
    check state.tagByWindow[10] == 2
    check state.tags[2].focusedWindow == 10
    check state.tags[2].columns.len == 1
    check state.tags[2].columns[0].windows == @[WindowId(10)]
    check state.windows[10].isMaximized
    check state.windows[10].appId == "brave"
    check state.windows[10].title == "Browser"
    check state.windows[10].widthProportion == 0.5'f32
    check not state.tagByWindow.hasKey(11)
    check parseLiveRestoreJson("{bad").isNone

    let nativeWithoutHistory = parseLiveRestoreJson("""{"schema":"triad-live-restore-v2","active_tag":1,"focused_window":10,"tags":[],"windows":[]}""")
    check nativeWithoutHistory.isSome
    check nativeWithoutHistory.get().focusHistory.len == 0
    check nativeWithoutHistory.get().workspaceHistory.len == 0

  test "consuming live restore snapshot removes it":
    let path = getTempDir() / "triad-live-restore-test.json"
    writeFile(path, """{"workspaces":[{"id":3,"is_active":true}],"windows":[]}""")

    let state = consumeLiveRestoreState(path)
    check state.isSome
    check state.get().activeTag == 3
    check not fileExists(path)

  test "live restore snapshot load waits for explicit completion":
    let path = getTempDir() / "triad-live-restore-load-test.json"
    writeFile(path, """{"workspaces":[{"id":4,"is_active":true}],"windows":[]}""")

    let state = loadLiveRestoreState(path)
    check state.isSome
    check state.get().activeTag == 4
    check fileExists(path)
    check completeLiveRestoreState(path)
    check not fileExists(path)

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
