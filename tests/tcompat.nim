import json, options, os, strtabs, strutils, unittest
import ../src/core/app_identity
import ../src/core/msg
import ../src/ipc/commands
import ../src/ipc/niri_cli
import ../src/ipc/niri_compat
import ../src/ipc/quickshell_compat
import ../src/ipc/shell_overlay
import ../src/ipc/triad_native
import ../src/types/runtime_values
import ../src/types/shell_snapshot

proc installAppIdentityFixture() =
  let apps =
    getTempDir() / ("triad-compat-apps-" & $getCurrentProcessId()) /
      "applications"
  if dirExists(apps.parentDir()):
    removeDir(apps.parentDir())
  createDir(apps)
  writeFile(apps / "Alacritty.desktop", """
[Desktop Entry]
Name=Alacritty
Exec=alacritty
Icon=Alacritty
Categories=System;TerminalEmulator;
""")
  putEnv("XDG_DATA_HOME", apps.parentDir())
  putEnv("XDG_DATA_DIRS", "")

proc snapshotForShell(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[Scroller, Grid, Monocle],
    workspaces: @[
      ShellWorkspace(
        tagId: 1,
        workspaceIdx: 1,
        name: "main",
        layoutMode: Scroller,
        isActive: true,
        focusedWindow: 10,
        occupied: true,
        outputName: "triad-0",
        columns: @[ShellColumn(
          idx: 1,
          widthProportion: 0.5,
          windows: @[WindowId(10)])],
        masterCount: 1,
        masterSplitRatio: 0.5),
      ShellWorkspace(
        tagId: 2,
        workspaceIdx: 2,
        name: "web",
        layoutMode: Grid,
        outputName: "triad-0",
        masterCount: 1,
        masterSplitRatio: 0.5),
      ShellWorkspace(
        tagId: 3,
        workspaceIdx: 3,
        name: "",
        layoutMode: Scroller,
        outputName: "triad-0",
        masterCount: 1,
        masterSplitRatio: 0.5)
    ],
    windows: @[
      ShellWindow(
        id: 10,
        title: "Terminal",
        appId: "Alacritty",
        tagId: some(1'u32),
        workspaceIdx: 1,
        outputName: "triad-0",
        colIdx: 1,
        winIdx: 1,
        isFocused: true,
        widthProportion: 0.5,
        heightProportion: 1.0,
        actualW: 777,
        actualH: 555)
    ],
    outputs: @[
      ShellOutput(id: 0, name: "triad-0", w: 1920, h: 1080, isPrimary: true)
    ]
  )

proc handleNiriRequest(
    line: string; snapshot: ShellSnapshot): NiriIpcResult =
  niri_compat.handleNiriRequest(line, snapshot)

proc handleTriadRequest(
    line: string; snapshot: ShellSnapshot): TriadIpcResult =
  triad_native.handleTriadRequest(line, snapshot)

suite "Shell compatibility contracts":
  setup:
    installAppIdentityFixture()

  test "Niri workspace, window, and output reads use shell snapshots":
    let snapshot = snapshotForShell()
    let workspaces =
      parseJson(handleNiriRequest("\"Workspaces\"", snapshot).reply)["Ok"][
        "Workspaces"]
    check workspaces.len == 3
    check workspaces[0]["id"].getInt() == 1
    check workspaces[0]["idx"].getInt() == 1
    check workspaces[0]["name"].getStr() == "main"
    check workspaces[0]["output"].getStr() == "triad-0"
    check workspaces[0]["active_window_id"].getInt() == 10

    let windows =
      parseJson(handleNiriRequest("\"Windows\"", snapshot).reply)["Ok"][
        "Windows"]
    check windows.len == 1
    check windows[0]["id"].getInt() == 10
    check windows[0]["app_id"].getStr() == "triad-alacritty"
    check windows[0]["raw_app_id"].getStr() == "Alacritty"
    check windows[0]["layout"]["window_size"][0].getInt() == 777
    check windows[0]["layout"]["window_size"][1].getInt() == 555

    let outputs =
      parseJson(handleNiriRequest("\"Outputs\"", snapshot).reply)["Ok"][
        "Outputs"]
    check outputs.hasKey("triad-0")
    check outputs["triad-0"]["logical"]["width"].getInt() == 1920
    check outputs["triad-0"]["logical"]["height"].getInt() == 1080

  test "Niri actions map to Triad messages":
    let snapshot = snapshotForShell()
    let focusWs = handleNiriRequest(
      """{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""",
      snapshot)
    check focusWs.messages.len == 1
    check focusWs.messages[0].kind == CmdFocusWorkspaceIndex
    check focusWs.messages[0].workspaceIndex == 2

    let focusNext =
      handleNiriRequest("""{"Action":{"FocusWorkspaceDown":{}}}""", snapshot)
    check focusNext.messages.len == 1
    check focusNext.messages[0].kind == CmdFocusTag
    check focusNext.messages[0].focusTag == 2

    let closeWin =
      handleNiriRequest("""{"Action":{"CloseWindow":{"id":10}}}""", snapshot)
    check closeWin.messages.len == 1
    check closeWin.messages[0].kind == CmdCloseWindowById
    check closeWin.messages[0].closeWindowId == 10

    let screenshot = handleNiriRequest(
      """{"Action":{"Screenshot":{"path":"/tmp/triad-shot.png"}}}""",
      snapshot)
    check screenshot.messages.len == 1
    check screenshot.messages[0].kind == CmdScreenshot
    check screenshot.messages[0].screenshotKind == ShotRegion
    check screenshot.messages[0].screenshotPath == "/tmp/triad-shot.png"

  test "Triad native reads and layout commands use shell snapshots":
    var snapshot = snapshotForShell()
    snapshot.overviewActive = true

    let stateReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"state"}}""",
        snapshot)
    check stateReply.handled
    let state = parseJson(stateReply.reply)["triad"]["state"]
    check state["overview"]["is_open"].getBool()
    check state["layout"]["active_tag"].getInt() == 1
    check state["outputs"][0]["name"].getStr() == "triad-0"
    check state["windows"][0]["workspace_idx"].getInt() == 1

    let setLayout = handleTriadRequest(
      """{"triad":{"version":1,"request":"set-layout","layout":"deck","target":{"workspace_idx":2}}}""",
      snapshot)
    check parseJson(setLayout.reply)["ok"].getBool()
    check setLayout.messages.len == 1
    check setLayout.messages[0].kind == CmdSetLayout
    check setLayout.messages[0].newLayout == Deck
    check setLayout.messages[0].layoutTargetTag == 2

  test "event streams start with current snapshot state":
    let niri = handleNiriRequest("\"EventStream\"", snapshotForShell())
    check niri.handled
    check niri.subscribe
    check niri.initialEvents.len >= 5
    check parseJson(niri.initialEvents[0]).hasKey("WorkspacesChanged")

    let triad = handleTriadRequest(
      """{"triad":{"version":1,"request":"event-stream","events":["layout","state"]}}""",
      snapshotForShell())
    check triad.subscribeLayout
    check triad.subscribeState
    check triad.initialEvents.len == 2

  test "triad_niri shim parses shell commands":
    let action =
      buildNiriCliRequest(@["msg", "action", "focus-workspace", "2"])
    check action.kind == NckRequest
    let forwarded = handleNiriRequest(action.socketPayload, snapshotForShell())
    check forwarded.messages.len == 1
    check forwarded.messages[0].kind == CmdFocusWorkspaceIndex
    check forwarded.messages[0].workspaceIndex == 2

    let screenshotScreen = buildNiriCliRequest(@[
      "msg", "action", "screenshot-screen", "--path",
      "/tmp/triad-screen.png", "--show-pointer"])
    check screenshotScreen.kind == NckRequest
    let screenshotForwarded =
      handleNiriRequest(screenshotScreen.socketPayload, snapshotForShell())
    check screenshotForwarded.messages[0].kind == CmdScreenshot
    check screenshotForwarded.messages[0].screenshotKind == ShotScreen
    check screenshotForwarded.messages[0].screenshotShowPointer

  test "Quickshell compatibility environment is private":
    let tmp = getTempDir() / ("triad-compat-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeTriadNiri = tmp / "triad_niri"
    writeFile(fakeTriadNiri, "#!/bin/sh\nexit 0\n")
    setFilePermissions(fakeTriadNiri, {fpUserRead, fpUserWrite, fpUserExec})

    let oldDataDirs = getEnv("XDG_DATA_DIRS", "")
    putEnv("XDG_DATA_DIRS", "/custom/share:/usr/share")
    defer:
      putEnv("XDG_DATA_DIRS", oldDataDirs)

    let compat =
      prepareQuickshellCompatEnv(tmp / "niri.sock", tmp, fakeTriadNiri)
    check compat.env["NIRI_SOCKET"] == tmp / "niri.sock"
    check compat.env["TRIAD_SOCKET"] == tmp / "triad.sock"
    check compat.env["XDG_CURRENT_DESKTOP"] == "triad"
    check compat.shimReady
    check compat.overlayReady
    check compat.env["PATH"].startsWith(tmp / "triad-compat-bin")
    check compat.env["XDG_DATA_DIRS"].contains("/custom/share")

  test "Quickshell launch and kill commands target configured theme":
    let config = QuickshellConfig(
      enabled: true,
      command: "qs",
      theme: "noctalia-shell",
      args: @["--verbose"])

    check quickshellLaunchArgs(config) == @[
      "-c", "noctalia-shell", "--verbose"]
    check quickshellKillArgs(config) == @[
      "kill", "-c", "noctalia-shell", "--any-display"]

  test "shell overlay is generated from terminal desktop metadata":
    let tmp = getTempDir() / ("triad-shell-overlay-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let appRoot = tmp / "apps"
    createDir(appRoot)
    writeFile(appRoot / "DemoTerm.desktop", """
