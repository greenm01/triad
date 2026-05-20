import std/[json, options, os, sequtils, strtabs, strutils, unittest]
import ../src/core/app_identity
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/core/msg
import ../src/daemon/quickshell_runner
import
  ../src/ipc/[
    binding_dispatch, command_help, command_registry, commands, niri_cli, niri_compat,
    quickshell_compat, shell_overlay, triad_native,
  ]
import ../src/types/[model, runtime_values, shell_snapshot]
import ../src/utils/behavior_log

proc installAppIdentityFixture() =
  let apps =
    getTempDir() / ("triad-compat-apps-" & $getCurrentProcessId()) / "applications"
  if dirExists(apps.parentDir()):
    removeDir(apps.parentDir())
  createDir(apps)
  writeFile(
    apps / "Alacritty.desktop",
    """
[Desktop Entry]
Name=Alacritty
Exec=alacritty
Icon=Alacritty
Categories=System;TerminalEmulator;
""",
  )
  putEnv("XDG_DATA_HOME", apps.parentDir())
  putEnv("XDG_DATA_DIRS", "")

proc snapshotForShell(): ShellSnapshot =
  ShellSnapshot(
    version: 1,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    layoutCycle: @[LayoutMode.Scroller, LayoutMode.Grid, LayoutMode.Monocle],
    keyboardLayoutNames: @["us", "de"],
    keyboardLayoutIndex: 0,
    workspaces:
      @[
        ShellWorkspace(
          tagId: 1,
          workspaceIdx: 1,
          name: "main",
          layoutMode: LayoutMode.Scroller,
          isActive: true,
          focusedWindow: 10,
          occupied: true,
          outputName: "triad-0",
          columns: @[ShellColumn(idx: 1, widthProportion: 0.5, windows: @[10'u32])],
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
        ShellWorkspace(
          tagId: 2,
          workspaceIdx: 2,
          name: "web",
          layoutMode: LayoutMode.Grid,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
        ShellWorkspace(
          tagId: 3,
          workspaceIdx: 3,
          name: "",
          layoutMode: LayoutMode.Scroller,
          outputName: "triad-0",
          masterCount: 1,
          masterSplitRatio: 0.5,
        ),
      ],
    windows:
      @[
        ShellWindow(
          id: 10,
          parentId: 9,
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
          actualH: 555,
        )
      ],
    outputs:
      @[
        ShellOutput(
          id: 0, name: "triad-0", w: 1920, h: 1080, refreshRate: 144000, isPrimary: true
        )
      ],
  )

proc handleNiriRequest(line: string, snapshot: ShellSnapshot): NiriIpcResult =
  niri_compat.handleNiriRequest(line, snapshot)

proc handleTriadRequest(line: string, snapshot: ShellSnapshot): TriadIpcResult =
  triad_native.handleTriadRequest(line, snapshot)

proc handleTriadAction(action: string, payload: JsonNode): TriadIpcResult =
  var actionPayload =
    %*{"version": TriadIpcVersion, "request": "action", "action": action}
  for key, value in payload:
    actionPayload[key] = value
  handleTriadRequest($(%*{"triad": actionPayload}), snapshotForShell())

proc handleTriadAction(action: string): TriadIpcResult =
  handleTriadAction(action, newJObject())

proc checkTriadActionMatchesText(action, textCommand: string, payload = newJObject()) =
  let actual = handleTriadAction(action, payload)
  let expected = parseTextCommand(textCommand)
  check parseJson(actual.reply)["ok"].getBool()
  check actual.messages.len == 1
  check expected.isSome
  check repr(actual.messages[0]) == repr(expected.get())

proc sampleCommand(
    spec: CommandSpec
): tuple[action: string, textCommand: string, payload: JsonNode] =
  result.action = spec.name
  result.payload = newJObject()
  case spec.argShape
  of CommandArgShape.NoArgs:
    result.textCommand = spec.name
  of CommandArgShape.OptionalWindowId, CommandArgShape.RequiredWindowId:
    result.textCommand = spec.name & " 42"
    result.payload["id"] = %42
  of CommandArgShape.WindowTagFollow:
    result.textCommand = spec.name & " 42 3 true"
    result.payload["id"] = %42
    result.payload["tag"] = %3
    result.payload["follow"] = %true
  of CommandArgShape.WindowWorkspaceFollow:
    result.textCommand = spec.name & " 42 2 true"
    result.payload["id"] = %42
    result.payload["workspace_idx"] = %2
    result.payload["follow"] = %true
  of CommandArgShape.WindowBool:
    result.textCommand = spec.name & " 42 true"
    result.payload["id"] = %42
    result.payload["value"] = %true
  of CommandArgShape.TagLayout:
    result.textCommand = spec.name & " 3 grid"
    result.payload["tag"] = %3
    result.payload["layout"] = %"grid"
  of CommandArgShape.RequiredTag:
    result.textCommand = spec.name & " 3"
    result.payload["tag"] = %3
  of CommandArgShape.RequiredWorkspaceIdx:
    result.textCommand = spec.name & " 2"
    result.payload["workspace_idx"] = %2
  of CommandArgShape.RequiredName:
    result.textCommand = spec.name & " named scratch"
    result.payload["name"] = %"named scratch"
  of CommandArgShape.RequiredOutput:
    result.textCommand = spec.name & " HDMI-A-1"
    result.payload["output"] = %"HDMI-A-1"
  of CommandArgShape.RequiredFloatDelta:
    result.textCommand = spec.name & " -0.25"
    result.payload["delta"] = %(-0.25)
  of CommandArgShape.RequiredFloatValue:
    result.textCommand = spec.name & " 0.75"
    result.payload["value"] = %0.75
  of CommandArgShape.RequiredIntCount:
    result.textCommand = spec.name & " 2"
    result.payload["count"] = %2
  of CommandArgShape.RequiredIntDelta:
    result.textCommand = spec.name & " -1"
    result.payload["delta"] = %(-1)
  of CommandArgShape.OptionalIntDelta:
    result.textCommand = spec.name & " -1"
    result.payload["delta"] = %(-1)
  of CommandArgShape.MoveDelta:
    result.textCommand = spec.name & " 12 -34"
    result.payload["dx"] = %12
    result.payload["dy"] = %(-34)
  of CommandArgShape.ResizeDelta:
    result.textCommand = spec.name & " 12 -34"
    result.payload["dw"] = %12
    result.payload["dh"] = %(-34)
  of CommandArgShape.RecentAdvance:
    result.textCommand = spec.name & " --scope output --filter app-id"
    result.payload["scope"] = %"output"
    result.payload["filter"] = %"app-id"
  of CommandArgShape.RecentScope:
    result.textCommand = spec.name & " workspace"
    result.payload["scope"] = %"workspace"
  of CommandArgShape.SpawnArgv:
    result.textCommand = spec.name & " sh -lc echo"
    result.payload["argv"] = %*["sh", "-lc", "echo"]
  of CommandArgShape.SplitTreeModeList:
    result.textCommand = spec.name & " splith stacking"
    result.payload["argv"] = %*["splith", "stacking"]
  of CommandArgShape.OptionalFloatDelta:
    result.textCommand = spec.name & " 0.05"
    result.payload["delta"] = %0.05
  of CommandArgShape.WarpPointer:
    result.textCommand = spec.name & " 12 34"
    result.payload["x"] = %12
    result.payload["y"] = %34
  of CommandArgShape.Screenshot:
    result.textCommand =
      spec.name & " --path /tmp/triad.png --show-pointer --clipboard-only"
    result.payload["path"] = %"/tmp/triad.png"
    result.payload["show_pointer"] = %true
    result.payload["write_to_disk"] = %false
    result.payload["copy_to_clipboard"] = %true

proc writeFakeRecoveringQs(
    tmp: string
): tuple[fakeQs: string, logPath: string, statePath: string] =
  result.fakeQs = tmp / "qs"
  result.logPath = tmp / "calls.log"
  result.statePath = tmp / "state"
  writeFile(
    result.fakeQs,
    """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_QS_LOG"
if [ "$1" = "kill" ]; then
  exit 0
fi
count=0
if [ -f "$TRIAD_FAKE_QS_STATE" ]; then
  count="$(cat "$TRIAD_FAKE_QS_STATE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$TRIAD_FAKE_QS_STATE"
handoffs="${TRIAD_FAKE_QS_HANDOFFS:-0}"
if [ "$count" -le "$handoffs" ]; then
  exit 0
fi
sleep 30
""",
  )
  setFilePermissions(result.fakeQs, {fpUserRead, fpUserWrite, fpUserExec})

suite "Shell compatibility contracts":
  setup:
    installAppIdentityFixture()

  test "Niri workspace, window, and output reads use shell snapshots":
    let snapshot = snapshotForShell()
    let workspaces =
      parseJson(handleNiriRequest("\"Workspaces\"", snapshot).reply)["Ok"]["Workspaces"]
    check workspaces.len == 1
    check workspaces[0]["id"].getInt() == 1
    check workspaces[0]["idx"].getInt() == 1
    check workspaces[0]["name"].getStr() == "main"
    check workspaces[0]["output"].getStr() == "triad-0"
    check workspaces[0]["active_window_id"].getInt() == 10
    check not workspaces.getElems().anyIt(it["id"].getInt() == 2)
    check not workspaces.getElems().anyIt(it["id"].getInt() == 3)

    let windows =
      parseJson(handleNiriRequest("\"Windows\"", snapshot).reply)["Ok"]["Windows"]
    check windows.len == 1
    check windows[0]["id"].getInt() == 10
    check windows[0]["app_id"].getStr() == "triad-alacritty"
    check windows[0]["raw_app_id"].getStr() == "Alacritty"
    check windows[0]["layout"]["window_size"][0].getInt() == 777
    check windows[0]["layout"]["window_size"][1].getInt() == 555

    let outputs =
      parseJson(handleNiriRequest("\"Outputs\"", snapshot).reply)["Ok"]["Outputs"]
    check outputs.hasKey("triad-0")
    check outputs["triad-0"]["physical_size"].kind == JArray
    check outputs["triad-0"]["physical_size"].len == 2
    check outputs["triad-0"]["logical"]["width"].getInt() == 1920
    check outputs["triad-0"]["logical"]["height"].getInt() == 1080
    check outputs["triad-0"]["refresh_rate"].getInt() == 144000

    let keyboardLayouts = parseJson(
      handleNiriRequest("\"KeyboardLayouts\"", snapshot).reply
    )["Ok"]["KeyboardLayouts"]
    check keyboardLayouts["names"].len == 2
    check keyboardLayouts["names"][0].getStr() == "us"
    check keyboardLayouts["current_idx"].getInt() == 0

    let casts = parseJson(handleNiriRequest("\"Casts\"", snapshot).reply)["Ok"]["Casts"]
    check casts.len == 0

  test "Niri focused window prefers active workspace focus":
    var snapshot = snapshotForShell()
    snapshot.workspaces[0].isActive = false
    snapshot.workspaces[1].isActive = true
    snapshot.activeTag = 2
    snapshot.activeWorkspaceIdx = 2
    snapshot.workspaces[0].focusedWindow = 10
    snapshot.workspaces[1].focusedWindow = 20
    snapshot.windows[0].isFocused = false
    snapshot.windows.add(
      ShellWindow(
        id: 20,
        title: "Browser",
        appId: "brave-browser",
        tagId: some(2'u32),
        workspaceIdx: 2,
        outputName: "triad-0",
        colIdx: 1,
        winIdx: 1,
        widthProportion: 0.5,
        heightProportion: 1.0,
        actualW: 800,
        actualH: 600,
      )
    )

    let focused = parseJson(handleNiriRequest("\"FocusedWindow\"", snapshot).reply)[
      "Ok"
    ]["FocusedWindow"]
    check focused["id"].getInt() == 20
    check focused["workspace_id"].getInt() == 2

  test "Niri event stream exposes one global focused window":
    var snapshot = snapshotForShell()
    snapshot.workspaces[0].isActive = false
    snapshot.workspaces[1].isActive = true
    snapshot.activeTag = 2
    snapshot.activeWorkspaceIdx = 2
    snapshot.workspaces[0].focusedWindow = 10
    snapshot.workspaces[1].focusedWindow = 20
    snapshot.windows[0].isFocused = true
    snapshot.windows.add(
      ShellWindow(
        id: 20,
        title: "Browser",
        appId: "brave-browser",
        tagId: some(2'u32),
        workspaceIdx: 2,
        outputName: "triad-0",
        colIdx: 1,
        winIdx: 1,
        widthProportion: 0.5,
        heightProportion: 1.0,
        actualW: 800,
        actualH: 600,
      )
    )

    let niri = handleNiriRequest("\"Windows\"", snapshot)
    let windows = parseJson(niri.reply)["Ok"]["Windows"]
    check windows.filterIt(it["is_focused"].getBool()).len == 1
    check windows[1]["id"].getInt() == 20
    check windows[1]["workspace_id"].getInt() == 2

  test "Niri actions map to Triad messages":
    let snapshot = snapshotForShell()
    let focusWs = handleNiriRequest(
      """{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""", snapshot
    )
    check focusWs.messages.len == 1
    check focusWs.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex
    check focusWs.messages[0].workspaceIndex == 2
    check focusWs.reply == """{"Ok":"Handled"}"""
    check focusWs.requestKind == "action"
    check focusWs.actionName == "FocusWorkspace"
    check focusWs.workspaceIndex == 2

    let focusNext =
      handleNiriRequest("""{"Action":{"FocusWorkspaceDown":{}}}""", snapshot)
    check focusNext.messages.len == 1
    check focusNext.messages[0].kind == MsgKind.CmdFocusTagRight

    let focusPrevious =
      handleNiriRequest("""{"Action":{"FocusWorkspaceUp":{}}}""", snapshot)
    check focusPrevious.messages.len == 1
    check focusPrevious.messages[0].kind == MsgKind.CmdFocusTagLeft

    var overviewSnapshot = snapshot
    overviewSnapshot.overviewActive = true
    overviewSnapshot.overviewSelectedWindow = 10

    let overviewFocusNext =
      handleNiriRequest("""{"Action":{"FocusWorkspaceDown":{}}}""", overviewSnapshot)
    check overviewFocusNext.messages.len == 1
    check overviewFocusNext.messages[0].kind == MsgKind.CmdFocusTagRight

    let overviewFocusPrevious =
      handleNiriRequest("""{"Action":{"FocusWorkspaceUp":{}}}""", overviewSnapshot)
    check overviewFocusPrevious.messages.len == 1
    check overviewFocusPrevious.messages[0].kind == MsgKind.CmdFocusTagLeft

    let overviewFocusWorkspace = handleNiriRequest(
      """{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""", overviewSnapshot
    )
    check overviewFocusWorkspace.messages.len == 1
    check overviewFocusWorkspace.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex
    check overviewFocusWorkspace.messages[0].workspaceIndex == 2

    let closeWin =
      handleNiriRequest("""{"Action":{"CloseWindow":{"id":10}}}""", snapshot)
    check closeWin.messages.len == 1
    check closeWin.messages[0].kind == MsgKind.CmdCloseWindowById
    check closeWin.messages[0].closeWindowId == 10

    let spawn = handleNiriRequest(
      """{"Action":{"Spawn":{"command":["foot","-e","htop"]}}}""", snapshot
    )
    check spawn.messages.len == 1
    check spawn.messages[0].kind == MsgKind.CmdSpawn
    check spawn.messages[0].spawnCommand == @["foot", "-e", "htop"]

    let spawnSh = handleNiriRequest(
      """{"Action":{"SpawnSh":{"command":"notify-send triad"}}}""", snapshot
    )
    check spawnSh.messages.len == 1
    check spawnSh.messages[0].kind == MsgKind.CmdSpawn
    check spawnSh.messages[0].spawnCommand == @["sh", "-c", "notify-send triad"]

    let switchKeyboardLayout =
      handleNiriRequest("""{"Action":{"SwitchLayout":{"layout":"Next"}}}""", snapshot)
    check switchKeyboardLayout.messages.len == 1
    check switchKeyboardLayout.messages[0].kind == MsgKind.CmdSwitchKeyboardLayout
    check switchKeyboardLayout.messages[0].keyboardLayoutDelta == 1
    check switchKeyboardLayout.messages[0].keyboardLayoutIndex == -1
    check parseJson(switchKeyboardLayout.reply).hasKey("Ok")

    let powerOffMonitors =
      handleNiriRequest("""{"Action":{"PowerOffMonitors":{}}}""", snapshot)
    check powerOffMonitors.messages.len == 0
    check parseJson(powerOffMonitors.reply).hasKey("Ok")

    let reorderWorkspace = handleNiriRequest(
      """{"Action":{"MoveWorkspaceToIndex":{"index":2,"reference":{"Index":1}}}}""",
      snapshot,
    )
    check reorderWorkspace.messages.len == 1
    check reorderWorkspace.messages[0].kind == MsgKind.CmdReorderWorkspaceIndex
    check reorderWorkspace.messages[0].reorderWorkspaceIndex == 1
    check reorderWorkspace.messages[0].reorderTargetIndex == 2

    let maximizeColumn =
      handleNiriRequest("""{"Action":{"MaximizeColumn":{}}}""", snapshot)
    check maximizeColumn.messages.len == 1
    check maximizeColumn.messages[0].kind == MsgKind.CmdMaximizeColumn

    let maximizeToEdges =
      handleNiriRequest("""{"Action":{"MaximizeWindowToEdges":{}}}""", snapshot)
    check maximizeToEdges.messages.len == 1
    check maximizeToEdges.messages[0].kind == MsgKind.WlWindowMaximizeRequested
    check maximizeToEdges.messages[0].maximizeRequestId == 10

    var maximizedSnapshot = snapshot
    maximizedSnapshot.windows[0].isMaximized = true
    let unmaximizeToEdges = handleNiriRequest(
      """{"Action":{"MaximizeWindowToEdges":{}}}""", maximizedSnapshot
    )
    check unmaximizeToEdges.messages.len == 1
    check unmaximizeToEdges.messages[0].kind == MsgKind.WlWindowUnmaximizeRequested
    check unmaximizeToEdges.messages[0].unmaximizeRequestId == 10

    let screenshot = handleNiriRequest(
      """{"Action":{"Screenshot":{"path":"/tmp/triad-shot.png"}}}""", snapshot
    )
    check screenshot.messages.len == 1
    check screenshot.messages[0].kind == MsgKind.CmdScreenshot
    check screenshot.messages[0].screenshotKind == ScreenshotKind.ShotRegion
    check screenshot.messages[0].screenshotPath == "/tmp/triad-shot.png"
    check screenshot.messages[0].screenshotPointerMode ==
      ScreenshotPointerMode.PointerShow
    check screenshot.messages[0].screenshotWriteToDisk
    check screenshot.messages[0].screenshotCopyToClipboard

    let screenshotClipboardOnly = handleNiriRequest(
      """{"Action":{"ScreenshotScreen":{"write-to-disk":false}}}""", snapshot
    )
    check screenshotClipboardOnly.messages.len == 1
    check screenshotClipboardOnly.messages[0].screenshotKind == ScreenshotKind.ShotScreen
    check not screenshotClipboardOnly.messages[0].screenshotWriteToDisk
    check screenshotClipboardOnly.messages[0].screenshotCopyToClipboard
    check screenshotClipboardOnly.messages[0].screenshotPointerMode ==
      ScreenshotPointerMode.PointerShow

    let screenshotWindow =
      handleNiriRequest("""{"Action":{"ScreenshotWindow":{}}}""", snapshot)
    check screenshotWindow.messages.len == 1
    check screenshotWindow.messages[0].screenshotKind == ScreenshotKind.ShotWindow
    check screenshotWindow.messages[0].screenshotPointerMode ==
      ScreenshotPointerMode.PointerHide

    let quitConfirm = handleNiriRequest("""{"Action":{"Quit":{}}}""", snapshot)
    check quitConfirm.messages.len == 1
    check quitConfirm.messages[0].kind == MsgKind.CmdExitSession

    let quitImmediate =
      handleNiriRequest("""{"Action":{"Quit":{"skip_confirmation":true}}}""", snapshot)
    check quitImmediate.messages.len == 1
    check quitImmediate.messages[0].kind == MsgKind.CmdExitSessionImmediate

  test "Triad native reads and layout commands use shell snapshots":
    var snapshot = snapshotForShell()
    snapshot.overviewActive = true
    snapshot.customLayouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("notion"),
          fallback: nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
        )
      ]
    snapshot.layoutCycleSelections =
      @[
        builtinSelection(LayoutMode.Scroller),
        customSelection(
          janetLayoutId("notion"),
          nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
        ),
      ]

    let stateReply =
      handleTriadRequest("""{"triad":{"version":1,"request":"state"}}""", snapshot)
    check stateReply.handled
    let state = parseJson(stateReply.reply)["triad"]["state"]
    check state["overview"]["is_open"].getBool()
    check state["layout"]["active_tag"].getInt() == 1
    check state["outputs"][0]["name"].getStr() == "triad-0"
    check state["windows"][0]["workspace_idx"].getInt() == 1
    check state["windows"][0]["parent_id"].getInt() == 9

    let setLayout = handleTriadRequest(
      """{"triad":{"version":1,"request":"set-layout","layout":"deck","target":{"workspace_idx":2}}}""",
      snapshot,
    )
    check parseJson(setLayout.reply)["ok"].getBool()
    check setLayout.messages.len == 1
    check setLayout.messages[0].kind == MsgKind.CmdSetCustomLayout
    check setLayout.messages[0].customLayout.layoutIdString() == "deck"
    check setLayout.messages[0].customLayoutTargetTag == 2

    let setTGMix = handleTriadRequest(
      """{"triad":{"version":1,"request":"set-layout","layout":"tgmix"}}""", snapshot
    )
    check parseJson(setTGMix.reply)["ok"].getBool()
    check setTGMix.messages.len == 1
    check setTGMix.messages[0].kind == MsgKind.CmdSetCustomLayout
    check setTGMix.messages[0].customLayout.layoutIdString() == "tgmix"

    let layoutStateReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"layout-state"}}""", snapshot
    )
    let layoutState = parseJson(layoutStateReply.reply)["triad"]["state"]
    check layoutState["layouts"].getElems().anyIt(
      it["kind"].getStr() == "custom" and it["id"].getStr() == "notion" and
        it["fallback_layout"].getStr() == "frame-tree"
    )
    check layoutState["layout_cycle_entries"].getElems().anyIt(
      it["kind"].getStr() == "custom" and it["id"].getStr() == "notion" and
        it["fallback_layout"].getStr() == "frame-tree"
    )

    let commandsReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"commands"}}""", snapshotForShell()
    )
    check parseJson(commandsReply.reply)["ok"].getBool()
    let catalog = parseJson(commandsReply.reply)["triad"]["catalog"]
    check catalog["commands"].getElems().anyIt(it["name"].getStr() == "focus-next")
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "layout-state"
    )

    let dispatchReply = handleTriadRequest(
      """{"triad":{"version":1,"request":"dispatch-binding","kind":"key","binding":"Super+h"}}""",
      snapshotForShell(),
    )
    check dispatchReply.bindingDispatch.isSome
    check dispatchReply.bindingDispatch.get().kind == BindingDispatchKind.BindKey
    check dispatchReply.bindingDispatch.get().binding == "Super+h"

  test "Triad command registry has unique resolvable action names":
    var seen: seq[string] = @[]
    for name in allCommandNames():
      check name.len > 0
    for spec in CommandSpecs:
      check spec.name notin seen
      seen.add(spec.name)
      let canonical = resolveCommandSpec(spec.name)
      check canonical.isSome
      check canonical.get().id == spec.id
      if spec.aliases.len > 0:
        for alias in spec.aliases.split('|'):
          check alias notin seen
          seen.add(alias)
          let resolved = resolveCommandSpec(alias)
          check resolved.isSome
          check resolved.get().id == spec.id

  test "Triad msg help and catalog are generated from command registry":
    let help = renderMsgHelp()
    check help.contains("triad msg validate <command...>")
    check help.contains("focus-next")
    check help.contains("triad msg state")
    check help.contains("triad msg dispatch-binding")
    check help.contains("triad msg mem-status")

    let topHelp = renderTriadHelp()
    check topHelp.contains("validate-config")
    check topHelp.contains("triad msg --help")

    let focusHelp = renderMsgHelp("focus-workspace")
    check focusHelp.contains("Usage: triad msg focus-workspace <workspace-idx>")
    check focusHelp.contains("required-workspace-idx")

    let aliasHelp = renderMsgHelp("toggle-fullscreen")
    check aliasHelp.contains("fullscreen-window [window-id]")
    check aliasHelp.contains("toggle-fullscreen")

    let catalog = commandCatalogJson()
    check catalog["commands"].len == CommandSpecs.len
    check catalog["commands"].getElems().anyIt(
      it["name"].getStr() == "focus-next" and it["arg_shape"].getStr() == "none"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "state" and it["usage"].getStr() == "triad msg state"
    )
    check catalog["special_requests"].getElems().anyIt(
      it["name"].getStr() == "mem-status" and
        it["usage"].getStr() == "triad msg mem-status"
    )

    check triadMsgRequestPayload("state").isSome
    let dispatchPayload =
      triadMsgRequestPayload("dispatch-binding axis Super+wheel-up 2")
    check dispatchPayload.isSome
    check parseJson(dispatchPayload.get())["triad"]["request"].getStr() ==
      "dispatch-binding"
    check parseBindingDispatchText("dispatch-binding gesture Super+swipe-left 3")
    .get().fingers == 3'u32
    let stream = parseJson(nativeEventStreamPayload(@["layout"]))
    check stream["triad"]["request"].getStr() == "event-stream"
    check stream["triad"]["events"][0].getStr() == "layout"

    let docs =
      readFile("docs/ipc.md") & "\n" & readFile("docs/comp/config-command-matrix.md")
    let commandList = renderCommandList()
    for spec in CommandSpecs:
      check commandList.contains(spec.name) or docs.contains(spec.name)

  test "Triad native actions mirror text IPC commands":
    for spec in CommandSpecs:
      let sample = sampleCommand(spec)
      checkTriadActionMatchesText(sample.action, sample.textCommand, sample.payload)
      if spec.aliases.len > 0:
        for alias in spec.aliases.split('|'):
          checkTriadActionMatchesText(alias, sample.textCommand, sample.payload)

    let badAction = handleTriadAction("spawn", %*{"argv": []})
    check not parseJson(badAction.reply)["ok"].getBool()
    check badAction.messages.len == 0

    let badWindowId = handleTriadAction("focus-window", %*{"id": "bad"})
    check not parseJson(badWindowId.reply)["ok"].getBool()
    check badWindowId.messages.len == 0

    let badScreenshot = handleTriadAction(
      "screenshot", %*{"write_to_disk": false, "copy_to_clipboard": false}
    )
    check not parseJson(badScreenshot.reply)["ok"].getBool()
    check badScreenshot.messages.len == 0

  test "event streams start with current snapshot state":
    let niri = handleNiriRequest("\"EventStream\"", snapshotForShell())
    check niri.handled
    check niri.subscribe
    check niri.reply == """{"Ok":"Handled"}"""
    check niri.initialEvents.len > 0
    let niriWorkspaces = parseJson(niri.initialEvents[0])
    check niriWorkspaces.hasKey("WorkspacesChanged")
    check niriWorkspaces["WorkspacesChanged"]["workspaces"].len > 0

    let triad = handleTriadRequest(
      """{"triad":{"version":1,"request":"event-stream","events":["layout","state"]}}""",
      snapshotForShell(),
    )
    check triad.subscribeLayout
    check triad.subscribeState
    check triad.initialEvents.len == 2

  test "triad_niri shim parses shell commands":
    let action = buildNiriCliRequest(@["msg", "action", "focus-workspace", "2"])
    check action.kind == NiriCliKind.NckRequest
    let forwarded = handleNiriRequest(action.socketPayload, snapshotForShell())
    check forwarded.messages.len == 1
    check forwarded.messages[0].kind == MsgKind.CmdFocusWorkspaceIndex
    check forwarded.messages[0].workspaceIndex == 2

    let maximizeColumn = buildNiriCliRequest(@["msg", "action", "maximize-column"])
    check maximizeColumn.kind == NiriCliKind.NckRequest
    check handleNiriRequest(maximizeColumn.socketPayload, snapshotForShell()).messages[
      0
    ].kind == MsgKind.CmdMaximizeColumn

    let screenshotScreen = buildNiriCliRequest(
      @[
        "msg", "action", "screenshot-screen", "--path", "/tmp/triad-screen.png",
        "--show-pointer",
      ]
    )
    check screenshotScreen.kind == NiriCliKind.NckRequest
    let screenshotForwarded =
      handleNiriRequest(screenshotScreen.socketPayload, snapshotForShell())
    check screenshotForwarded.messages[0].kind == MsgKind.CmdScreenshot
    check screenshotForwarded.messages[0].screenshotKind == ScreenshotKind.ShotScreen
    check screenshotForwarded.messages[0].screenshotPointerMode ==
      ScreenshotPointerMode.PointerShow
    check screenshotForwarded.messages[0].screenshotWriteToDisk

    let quit = buildNiriCliRequest(@["msg", "action", "quit", "--skip-confirmation"])
    check quit.kind == NiriCliKind.NckRequest
    let quitForwarded = handleNiriRequest(quit.socketPayload, snapshotForShell())
    check quitForwarded.messages.len == 1
    check quitForwarded.messages[0].kind == MsgKind.CmdExitSessionImmediate

    let spawn =
      buildNiriCliRequest(@["msg", "action", "spawn", "--", "foot", "-e", "htop"])
    check spawn.kind == NiriCliKind.NckRequest
    let spawnForwarded = handleNiriRequest(spawn.socketPayload, snapshotForShell())
    check spawnForwarded.messages.len == 1
    check spawnForwarded.messages[0].kind == MsgKind.CmdSpawn
    check spawnForwarded.messages[0].spawnCommand == @["foot", "-e", "htop"]

    let casts = buildNiriCliRequest(@["msg", "-j", "casts"])
    check casts.kind == NiriCliKind.NckRequest
    let castsForwarded = handleNiriRequest(casts.socketPayload, snapshotForShell())
    check parseJson(castsForwarded.reply)["Ok"]["Casts"].len == 0

    let eventStream = buildNiriCliRequest(@["msg", "--json", "event-stream"])
    check eventStream.kind == NiriCliKind.NckRequest
    check eventStream.stream
    check eventStream.socketPayload == "\"EventStream\""

    let outputMutation =
      buildNiriCliRequest(@["msg", "output", "DP-1", "scale", "1.25"])
    check outputMutation.kind == NiriCliKind.NckInvalid
    check outputMutation.error.contains("output mutation")

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

    let compat = prepareQuickshellCompatEnv(tmp / "niri.sock", tmp, fakeTriadNiri)
    check compat.env["NIRI_SOCKET"] == tmp / "niri.sock"
    check compat.env["TRIAD_SOCKET"] == tmp / "triad.sock"
    check compat.env["XDG_CURRENT_DESKTOP"] == "triad"
    check compat.shimReady
    check compat.overlayReady
    check compat.env["PATH"].startsWith(tmp / "triad-compat-bin")
    check compat.env["XDG_DATA_DIRS"].contains("/custom/share")

  test "Quickshell compatibility environment starts from configured env":
    let tmp = getTempDir() / ("triad-compat-config-env-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeTriadNiri = tmp / "triad_niri"
    writeFile(fakeTriadNiri, "#!/bin/sh\nexit 0\n")
    setFilePermissions(fakeTriadNiri, {fpUserRead, fpUserWrite, fpUserExec})

    let base = newStringTable(modeCaseSensitive)
    base["PATH"] = "/configured/bin"
    base["XDG_DATA_DIRS"] = "/configured/share"
    base["XDG_CURRENT_DESKTOP"] = "wrong"
    base["CUSTOM_TRIAD_ENV"] = "kept"

    let compat =
      prepareQuickshellCompatEnv(tmp / "niri.sock", tmp, fakeTriadNiri, baseEnv = base)
    check compat.env["CUSTOM_TRIAD_ENV"] == "kept"
    check compat.env["XDG_CURRENT_DESKTOP"] == "triad"
    check compat.env["PATH"].startsWith(tmp / "triad-compat-bin")
    check compat.env["PATH"].contains("/configured/bin")
    check compat.env["XDG_DATA_DIRS"].startsWith(compat.xdgSharePath)
    check compat.env["XDG_DATA_DIRS"].contains("/configured/share")

  test "Quickshell launch and kill commands target configured theme":
    let config = QuickshellConfig(
      enabled: true, command: "qs", theme: "noctalia-shell", args: @["--verbose"]
    )

    check quickshellLaunchArgs(config) == @["-c", "noctalia-shell", "--verbose"]
    check quickshellKillArgs(config) ==
      @["kill", "-c", "noctalia-shell", "--any-display"]

  test "Quickshell lifecycle actions avoid reload handoff kills":
    let noctalia = QuickshellConfig(
      enabled: true, command: "qs", theme: "noctalia-shell", args: @["--verbose"]
    )
    var changedTheme = noctalia
    changedTheme.theme = "other-shell"
    var disabled = noctalia
    disabled.enabled = false

    check quickshellStartupAction(noctalia) == QuickshellReloadAction.SpawnOnly
    check quickshellConfigReloadAction(noctalia, noctalia) == QuickshellReloadAction.Noop
    check quickshellConfigReloadAction(noctalia, changedTheme) ==
      QuickshellReloadAction.AuthoritativeRestart
    check quickshellConfigReloadAction(noctalia, disabled) ==
      QuickshellReloadAction.AuthoritativeStop

  test "Shell switching stops old profile before launching new profile":
    let tmp = getTempDir() / ("triad-shell-switch-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fake,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
exit 0
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)

    let previous = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "old",
        profiles:
          @[
            ShellProfileConfig(
              name: "old", launch: @[fake, "launch-old"], stop: @[fake, "stop-old"]
            ),
            ShellProfileConfig(
              name: "new", launch: @[fake, "launch-new"], stop: @[fake, "stop-new"]
            ),
          ],
      )
    )
    let current = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "new",
        profiles: previous.shells.profiles,
      )
    )

    var runner = QuickshellRunner()
    runner.switchShell(previous, current, tmp / "niri.sock", "test switch")
    let calls = readFile(logPath).splitLines().filterIt(it.len > 0)
    check calls == @["stop-old", "launch-new"]

  test "Shell profile Niri compatibility logs shim readiness":
    let tmp = getTempDir() / ("triad-shell-niri-log-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeShell = tmp / "fake-shell"
    writeFile(fakeShell, "#!/bin/sh\nsleep 5\n")
    setFilePermissions(fakeShell, {fpUserRead, fpUserWrite, fpUserExec})

    let fakeTriadNiri = tmp / "triad_niri"
    writeFile(fakeTriadNiri, "#!/bin/sh\nexit 0\n")
    setFilePermissions(fakeTriadNiri, {fpUserRead, fpUserWrite, fpUserExec})

    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    let oldPath = getEnv("PATH", "")
    let oldRuntimeDir = getEnv("XDG_RUNTIME_DIR", "")
    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", tmp / "behavior")
    putEnv("PATH", tmp & $PathSep & oldPath)
    putEnv("XDG_RUNTIME_DIR", tmp)
    defer:
      putEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      putEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      putEnv("PATH", oldPath)
      putEnv("XDG_RUNTIME_DIR", oldRuntimeDir)

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "noctalia",
        profiles:
          @[
            ShellProfileConfig(name: "noctalia", launch: @[fakeShell], niriCompat: true)
          ],
      )
    )
    var runner = QuickshellRunner()
    defer:
      runner.stopTrackedQuickshell("test cleanup")

    runner.switchShell(Model(), model, tmp / "niri.sock", "test spawn")

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    let spawned =
      lines.mapIt(parseJson(it)).filterIt(it["event"].getStr() == "shell_spawned")
    check spawned.len == 1
    check spawned[0]["profile"].getStr() == "noctalia"
    check spawned[0]["niri_socket"].getStr() == tmp / "niri.sock"
    check spawned[0]["shim_ready"].getBool()
    check spawned[0]["overlay_ready"].getBool()
    check spawned[0]["compat_bin"].getStr() == tmp / "triad-compat-bin"
    check spawned[0]["niri_shim"].getStr() == tmp / "triad-compat-bin" / "niri"

  test "Shell watchdog falls back when active tracked shell exits":
    let tmp = getTempDir() / ("triad-shell-watchdog-exit-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    writeFile(
      fake,
      """
#!/bin/sh
if [ "$1" = "launch-dank" ]; then
  sleep 1
  exit 7
fi
sleep 5
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "dank",
        cycle: @["waybar", "dank"],
        watchdog: ShellWatchdogConfig(
          enabled: true, fallback: "waybar", exclusiveFocusTimeoutMs: 30000
        ),
        profiles:
          @[
            ShellProfileConfig(
              name: "dank", launch: @[fake, "launch-dank"], stop: @[fake, "stop-dank"]
            ),
            ShellProfileConfig(name: "waybar", launch: @[fake, "launch-waybar"]),
          ],
      )
    )
    var runner = QuickshellRunner()
    runner.switchShell(Model(), model, tmp / "niri.sock", "test spawn")
    check runner.trackedQuickshellRunning()

    sleep(1200)
    let fallback = runner.pollShellWatchdog(model, 2000)
    check fallback.isSome
    check fallback.get() == "waybar"
    check runner.trackedProcess == nil

  test "Shell watchdog falls back after exclusive layer focus timeout":
    let model = Model(
      layerFocusExclusive: true,
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "dank",
        watchdog: ShellWatchdogConfig(
          enabled: true, fallback: "waybar", exclusiveFocusTimeoutMs: 10
        ),
        profiles:
          @[
            ShellProfileConfig(name: "dank", launch: @["dms", "run"]),
            ShellProfileConfig(name: "waybar", launch: @["waybar"]),
          ],
      ),
    )
    var runner = QuickshellRunner()
    check runner.pollShellWatchdog(model, 1000).isNone
    let fallback = runner.pollShellWatchdog(model, 1011)
    check fallback.isSome
    check fallback.get() == "waybar"

  test "Shell startup stops stale configured profiles before active launch":
    let tmp = getTempDir() / ("triad-shell-startup-cleanup-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = tmp / "fake-shell"
    let logPath = tmp / "calls.log"
    writeFile(
      fake,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_SHELL_LOG"
if [ "$1" = "launch-noctalia" ]; then
  sleep 5
fi
exit 0
""",
    )
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_SHELL_LOG", "")
    putEnv("TRIAD_FAKE_SHELL_LOG", logPath)
    defer:
      putEnv("TRIAD_FAKE_SHELL_LOG", oldLog)

    let model = Model(
      shells: ShellsConfig(
        configured: true,
        enabled: true,
        active: "noctalia",
        profiles:
          @[
            ShellProfileConfig(
              name: "noctalia",
              launch: @[fake, "launch-noctalia"],
              stop: @[fake, "stop-noctalia"],
            ),
            ShellProfileConfig(
              name: "waybar", launch: @[fake], stop: @[fake, "stop-waybar"]
            ),
            ShellProfileConfig(
              name: "dank", launch: @[fake], stop: @[fake, "stop-dank"]
            ),
          ],
      )
    )
    var runner = QuickshellRunner(spawnPending: true)
    defer:
      runner.stopTrackedQuickshell("test cleanup")

    runner.spawnPendingQuickshell(model, tmp / "niri.sock", "initial manage")

    let calls = readFile(logPath).splitLines().filterIt(it.len > 0)
    check calls == @["stop-noctalia", "stop-waybar", "stop-dank", "launch-noctalia"]

  test "Quickshell unchanged reload can recover untracked shell":
    let noctalia =
      QuickshellConfig(enabled: true, command: "qs", theme: "noctalia-shell")
    var runner = QuickshellRunner()
    check runner.needsQuickshellRecovery(Model(quickshell: noctalia))

    var disabled = Model(quickshell: noctalia)
    disabled.quickshell.enabled = false
    check not runner.needsQuickshellRecovery(disabled)

  test "Quickshell spawn handoff refreshes configured shell":
    let tmp = getTempDir() / ("triad-qs-handoff-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeQs = tmp / "qs"
    let logPath = tmp / "calls.log"
    writeFile(
      fakeQs,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_QS_LOG"
if [ "$1" = "kill" ]; then
  exit 0
fi
exit "${TRIAD_FAKE_QS_EXIT:-0}"
""",
    )
    setFilePermissions(fakeQs, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_QS_LOG", "")
    let oldExit = getEnv("TRIAD_FAKE_QS_EXIT", "")
    putEnv("TRIAD_FAKE_QS_LOG", logPath)
    putEnv("TRIAD_FAKE_QS_EXIT", "0")
    defer:
      putEnv("TRIAD_FAKE_QS_LOG", oldLog)
      putEnv("TRIAD_FAKE_QS_EXIT", oldExit)

    let config =
      QuickshellConfig(enabled: true, command: fakeQs, theme: "noctalia-shell")
    var runner = QuickshellRunner(spawnPending: true)
    let model = Model(quickshell: config)

    runner.spawnPendingQuickshell(model, tmp / "niri.sock", "test")

    let calls = readFile(logPath)
    check calls.contains("-c noctalia-shell")
    check calls.contains("kill -c noctalia-shell --any-display")
    check calls.count("-c noctalia-shell") >= 2

  test "Quickshell double handoff schedules recovery until tracked":
    let tmp = getTempDir() / ("triad-qs-recovery-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringQs(tmp)

    let oldLog = getEnv("TRIAD_FAKE_QS_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_QS_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_QS_HANDOFFS", "")
    putEnv("TRIAD_FAKE_QS_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_QS_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_QS_HANDOFFS", "2")
    defer:
      putEnv("TRIAD_FAKE_QS_LOG", oldLog)
      putEnv("TRIAD_FAKE_QS_STATE", oldState)
      putEnv("TRIAD_FAKE_QS_HANDOFFS", oldHandoffs)

    let config =
      QuickshellConfig(enabled: true, command: fake.fakeQs, theme: "noctalia-shell")
    var runner = QuickshellRunner(spawnPending: true)
    let model = Model(quickshell: config)
    defer:
      runner.stopTrackedQuickshell("test cleanup")

    runner.spawnPendingQuickshell(model, tmp / "niri.sock", "test")

    check runner.recoveryPending
    check runner.recoveryAttempts == 0
    check readFile(fake.statePath).strip() == "2"

    runner.nextRecoveryMs = 0
    check runner.pollQuickshellRecovery(model, tmp / "niri.sock", 0)
    check not runner.recoveryPending
    check runner.trackedQuickshellRunning()
    check readFile(fake.statePath).strip() == "3"

    let calls = readFile(fake.logPath)
    check calls.count("kill -c noctalia-shell --any-display") >= 2

  test "Quickshell recovery exhausts repeated handoffs":
    let tmp = getTempDir() / ("triad-qs-recovery-exhaust-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringQs(tmp)

    let oldLog = getEnv("TRIAD_FAKE_QS_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_QS_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_QS_HANDOFFS", "")
    putEnv("TRIAD_FAKE_QS_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_QS_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_QS_HANDOFFS", "99")
    defer:
      putEnv("TRIAD_FAKE_QS_LOG", oldLog)
      putEnv("TRIAD_FAKE_QS_STATE", oldState)
      putEnv("TRIAD_FAKE_QS_HANDOFFS", oldHandoffs)

    let config =
      QuickshellConfig(enabled: true, command: fake.fakeQs, theme: "noctalia-shell")
    var runner = QuickshellRunner(spawnPending: true)
    let model = Model(quickshell: config)

    runner.spawnPendingQuickshell(model, tmp / "niri.sock", "test")
    check runner.recoveryPending

    for attempt in 1 .. MaxQuickshellRecoveryAttempts:
      runner.nextRecoveryMs = 0
      check runner.pollQuickshellRecovery(model, tmp / "niri.sock", 0)
      if attempt < MaxQuickshellRecoveryAttempts:
        check runner.recoveryPending
        check runner.recoveryAttempts == attempt
      else:
        check not runner.recoveryPending

    check readFile(fake.statePath).strip() == "5"
    let calls = readFile(fake.logPath)
    check calls.count("kill -c noctalia-shell --any-display") >= 4

  test "Quickshell config reload handoff schedules recovery":
    let tmp = getTempDir() / ("triad-qs-config-recovery-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fake = writeFakeRecoveringQs(tmp)

    let oldLog = getEnv("TRIAD_FAKE_QS_LOG", "")
    let oldState = getEnv("TRIAD_FAKE_QS_STATE", "")
    let oldHandoffs = getEnv("TRIAD_FAKE_QS_HANDOFFS", "")
    putEnv("TRIAD_FAKE_QS_LOG", fake.logPath)
    putEnv("TRIAD_FAKE_QS_STATE", fake.statePath)
    putEnv("TRIAD_FAKE_QS_HANDOFFS", "1")
    defer:
      putEnv("TRIAD_FAKE_QS_LOG", oldLog)
      putEnv("TRIAD_FAKE_QS_STATE", oldState)
      putEnv("TRIAD_FAKE_QS_HANDOFFS", oldHandoffs)

    let config =
      QuickshellConfig(enabled: true, command: fake.fakeQs, theme: "noctalia-shell")
    var runner = QuickshellRunner()
    let model = Model(quickshell: config)
    defer:
      runner.stopTrackedQuickshell("test cleanup")

    let status =
      runner.spawnQuickshell(model, tmp / "niri.sock", "config reload recovery")
    check status == QuickshellSpawnStatus.Handoff

    runner.scheduleQuickshellRecovery(model, "config reload recovery", status, 1000)
    check runner.recoveryPending
    check runner.nextRecoveryMs == 1500

    runner.nextRecoveryMs = 0
    check runner.pollQuickshellRecovery(model, tmp / "niri.sock", 0)
    check not runner.recoveryPending
    check runner.trackedQuickshellRunning()
    check readFile(fake.statePath).strip() == "2"

  test "Quickshell failed spawn kills stale configured shell":
    let tmp = getTempDir() / ("triad-qs-failed-" & $getCurrentProcessId())
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    defer:
      if dirExists(tmp):
        removeDir(tmp)

    let fakeQs = tmp / "qs"
    let logPath = tmp / "calls.log"
    writeFile(
      fakeQs,
      """
#!/bin/sh
printf '%s\n' "$*" >> "$TRIAD_FAKE_QS_LOG"
if [ "$1" = "kill" ]; then
  exit 0
fi
exit "${TRIAD_FAKE_QS_EXIT:-9}"
""",
    )
    setFilePermissions(fakeQs, {fpUserRead, fpUserWrite, fpUserExec})

    let oldLog = getEnv("TRIAD_FAKE_QS_LOG", "")
    let oldExit = getEnv("TRIAD_FAKE_QS_EXIT", "")
    putEnv("TRIAD_FAKE_QS_LOG", logPath)
    putEnv("TRIAD_FAKE_QS_EXIT", "9")
    defer:
      putEnv("TRIAD_FAKE_QS_LOG", oldLog)
      putEnv("TRIAD_FAKE_QS_EXIT", oldExit)

    let config =
      QuickshellConfig(enabled: true, command: fakeQs, theme: "noctalia-shell")
    var runner = QuickshellRunner(spawnPending: true)
    let model = Model(quickshell: config)

    runner.spawnPendingQuickshell(model, tmp / "niri.sock", "test")

    let calls = readFile(logPath)
    check calls.contains("-c noctalia-shell")
    check calls.contains("kill -c noctalia-shell --any-display")

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
    writeFile(
      appRoot / "DemoTerm.desktop",
      """
[Desktop Entry]
Type=Application
Name=Demo Term
Exec=demo-term --new-window
Icon=demo-term
StartupWMClass=DemoTerm
Categories=System;TerminalEmulator;
""",
    )
    let iconRoot = tmp / "iconsrc"
    createDir(iconRoot / "icons" / "hicolor" / "scalable" / "apps")
    writeFile(
      iconRoot / "icons" / "hicolor" / "scalable" / "apps" / "demo-term.svg",
      """<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"/>""",
    )

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
    let generatedApp = overlay.sharePath / "applications" / "triad-demoterm.desktop"
    check fileExists(generatedApp)
    check readFile(generatedApp).contains("Exec=demo-term --new-window")

  test "text IPC remains Triad-native":
    let msg = parseTextCommand("focus-workspace 2")
    check msg.isSome
    check msg.get().kind == MsgKind.CmdFocusWorkspaceIndex
    check msg.get().workspaceIndex == 2
    check parseTextCommand("mmsg -g -A").isNone
