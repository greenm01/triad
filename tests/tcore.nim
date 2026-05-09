import json, options, sequtils, strutils, tables, unittest
import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/render_visibility
import ../src/core/restore_state
import ../src/state/snapshot
import ../src/systems/runtime_facade
import ../src/systems/update
import ../src/types/model
import ../src/types/runtime_values

proc configuredModel(): Model =
  initRuntimeStateFromConfig(Config(
    layout: LayoutConfig(
      gaps: 10,
      defaultColumnWidth: 0.7,
      defaultWindowWidth: 0.8,
      defaultWindowHeight: 0.6,
      defaultMasterCount: 2,
      defaultMasterRatio: 0.65),
    workspaces: WorkspaceConfig(defaultCount: 3),
    windowRules: @[
      WindowRule(appIdMatch: "float-me", openFloating: true),
      WindowRule(appIdMatch: "qemu", keyboardShortcutsInhibit: true)
    ])).model

suite "Core Runtime Logic":
  test "Triad reload command emits restart effect":
    let (_, effects) = update(Model(), Msg(kind: CmdTriadReload))
    check effects.len == 1
    check effects[0].kind == EffTriadReload

  test "Targeted layout command updates requested slot only":
    var model = configuredModel()
    let (nextModel, effects) =
      update(model, Msg(kind: CmdSetLayout, newLayout: Deck,
        layoutTargetTag: 2))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.activeTag == 1
    check snapshot.workspaces[0].layoutMode == Scroller
    check snapshot.workspaces[1].layoutMode == Deck
    check effects.anyIt(it.kind == EffManageDirty)
    check effects.anyIt(
      it.kind == EffBroadcastTriadJson and
      it.jsonPayload.contains("layout-state-changed"))

  test "Render visibility suppresses clipped scroller border rails":
    let screen = Rect(x: 0, y: 0, w: 100, h: 80)

    let full = renderVisibility(Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)
    check full.visible
    check not full.clipped
    check full.borderEdges == RenderAllEdges

    let leftClip =
      renderVisibility(Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    check leftClip.visible
    check leftClip.clipped
    check (leftClip.borderEdges and RenderEdgeLeft) == 0
    check (leftClip.borderEdges and RenderEdgeRight) == 0

    let sliver =
      renderVisibility(Rect(x: -98, y: 10, w: 100, h: 30), screen, 4)
    check not sliver.visible
    check sliver.borderEdges == 0

  test "Window lifecycle mutates state and emits shell updates":
    var model = configuredModel()
    let (nextModel, effects) = update(model, Msg(
      kind: WlWindowCreated,
      windowId: 100,
      appId: "firefox",
      title: "Mozilla Firefox"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 100
    check snapshot.windows[0].appId == "firefox"
    check snapshot.workspaces[0].focusedWindow == 100
    check effects.anyIt(it.kind == EffManageDirty)
    check effects.anyIt(
      it.kind == EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))

  test "Configured defaults place floating windows":
    var model = configuredModel()
    let (nextModel, _) = update(model, Msg(
      kind: WlWindowCreated,
      windowId: 130,
      appId: "float-me",
      title: "Tool"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].widthProportion == 0.8'f32
    check snapshot.windows[0].heightProportion == 0.6'f32
    check snapshot.windows[0].isFloating
    check snapshot.workspaces[0].masterCount == 2
    check snapshot.workspaces[0].masterSplitRatio == 0.65'f32
    check snapshot.workspaces[0].columns[0].widthProportion == 0.7'f32

  test "Window rule marks matching windows as shortcut-inhibiting":
    var model = configuredModel()
    let (nextModel, _) = update(model, Msg(
      kind: WlWindowCreated,
      windowId: 140,
      appId: "qemu-system-x86_64",
      title: "Void"))
    let snapshot = nextModel.shellSnapshot()

    check snapshot.windows.len == 1
    check snapshot.windows[0].keyboardShortcutsInhibit

  test "Live restore parser accepts native schema only":
    let native = parseLiveRestoreJson("""
{
  "schema": "triad-live-restore-v2",
  "active_tag": 2,
  "focused_window": 10,
  "tags": [
    {"id": 2, "layout_mode": "Deck", "columns": [
      {"windows": [10], "width_proportion": 0.6}
    ]}
  ],
  "windows": [{"id": 10, "tag_id": 2, "app_id": "term"}]
}
""")
    check native.isSome
    check native.get().activeTag == 2
    check native.get().tags[2].layoutMode == Deck
    check native.get().windows[10].appId == "term"

    let invalid = parseLiveRestoreJson("""{"workspaces":[{"id":1}]}""")
    check invalid.isNone

  test "Niri window event includes focused workspace state":
    var model = configuredModel()
    let (_, effects) = update(model, Msg(
      kind: WlWindowCreated,
      windowId: 120,
      appId: "alacritty",
      title: "Alacritty"))
    let event = effects.filterIt(
      it.kind == EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))[0]
    let win = parseJson(event.jsonPayload)["WindowOpenedOrChanged"]["window"]

    check win["id"].getInt() == 120
    check win["workspace_id"].getInt() == 1
    check win["is_focused"].getBool()