[Desktop Entry]
Type=Application
Name=Demo Term
Exec=demo-term --new-window
Icon=demo-term
StartupWMClass=DemoTerm
Categories=System;TerminalEmulator;
""")
    let iconRoot = tmp / "iconsrc"
    createDir(iconRoot / "icons" / "hicolor" / "scalable" / "apps")
    writeFile(
      iconRoot / "icons" / "hicolor" / "scalable" / "apps" /
        "demo-term.svg",
      """<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"/>""")

    let oldDataHome = getEnv("XDG_DATA_HOME", "")
    let oldDataDirs = getEnv("XDG_DATA_DIRS", "")
    putEnv("XDG_DATA_HOME", iconRoot)
    putEnv("XDG_DATA_DIRS", "")
    defer:
      putEnv("XDG_DATA_HOME", oldDataHome)
      putEnv("XDG_DATA_DIRS", oldDataDirs)

    let index = buildAppIdentityIndex([appRoot])
    let overlay = installShellOverlay(tmp / "runtime", index)
    check overlay.ok
    let generatedApp =
      overlay.sharePath / "applications" / "triad-demoterm.desktop"
    check fileExists(generatedApp)
    check readFile(generatedApp).contains("Exec=demo-term --new-window")

  test "text IPC remains Triad-native":
    let msg = parseTextCommand("focus-workspace 2")
    check msg.isSome
    check msg.get().kind == CmdFocusWorkspaceIndex
    check msg.get().workspaceIndex == 2
    check parseTextCommand("mmsg -g -A").isNone
