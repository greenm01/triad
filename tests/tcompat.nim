import unittest, json, options, tables
import ../src/core/model
import ../src/core/model_utils
import ../src/core/msg
import ../src/ipc/commands
import ../src/ipc/niri_cli
import ../src/ipc/niri_compat

proc modelForShell(): Model =
  result = Model(activeTag: 1, screenWidth: 1920, screenHeight: 1080)
  result.tags[1] = initTagState(1, Scroller, "main")
  result.tags[1].columns.add(Column(windows: @[WindowId(10)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, Grid, "web")
  result.windows[10] = WindowData(id: 10, appId: "Alacritty", title: "Terminal")

suite "Shell compatibility contracts":
  test "Noctalia Niri workspace request has the expected shape":
    let response = handleNiriRequest("\"Workspaces\"", modelForShell())
    check response.handled
    check response.reply.len > 0

    let json = parseJson(response.reply)
    let workspaces = json["Ok"]["Workspaces"]
    check workspaces.len == 2
    check workspaces[0]["id"].getInt() == 1
    check workspaces[0]["idx"].getInt() == 1
    check workspaces[0]["name"].getStr() == "main"
    check workspaces[0]["output"].getStr() == "triad-0"
    check workspaces[0]["is_active"].getBool() == true
    check workspaces[0]["is_focused"].getBool() == true
    check workspaces[0]["active_window_id"].getInt() == 10

  test "Noctalia Niri window and output requests have usable fields":
    let model = modelForShell()
    let windows = parseJson(handleNiriRequest("\"Windows\"", model).reply)["Ok"]["Windows"]
    check windows.len == 1
    check windows[0]["id"].getInt() == 10
    check windows[0]["title"].getStr() == "Terminal"
    check windows[0]["app_id"].getStr() == "Alacritty"
    check windows[0]["workspace_id"].getInt() == 1
    check windows[0]["is_focused"].getBool() == true
    check windows[0]["layout"].hasKey("tile_pos_in_workspace_view")

    let outputs = parseJson(handleNiriRequest("\"Outputs\"", model).reply)["Ok"]["Outputs"]
    check outputs.hasKey("triad-0")
    check outputs["triad-0"]["logical"]["width"].getInt() == 1920
    check outputs["triad-0"]["logical"]["height"].getInt() == 1080

  test "Niri output request reflects River output geometry when available":
    var model = modelForShell()
    model.outputs[42] = OutputData(id: 42, x: 100, y: 50, w: 1280, h: 720)
    model.primaryOutput = 42

    let outputs = parseJson(handleNiriRequest("\"Outputs\"", model).reply)["Ok"]["Outputs"]
    check outputs.hasKey("river-42")
    check outputs["river-42"]["logical"]["x"].getInt() == 100
    check outputs["river-42"]["logical"]["y"].getInt() == 50
    check outputs["river-42"]["logical"]["width"].getInt() == 1280
    check outputs["river-42"]["logical"]["height"].getInt() == 720

  test "Niri event stream starts with full state":
    let response = handleNiriRequest("\"EventStream\"", modelForShell())
    check response.handled
    check response.subscribe
    check parseJson(response.reply)["Ok"].hasKey("Handled")
    check response.initialEvents.len >= 5

    var hasWorkspaces = false
    var hasWindows = false
    var hasOutputs = false
    var hasOverview = false
    for event in response.initialEvents:
      let parsed = parseJson(event)
      hasWorkspaces = hasWorkspaces or parsed.hasKey("WorkspacesChanged")
      hasWindows = hasWindows or parsed.hasKey("WindowsChanged")
      hasOutputs = hasOutputs or parsed.hasKey("OutputsChanged")
      hasOverview = hasOverview or parsed.hasKey("OverviewOpenedOrClosed")

    check hasWorkspaces
    check hasWindows
    check hasOutputs
    check hasOverview

  test "Niri actions map to Triad messages":
    let focusWs = handleNiriRequest("""{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""", modelForShell())
    check focusWs.messages.len == 1
    check focusWs.messages[0].kind == CmdFocusTag
    check focusWs.messages[0].focusTag == 2

    let focusWin = handleNiriRequest("""{"Action":{"FocusWindow":{"id":10}}}""", modelForShell())
    check focusWin.messages.len == 1
    check focusWin.messages[0].kind == CmdFocusWindowById
    check focusWin.messages[0].focusWindowId == 10

    let closeWin = handleNiriRequest("""{"Action":{"CloseWindow":{"id":10}}}""", modelForShell())
    check closeWin.messages.len == 1
    check closeWin.messages[0].kind == CmdCloseWindowById
    check closeWin.messages[0].closeWindowId == 10

  test "DankMaterialShell Niri actions are handled":
    let toggleOverview = handleNiriRequest("""{"Action":{"ToggleOverview":{}}}""", modelForShell())
    check toggleOverview.messages.len == 1
    check toggleOverview.messages[0].kind == CmdToggleOverview

    let focusNextWorkspace = handleNiriRequest("""{"Action":{"FocusWorkspaceDown":{}}}""", modelForShell())
    check focusNextWorkspace.messages.len == 1
    check focusNextWorkspace.messages[0].kind == CmdFocusTag
    check focusNextWorkspace.messages[0].focusTag == 2

    let focusPrevColumn = handleNiriRequest("""{"Action":{"FocusColumnLeft":{}}}""", modelForShell())
    check focusPrevColumn.messages.len == 1
    check focusPrevColumn.messages[0].kind == CmdFocusPrev

    let screenshot = handleNiriRequest("""{"Action":{"Screenshot":{"path":"/tmp/triad-shot.png"}}}""", modelForShell())
    check screenshot.handled
    check parseJson(screenshot.reply)["Ok"].hasKey("Handled")
    check screenshot.messages.len == 0

  test "triad_niri shim parses DankMaterialShell shell commands":
    let outputs = buildNiriCliRequest(@["msg", "-j", "outputs"])
    check outputs.kind == NckRequest
    check outputs.socketPayload == "\"Outputs\""
    check outputs.unwrapKey == "Outputs"

    let action = buildNiriCliRequest(@["msg", "action", "focus-workspace", "2"])
    check action.kind == NckRequest
    let forwarded = handleNiriRequest(action.socketPayload, modelForShell())
    check forwarded.messages.len == 1
    check forwarded.messages[0].kind == CmdFocusTag
    check forwarded.messages[0].focusTag == 2

    let validate = buildNiriCliRequest(@["validate"])
    check validate.kind == NckValidate

    let unwrapped = unwrapNiriReply("""{"Ok":{"Outputs":{"triad-0":{"logical":{"scale":1.0}}}}}""", "Outputs")
    check unwrapped.ok
    check parseJson(unwrapped.output).hasKey("triad-0")

  test "text IPC remains Triad-native, not a fake Mango mmsg shell":
    let msg = parseLegacyCommand("focus-workspace 2")
    check msg.isSome
    check msg.get().kind == CmdFocusTag
    check msg.get().focusTag == 2

    check parseLegacyCommand("mmsg -g -A").isNone
