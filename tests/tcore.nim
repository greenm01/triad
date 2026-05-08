import unittest
import ../src/core/model
import ../src/core/model_utils
import ../src/core/msg
import ../src/core/niri_state
import ../src/core/render_visibility
import ../src/core/restore_state
import ../src/core/update
import json, options, os, tables, sequtils, strutils

proc installAppIdentityFixture() =
  let apps = getTempDir() / ("triad-core-apps-" & $getCurrentProcessId()) / "applications"
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
  writeFile(apps / "kitty.desktop", """
[Desktop Entry]
Name=kitty
Exec=kitty
Icon=kitty
Categories=System;TerminalEmulator;
""")
  putEnv("XDG_DATA_HOME", apps.parentDir())
  putEnv("XDG_DATA_DIRS", "")

suite "Core TEA Update Logic":
  setup:
    installAppIdentityFixture()
    var model = Model(
      activeTag: 1,
      screenWidth: 1920,
      screenHeight: 1080,
      outerGaps: 10,
      innerGaps: 5
    )

  test "Render visibility suppresses clipped scroller border rails":
    let screen = Rect(x: 0, y: 0, w: 100, h: 80)

    let full = renderVisibility(Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)
    check full.visible
    check not full.clipped
    check full.clipX == 0
    check full.clipY == 0
    check full.clipW == 40
    check full.clipH == 30
    check full.borderEdges == RenderAllEdges

    let leftClip = renderVisibility(Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    check leftClip.visible
    check leftClip.clipped
    check leftClip.clipX == 20
    check leftClip.clipW == 40
    check (leftClip.borderEdges and RenderEdgeLeft) == 0
    check (leftClip.borderEdges and RenderEdgeRight) == 0
    check (leftClip.borderEdges and RenderEdgeTop) != 0
    check (leftClip.borderEdges and RenderEdgeBottom) != 0

    let rightClip = renderVisibility(Rect(x: 70, y: 10, w: 60, h: 30), screen, 4)
    check rightClip.visible
    check rightClip.clipped
    check rightClip.clipW == 30
    check (rightClip.borderEdges and RenderEdgeLeft) == 0
    check (rightClip.borderEdges and RenderEdgeRight) == 0

    let topClip = renderVisibility(Rect(x: 10, y: -10, w: 40, h: 30), screen, 4)
    check topClip.visible
    check topClip.clipped
    check (topClip.borderEdges and RenderEdgeTop) == 0
    check (topClip.borderEdges and RenderEdgeBottom) == 0
    check (topClip.borderEdges and RenderEdgeLeft) != 0
    check (topClip.borderEdges and RenderEdgeRight) != 0

    let sliver = renderVisibility(Rect(x: -98, y: 10, w: 100, h: 30), screen, 4)
    check not sliver.visible
    check sliver.borderEdges == 0

  test "WlWindowCreated initializes tag and window data":
    let msg = Msg(kind: WlWindowCreated, windowId: 100, appId: "firefox", title: "Mozilla Firefox")
    let (nextModel, effects) = update(model, msg)
    
    check nextModel.windows.hasKey(100)
    check nextModel.windows[100].appId == "firefox"
    check nextModel.tags.hasKey(1)
    check nextModel.tags[1].columns.len == 1
    check nextModel.tags[1].focusedWindow == 100
    
    # Check effects
    var hasManageDirty = false
    for eff in effects:
      if eff.kind == EffManageDirty: hasManageDirty = true
    check hasManageDirty

  test "Window open event includes Niri workspace and app identity":
    model.tags[1] = initTagState(1, Scroller)
    model.activeTag = 1

    let (_, effects) = update(model, Msg(kind: WlWindowCreated, windowId: 120, appId: "alacritty", title: "Alacritty"))
    let event = effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WindowOpenedOrChanged"))[0]
    let win = parseJson(event.jsonPayload)["WindowOpenedOrChanged"]["window"]

    check win["id"].getInt() == 120
    check win["app_id"].getStr() == "triad-alacritty"
    check win["raw_app_id"].getStr() == "alacritty"
    check win["workspace_id"].getInt() == 1
    check win["is_focused"].getBool() == true

  test "Configured runtime defaults place new windows and floating windows":
    model.activeTag = 1
    model.screenWidth = 2000
    model.screenHeight = 1000
    model.defaultColumnWidth = 0.7
    model.defaultWindowWidth = 0.8
    model.defaultWindowHeight = 0.6
    model.defaultMasterCount = 2
    model.defaultMasterRatio = 0.65
    model.floating = FloatingConfig(
      xRatio: 0.1,
      yRatio: 0.2,
      widthRatio: 0.4,
      heightRatio: 0.5,
      minWidth: 120,
      minHeight: 90)
    model.windowRules.add(WindowRule(appIdMatch: "float-me", openFloating: true))

    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 130, appId: "float-me", title: "Tool"))

    check nextModel.windows[130].widthProportion == 0.8'f32
    check nextModel.windows[130].heightProportion == 0.6'f32
    check nextModel.windows[130].floatingGeom == Rect(x: 200, y: 200, w: 800, h: 500)
    check nextModel.tags[1].masterCount == 2
    check nextModel.tags[1].masterSplitRatio == 0.65'f32
    check nextModel.tags[1].columns[0].widthProportion == 0.7'f32

    nextModel.windows[131] = WindowData(id: 131, appId: "term", title: "Term")
    nextModel.tags[1].columns[0].windows.add(131)
    nextModel.tags[1].focusedWindow = 131

    (nextModel, _) = update(nextModel, Msg(kind: CmdExpelWindow))
    check nextModel.tags[1].columns[^1].widthProportion == 0.7'f32

  test "Moving windows emits full Niri window state":
    model.tags[1] = initTagState(1, Scroller)
    model.tags[1].columns.add(Column(windows: @[WindowId(121)]))
    model.tags[1].focusedWindow = 121
    model.windows[121] = WindowData(id: 121, appId: "kitty", title: "Kitty")
    model.activeTag = 1

    let (_, effects) = update(model, Msg(kind: CmdMoveToTag, targetTag: 2))
    let event = effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WindowsChanged"))[^1]
    let windows = parseJson(event.jsonPayload)["WindowsChanged"]["windows"]

    check windows.len == 1
    check windows[0]["app_id"].getStr() == "triad-kitty"
    check windows[0]["raw_app_id"].getStr() == "kitty"
    check windows[0]["workspace_id"].getInt() == 2

  test "Output changes emit full Niri state for shell caches":
    model.tags[1] = initTagState(1, Scroller)
    model.activeTag = 1

    var (nextModel, effects) = update(model, Msg(kind: WlOutputName, nameOutputId: 42, outputName: "DP-2"))
    check nextModel.primaryOutput == 42

    let outputEvent = effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("OutputsChanged"))[^1]
    let workspaceEvent = effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspacesChanged"))[^1]
    let windowsEvent = effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WindowsChanged"))[^1]
    check parseJson(outputEvent.jsonPayload)["OutputsChanged"]["outputs"].hasKey("DP-2")
    check parseJson(workspaceEvent.jsonPayload)["WorkspacesChanged"]["workspaces"][0]["output"].getStr() == "DP-2"
    check parseJson(windowsEvent.jsonPayload)["WindowsChanged"]["windows"].len == 0

    (nextModel, effects) = update(nextModel, Msg(kind: WlOutputDimensions, outputId: 42, width: 2560, height: 1440))
    let resizedOutput = parseJson(effects.filterIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("OutputsChanged"))[^1].jsonPayload)
    check resizedOutput["OutputsChanged"]["outputs"]["DP-2"]["width"].getInt() == 2560
    check resizedOutput["OutputsChanged"]["outputs"]["DP-2"]["height"].getInt() == 1440

  test "Window creation emits workspace occupancy before full window state":
    model.tags[1] = initTagState(1, Scroller)
    model.activeTag = 1

    let (_, effects) = update(model, Msg(kind: WlWindowCreated, windowId: 122, appId: "kitty", title: "Kitty"))
    let workspaceIdx = effects.findIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspacesChanged"))
    let windowsIdx = effects.findIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WindowsChanged"))
    check workspaceIdx >= 0
    check windowsIdx >= 0
    check workspaceIdx < windowsIdx

    let workspaces = parseJson(effects[workspaceIdx].jsonPayload)["WorkspacesChanged"]["workspaces"]
    check workspaces[0]["occupied"].getBool() == true

    let windows = parseJson(effects[windowsIdx].jsonPayload)["WindowsChanged"]["windows"]
    check windows.len == 1
    check windows[0]["app_id"].getStr() == "triad-kitty"
    check windows[0]["raw_app_id"].getStr() == "kitty"

  test "CmdFocusNext cycles focus correctly":
    # Setup model with 3 windows across 2 columns
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[WindowId(102), 103], widthProportion: 0.5))
    model.tags[1] = tag
    
    let msg = Msg(kind: CmdFocusNext)
    var (nextModel, _) = update(model, msg)
    check nextModel.tags[1].focusedWindow == 102
    
    let (finalModel, _) = update(nextModel, msg)
    check finalModel.tags[1].focusedWindow == 103

  test "CmdMoveColumnRight swaps columns":
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[WindowId(102)], widthProportion: 0.5))
    model.tags[1] = tag
    
    let msg = Msg(kind: CmdMoveColumnRight)
    let (nextModel, _) = update(model, msg)
    
    check nextModel.tags[1].columns[0].windows[0] == 102
    check nextModel.tags[1].columns[1].windows[0] == 101

  test "CmdMoveToTag transfers window between tags":
    # Window 101 is on Tag 1
    var tag1 = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag1.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    model.tags[1] = tag1
    model.activeTag = 1
    
    let msg = Msg(kind: CmdMoveToTag, targetTag: 2)
    let (nextModel, _) = update(model, msg)
    
    # Verify Tag 1 is empty
    check nextModel.tags[1].columns.len == 0
    # Verify Tag 2 has the window
    check nextModel.tags[2].columns.len == 1
    check nextModel.tags[2].columns[0].windows[0] == 101
    check nextModel.tags[2].focusedWindow == 101

  test "CmdSwapWindowToTag exchanges windows between tags":
    # Tag 1: [101], Tag 2: [102]
    var tag1 = TagState(tagId: 1, focusedWindow: 101)
    tag1.columns.add(Column(windows: @[WindowId(101)]))
    var tag2 = TagState(tagId: 2, focusedWindow: 102)
    tag2.columns.add(Column(windows: @[WindowId(102)]))
    model.tags[1] = tag1
    model.tags[2] = tag2
    model.activeTag = 1
    
    let (nextModel, _) = update(model, Msg(kind: CmdSwapWindowToTag, targetTagSwap: 2))
    check nextModel.tags[1].columns[0].windows[0] == 102
    check nextModel.tags[2].columns[0].windows[0] == 101
    check nextModel.tags[1].focusedWindow == 102
    check nextModel.tags[2].focusedWindow == 101

  test "forced-layout window rule overrides tag layout":
    # Setup rule: Discord forces Grid mode
    model.windowRules.add(WindowRule(appIdMatch: "discord", forcedLayout: ord(Grid) + 1))
    model.activeTag = 1
    
    let msg = Msg(kind: WlWindowCreated, windowId: 100, appId: "discord", title: "Discord")
    let (nextModel, _) = update(model, msg)
    
    check nextModel.tags[1].layoutMode == Grid

  test "new window opens on active tag unless a rule pins it":
    model.tags[1] = TagState(tagId: 1, layoutMode: Scroller)
    model.tags[3] = TagState(tagId: 3, layoutMode: Grid)
    model.activeTag = 3

    var (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 110, appId: "foot", title: "foot"))
    check nextModel.tags[3].containsWindow(110)
    check not nextModel.tags[1].containsWindow(110)

    nextModel.windowRules.add(WindowRule(appIdMatch: "pinned", defaultTag: 1))
    let (pinnedModel, _) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 111, appId: "pinned-app", title: "pinned"))
    check pinnedModel.tags[1].containsWindow(111)

  test "live restore places rediscovered windows before rules":
    model.tags[1] = initTagState(1, Scroller)
    model.tags[2] = initTagState(2, Grid)
    model.activeTag = 1
    model.windowRules.add(WindowRule(appIdMatch: "pinned", defaultTag: 3))
    var restored = LiveRestoreState(activeTag: 2)
    restored.tagByWindow[WindowId(112)] = 2
    model.applyLiveRestore(restored)

    let (nextModel, _) = update(model, Msg(kind: WlWindowCreated, windowId: 112, appId: "pinned-app", title: "pinned"))
    check nextModel.activeTag == 2
    check nextModel.tags[2].containsWindow(112)
    check not nextModel.tags[1].containsWindow(112)
    check not nextModel.tags.hasKey(3) or not nextModel.tags[3].containsWindow(112)
    check not nextModel.restoreTagByWindow.hasKey(112)

  test "native live restore preserves workspace layout sizing and focus":
    var source = Model(activeTag: 2, screenWidth: 2560, screenHeight: 1440)
    source.tags[1] = initTagState(1, Scroller, "term")
    source.tags[2] = initTagState(2, Scroller, "web")
    source.tags[2].focusedWindow = 202
    source.tags[2].targetViewportXOffset = 128.0
    source.tags[2].currentViewportXOffset = 64.0
    source.tags[2].columns.add(Column(windows: @[WindowId(201)], widthProportion: 0.35))
    source.tags[2].columns.add(Column(windows: @[WindowId(202)], widthProportion: 0.9))
    source.windows[201] = WindowData(id: 201, appId: "foot", title: "foot", widthProportion: 0.4, heightProportion: 0.8)
    source.windows[202] = WindowData(
      id: 202,
      appId: "brave",
      title: "Brave",
      widthProportion: 0.75,
      heightProportion: 1.0,
      isMaximized: true,
      actualW: 2560,
      actualH: 1410)
    source.outputTags[42] = 2
    source.focusHistory = @[WindowId(201), 202]
    source.workspaceHistory = @[1'u32, 2]

    let parsed = parseLiveRestoreJson(liveRestoreJson(source))
    check parsed.isSome
    check parsed.get().focusHistory == @[WindowId(201), 202]
    check parsed.get().workspaceHistory == @[1'u32, 2]

    var restoredModel = Model(activeTag: 1, screenWidth: 2560, screenHeight: 1440)
    restoredModel.applyLiveRestore(parsed.get())
    check restoredModel.focusHistory == @[WindowId(201), 202]
    check restoredModel.workspaceHistory == @[1'u32, 2]

    var (nextModel, _) = update(restoredModel, Msg(kind: WlWindowCreated, windowId: 201, appId: "foot", title: "foot"))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 202
    check nextModel.tags[2].columns[0].windows == @[WindowId(201)]
    check nextModel.tags[2].columns[0].widthProportion == 0.35'f32
    check nextModel.restoreFocusedWindow == 202

    var effects: seq[Effect]
    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 202, appId: "brave", title: "Brave"))
    check nextModel.tags[2].name == "web"
    check nextModel.tags[2].focusedWindow == 202
    check nextModel.tags[2].columns.len == 2
    check nextModel.tags[2].columns[1].windows == @[WindowId(202)]
    check nextModel.tags[2].columns[1].widthProportion == 0.9'f32
    check nextModel.tags[2].currentViewportXOffset == 64.0'f32
    check nextModel.windows[202].isMaximized
    check nextModel.windows[202].actualW == 2560
    check nextModel.outputTags[42] == 2
    check nextModel.restoreFocusedWindow == 0
    check effects.anyIt(it.kind == EffSetMaximized and it.maxWinId == 202 and it.isMaximized)
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 202)

    var manageEffects: seq[Effect]
    (nextModel, manageEffects) = update(nextModel, Msg(kind: WlManageStart))
    check nextModel.tags[2].focusedWindow == 202
    check manageEffects.anyIt(it.kind == EffFocusWindow and it.focusId == 202)

  test "legacy live restore matches changed window ids by identity":
    let parsed = parseLiveRestoreJson("""
{
  "workspaces": [
    {"id": 1, "name": "term", "is_active": false},
    {"id": 2, "name": "web", "is_active": true}
  ],
  "windows": [
    {
      "id": 10,
      "title": "term",
      "app_id": "triad-foot",
      "raw_app_id": "foot",
      "workspace_id": 2,
      "is_focused": false,
      "layout": {
        "pos_in_scrolling_layout": [2, 1],
        "tile_size": [2000.0, 1000.0],
        "window_size": [800, 900]
      }
    },
    {
      "id": 11,
      "title": "Browser",
      "app_id": "brave-origin-nightly.desktop",
      "raw_app_id": "brave-origin-nightly",
      "workspace_id": 2,
      "is_focused": true,
      "is_maximized": true,
      "layout": {
        "pos_in_scrolling_layout": [1, 1],
        "tile_size": [2000.0, 1000.0],
        "window_size": [1000, 900]
      }
    }
  ]
}
""")
    check parsed.isSome

    var restoredModel = Model(activeTag: 1, screenWidth: 2000, screenHeight: 1000)
    restoredModel.applyLiveRestore(parsed.get())

    var (nextModel, _) = update(restoredModel, Msg(kind: WlWindowCreated, windowId: 210, appId: "foot", title: "term"))
    var effects: seq[Effect]
    (nextModel, effects) = update(nextModel, Msg(kind: WlWindowCreated, windowId: 211, appId: "brave-origin-nightly", title: "Browser"))

    check nextModel.activeTag == 2
    check nextModel.tags[2].name == "web"
    check nextModel.tags[2].focusedWindow == 211
    check nextModel.tags[2].columns.len == 2
    check nextModel.tags[2].columns[0].windows == @[WindowId(211)]
    check nextModel.tags[2].columns[1].windows == @[WindowId(210)]
    check nextModel.windows[211].isMaximized
    check nextModel.windows[211].widthProportion == 0.5'f32
    check nextModel.restoreFocusedWindow == 0
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 211)

  test "Scratchpad management moves window out of tag":
    var tag1 = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag1.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    model.tags[1] = tag1
    model.activeTag = 1
    
    let msg = Msg(kind: CmdMoveToScratchpad)
    let (nextModel, _) = update(model, msg)
    
    check nextModel.tags[1].columns.len == 0
    check nextModel.scratchpadWindows.len == 1
    check nextModel.scratchpadWindows[0] == 101

  test "Named scratchpad can hide show and restore a real window":
    var tag1 = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag1.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    model.tags[1] = tag1
    model.windows[101] = WindowData(id: 101, appId: "terminal", title: "Terminal")
    model.activeTag = 1

    var (nextModel, _) = update(model, Msg(kind: CmdMoveToNamedScratchpad, scratchpadName: "terminal"))
    check nextModel.tags[1].columns.len == 0
    check nextModel.namedScratchpads["terminal"] == 101

    (nextModel, _) = update(nextModel, Msg(kind: CmdToggleNamedScratchpad, scratchpadName: "terminal"))
    check nextModel.isScratchpadVisible
    check nextModel.visibleScratchpad == 101

    (nextModel, _) = update(nextModel, Msg(kind: CmdToggleNamedScratchpad, scratchpadName: "terminal"))
    check not nextModel.isScratchpadVisible
    check nextModel.visibleScratchpad == 0

    (nextModel, _) = update(nextModel, Msg(kind: CmdRestoreScratchpad))
    check nextModel.scratchpadWindows.len == 0
    check not nextModel.namedScratchpads.hasKey("terminal")
    check nextModel.tags[1].containsWindow(101)
    check nextModel.tags[1].focusedWindow == 101

  test "Directional focus follows columns and stacks":
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag.columns.add(Column(windows: @[WindowId(101), 102], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[WindowId(103)], widthProportion: 0.5))
    model.tags[1] = tag
    model.activeTag = 1

    var (nextModel, _) = update(model, Msg(kind: CmdFocusDirection, direction: DirDown))
    check nextModel.tags[1].focusedWindow == 102

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusDirection, direction: DirRight))
    check nextModel.tags[1].focusedWindow == 103

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusDirection, direction: DirLeft))
    check nextModel.tags[1].focusedWindow == 101

  test "Focus last uses recent window history":
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag.columns.add(Column(windows: @[WindowId(101), 102], widthProportion: 0.5))
    model.tags[1] = tag
    model.windows[101] = WindowData(id: 101)
    model.windows[102] = WindowData(id: 102)
    model.activeTag = 1

    var (nextModel, _) = update(model, Msg(kind: WlFocusChanged, newFocusedId: 101))
    (nextModel, _) = update(nextModel, Msg(kind: WlFocusChanged, newFocusedId: 102))
    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusLast))

    check nextModel.tags[1].focusedWindow == 101

  test "Closing focused window restores most recent surviving window globally":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[1].focusedWindow = 101
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[2].columns.add(Column(windows: @[WindowId(201)]))
    model.tags[2].focusedWindow = 201
    model.windows[101] = WindowData(id: 101)
    model.windows[201] = WindowData(id: 201)
    model.activeTag = 2
    model.focusHistory = @[WindowId(101), 201]
    model.workspaceHistory = @[1'u32, 2]

    let (nextModel, effects) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 201))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 101
    check nextModel.focusHistory == @[WindowId(101)]
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 101)
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspaceActivated"))

  test "Closing background window does not steal focus":
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[1].columns.add(Column(windows: @[WindowId(101), 102]))
    model.tags[1].focusedWindow = 101
    model.windows[101] = WindowData(id: 101)
    model.windows[102] = WindowData(id: 102)
    model.activeTag = 1
    model.focusHistory = @[WindowId(102), 101]

    let (nextModel, effects) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 102))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 101
    check not nextModel.tags[1].containsWindow(102)
    check not effects.anyIt(it.kind == EffFocusWindow and it.focusId == 101)

  test "Closing focused window ignores invalid MRU candidates":
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[1].focusedWindow = 101
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[2].columns.add(Column(windows: @[WindowId(201)]))
    model.tags[2].focusedWindow = 201
    model.tags[3] = initTagState(3, Scroller, "chat")
    model.tags[3].columns.add(Column(windows: @[WindowId(301)]))
    model.tags[3].focusedWindow = 301
    model.windows[101] = WindowData(id: 101)
    model.windows[201] = WindowData(id: 201)
    model.windows[301] = WindowData(id: 301, isMinimized: true)
    model.activeTag = 2
    model.focusHistory = @[WindowId(999), 101, 301, 201]

    let (nextModel, _) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 201))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 101
    check nextModel.focusHistory == @[WindowId(101)]

  test "Closing focused window falls back to workspace MRU":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[2].columns.add(Column(windows: @[WindowId(201)]))
    model.tags[2].focusedWindow = 201
    model.windows[201] = WindowData(id: 201)
    model.activeTag = 2
    model.focusHistory = @[WindowId(201)]
    model.workspaceHistory = @[1'u32, 2]

    let (nextModel, effects) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 201))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 0
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspaceActivated"))

  test "Closing focused window prunes emptied dynamic workspace after MRU restore":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[1].focusedWindow = 101
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401)]))
    model.tags[4].focusedWindow = 401
    model.windows[101] = WindowData(id: 101)
    model.windows[401] = WindowData(id: 401)
    model.activeTag = 4
    model.focusHistory = @[WindowId(101), 401]
    model.workspaceHistory = @[1'u32, 4]

    let (nextModel, _) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 401))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 101
    check not nextModel.tags.hasKey(4)
    check niriWorkspacesJson(nextModel).len == 3

  test "Relative tag commands focus and move by tag order":
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.windows[101] = WindowData(id: 101)
    model.tags[2] = TagState(tagId: 2)
    model.tags[3] = TagState(tagId: 3, focusedWindow: 103)
    model.tags[3].columns.add(Column(windows: @[WindowId(103)]))
    model.windows[103] = WindowData(id: 103)
    model.activeTag = 2

    var (nextModel, _) = update(model, Msg(kind: CmdFocusTagRight))
    check nextModel.activeTag == 3

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusOccupiedTagLeft))
    check nextModel.activeTag == 1

    (nextModel, _) = update(nextModel, Msg(kind: CmdMoveToTagRight))
    check nextModel.tags[1].columns.len == 0
    check nextModel.tags[2].containsWindow(101)

  test "CmdSwitchLayout advances through configured layout cycle":
    model.layoutCycle = @[Scroller, Grid]
    model.tags[1] = TagState(tagId: 1, layoutMode: Scroller)
    model.activeTag = 1

    var (nextModel, _) = update(model, Msg(kind: CmdSwitchLayout))
    check nextModel.tags[1].layoutMode == Grid

    (nextModel, _) = update(nextModel, Msg(kind: CmdSwitchLayout))
    check nextModel.tags[1].layoutMode == Scroller

  test "CmdAdjustMasterCount and Ratio apply deltas":
    model.tags[1] = TagState(tagId: 1, layoutMode: MasterStack, masterCount: 1, masterSplitRatio: 0.5)
    model.activeTag = 1
    
    let msgCount = Msg(kind: CmdAdjustMasterCount, deltaMC: 1)
    let (nextModel, _) = update(model, msgCount)
    check nextModel.tags[1].masterCount == 2
    
    let msgRatio = Msg(kind: CmdAdjustMasterRatio, deltaMR: 0.1)
    let (finalModel, _) = update(nextModel, msgRatio)
    check abs(finalModel.tags[1].masterSplitRatio - 0.6) < 0.01

  test "CmdMoveWindowLeft moves window to adjacent column or creates new":
    # [101] [102]
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 102)
    tag.columns.add(Column(windows: @[WindowId(101)], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[WindowId(102)], widthProportion: 0.5))
    model.tags[1] = tag
    model.activeTag = 1
    
    # Move 102 left -> [101, 102]
    var (nextModel, _) = update(model, Msg(kind: CmdMoveWindowLeft))
    check nextModel.tags[1].columns.len == 1
    check nextModel.tags[1].columns[0].windows == @[WindowId(101), 102]
    
    # Move 101 left -> [101] [102]
    var tagState = nextModel.tags[1]
    tagState.focusedWindow = 101
    nextModel.tags[1] = tagState
    let (finalModel, _) = update(nextModel, Msg(kind: CmdMoveWindowLeft))
    check finalModel.tags[1].columns.len == 2
    check finalModel.tags[1].columns[0].windows == @[WindowId(101)]
    check finalModel.tags[1].columns[1].windows == @[WindowId(102)]

  test "CmdFocusNext in Overview cycles through all tags":
    model.overviewActive = true
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[2] = TagState(tagId: 2, focusedWindow: 102)
    model.tags[2].columns.add(Column(windows: @[WindowId(102)]))
    model.windows[101] = WindowData(id: 101)
    model.windows[102] = WindowData(id: 102)
    model.activeTag = 1
    
    let (nextModel, _) = update(model, Msg(kind: CmdFocusNext))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 102
    
    let (finalModel, _) = update(nextModel, Msg(kind: CmdFocusNext))
    check finalModel.activeTag == 1
    check finalModel.tags[1].focusedWindow == 101

  test "Overview navigation commits focus immediately":
    model.overviewActive = true
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[2] = TagState(tagId: 2, focusedWindow: 102)
    model.tags[2].columns.add(Column(windows: @[WindowId(102)]))
    model.windows[101] = WindowData(id: 101, appId: "app", title: "one")
    model.windows[102] = WindowData(id: 102, appId: "app", title: "two")
    model.activeTag = 1

    var (nextModel, effects) = update(model, Msg(kind: CmdFocusDirection, direction: DirDown))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 102
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 102)

    let (selectedModel, selectedEffects) = update(nextModel, Msg(kind: CmdSelectWindow))
    check not selectedModel.overviewActive
    check selectedEffects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("OverviewOpenedOrClosed"))
    check selectedEffects.anyIt(it.kind == EffFocusWindow and it.focusId == 102)

  test "Overview directional navigation follows columns and tag edges":
    model.overviewActive = true
    model.tags[1] = TagState(tagId: 1, focusedWindow: 102)
    model.tags[1].columns.add(Column(windows: @[WindowId(101), 102]))
    model.tags[1].columns.add(Column(windows: @[WindowId(103), 104]))
    model.tags[2] = TagState(tagId: 2, focusedWindow: 201)
    model.tags[2].columns.add(Column(windows: @[WindowId(201)]))
    for win in [WindowId(101), 102, 103, 104, 201]:
      model.windows[win] = WindowData(id: win)
    model.activeTag = 1

    var (nextModel, effects) = update(model, Msg(kind: CmdFocusDirection, direction: DirRight))
    check nextModel.activeTag == 1
    check nextModel.tags[1].focusedWindow == 104
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 104)

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusDirection, direction: DirUp))
    check nextModel.tags[1].focusedWindow == 103

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusDirection, direction: DirDown))
    check nextModel.tags[1].focusedWindow == 104

    (nextModel, effects) = update(nextModel, Msg(kind: CmdFocusDirection, direction: DirDown))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 201
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 201)

  test "Niri-style edge movement moves focused window between tags":
    model.tags[1] = TagState(tagId: 1, focusedWindow: 102)
    model.tags[1].columns.add(Column(windows: @[WindowId(101), 102]))
    model.tags[2] = TagState(tagId: 2)
    model.windows[101] = WindowData(id: 101)
    model.windows[102] = WindowData(id: 102)
    model.activeTag = 1

    var (nextModel, effects) = update(model, Msg(kind: CmdMoveWindowUpOrToWorkspaceUp))
    check nextModel.activeTag == 1
    check nextModel.tags[1].columns[0].windows == @[WindowId(102), 101]
    check not effects.anyIt(it.kind == EffFocusWindow)

    (nextModel, effects) = update(nextModel, Msg(kind: CmdMoveWindowDownOrToWorkspaceDown))
    check nextModel.activeTag == 1
    check nextModel.tags[1].columns[0].windows == @[WindowId(101), 102]

    (nextModel, effects) = update(nextModel, Msg(kind: CmdMoveWindowDownOrToWorkspaceDown))
    check nextModel.activeTag == 2
    check not nextModel.tags[1].containsWindow(102)
    check nextModel.tags[2].containsWindow(102)
    check nextModel.tags[2].focusedWindow == 102
    check effects.anyIt(it.kind == EffFocusWindow and it.focusId == 102)

  test "Dynamic workspace navigation grows and prunes empty non-default tags":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.activeTag = 3

    var (nextModel, _) = update(model, Msg(kind: CmdFocusTagRight))
    check nextModel.activeTag == 4
    check nextModel.tags.hasKey(4)
    check niriWorkspacesJson(nextModel).len == 4

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusTagLeft))
    check nextModel.activeTag == 3
    check not nextModel.tags.hasKey(4)
    check niriWorkspacesJson(nextModel).len == 3

  test "Occupied dynamic workspace exposes one trailing creation workspace":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401)]))
    model.tags[4].focusedWindow = 401
    model.windows[401] = WindowData(id: 401)
    model.activeTag = 4

    let workspaces = niriWorkspacesJson(model)
    check workspaces.len == 5
    check workspaces[3]["id"].getInt() == 4
    check workspaces[3]["idx"].getInt() == 4
    check workspaces[3]["occupied"].getBool()
    check workspaces[4]["id"].getInt() == 5
    check workspaces[4]["idx"].getInt() == 5
    check not workspaces[4]["occupied"].getBool()

    var (nextModel, _) = update(model, Msg(kind: CmdFocusWorkspaceIndex, workspaceIndex: 5))
    check nextModel.activeTag == 5
    check nextModel.tags.hasKey(5)
    check niriWorkspacesJson(nextModel).len == 5

    (nextModel, _) = update(nextModel, Msg(kind: CmdFocusTagRight))
    check nextModel.activeTag == 5
    check not nextModel.tags.hasKey(6)
    check niriWorkspacesJson(nextModel).len == 5

  test "Occupied sparse dynamic tag compacts with trailing creation workspace":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[9] = initTagState(9, Monocle, "media")
    model.tags[9].columns.add(Column(windows: @[WindowId(901)]))
    model.tags[9].focusedWindow = 901
    model.windows[901] = WindowData(id: 901)
    model.activeTag = 1

    let workspaces = niriWorkspacesJson(model)
    check workspaces.len == 5
    check workspaces[3]["id"].getInt() == 9
    check workspaces[3]["idx"].getInt() == 4
    check workspaces[4]["id"].getInt() == 10
    check workspaces[4]["idx"].getInt() == 5

  test "Dynamic workspace creation applies lazy tag templates":
    model.workspaces.defaultCount = 3
    model.tagRules = @[
      TagRule(tagId: 4, name: "chat", defaultLayout: Deck)
    ]
    model.tags[3] = initTagState(3, Scroller, "files")
    model.tags[3].columns.add(Column(windows: @[WindowId(301)]))
    model.tags[3].focusedWindow = 301
    model.windows[301] = WindowData(id: 301)
    model.activeTag = 3

    let (nextModel, _) = update(model, Msg(kind: CmdMoveWindowDownOrToWorkspaceDown))
    check nextModel.activeTag == 4
    check nextModel.tags[4].name == "chat"
    check nextModel.tags[4].layoutMode == Deck
    check nextModel.tags[4].containsWindow(301)
    check niriWorkspacesJson(nextModel).len == 5

  test "Closing last window on dynamic workspace collapses to lower workspace":
    model.workspaces.defaultCount = 3
    model.primaryOutput = 42
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401)]))
    model.tags[4].focusedWindow = 401
    model.windows[401] = WindowData(id: 401)
    model.outputTags[42] = 4
    model.activeTag = 4

    let (nextModel, effects) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 401))
    check nextModel.activeTag == 3
    check not nextModel.tags.hasKey(4)
    check nextModel.outputTags[42] == 3
    check niriWorkspacesJson(nextModel).len == 3
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspaceActivated"))
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspacesChanged"))

  test "Closing last window on default workspace keeps workspace visible":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[3].columns.add(Column(windows: @[WindowId(301)]))
    model.tags[3].focusedWindow = 301
    model.windows[301] = WindowData(id: 301)
    model.activeTag = 3

    let (nextModel, _) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 301))
    check nextModel.activeTag == 3
    check nextModel.tags.hasKey(3)
    check nextModel.tags[3].flattenWindows().len == 0
    check niriWorkspacesJson(nextModel).len == 3

  test "Closing one of several windows on dynamic workspace keeps it":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401), 402]))
    model.tags[4].focusedWindow = 401
    model.windows[401] = WindowData(id: 401)
    model.windows[402] = WindowData(id: 402)
    model.activeTag = 4

    let (nextModel, _) = update(model, Msg(kind: WlWindowDestroyed, destroyedId: 401))
    check nextModel.activeTag == 4
    check nextModel.tags.hasKey(4)
    check nextModel.tags[4].containsWindow(402)
    check niriWorkspacesJson(nextModel).len == 5

  test "Stale missing windows do not keep dynamic workspace visible":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[2].columns.add(Column(windows: @[WindowId(201)]))
    model.tags[2].focusedWindow = 201
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401)]))
    model.tags[4].focusedWindow = 401
    model.windows[201] = WindowData(id: 201)
    model.outputTags[42] = 4
    model.activeTag = 2

    let (nextModel, effects) = update(model, Msg(kind: WlModifiersChanged, newModifiers: 0))
    check not nextModel.tags.hasKey(4)
    check not nextModel.outputTags.hasKey(42)
    check niriWorkspacesJson(nextModel).len == 3
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspacesChanged"))

  test "Moving last window out of dynamic workspace collapses active workspace":
    model.workspaces.defaultCount = 3
    model.tags[1] = initTagState(1, Scroller, "term")
    model.tags[2] = initTagState(2, Scroller, "web")
    model.tags[3] = initTagState(3, Grid, "files")
    model.tags[4] = initTagState(4, Deck, "chat")
    model.tags[4].columns.add(Column(windows: @[WindowId(401)]))
    model.tags[4].focusedWindow = 401
    model.windows[401] = WindowData(id: 401)
    model.activeTag = 4

    let (nextModel, effects) = update(model, Msg(kind: CmdMoveToTag, targetTag: 5))
    check nextModel.activeTag == 3
    check not nextModel.tags.hasKey(4)
    check nextModel.tags[5].containsWindow(401)
    check niriWorkspacesJson(nextModel).len == 5
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspaceActivated"))
    check effects.anyIt(it.kind == EffBroadcastJson and it.jsonPayload.contains("WorkspacesChanged"))

  test "CmdMoveToTag in Overview updates activeTag":
    model.overviewActive = true
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.activeTag = 1
    
    let (nextModel, _) = update(model, Msg(kind: CmdMoveToTag, targetTag: 2))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 101
    check nextModel.tags[1].columns.len == 0

  test "CmdToggleFullscreen toggles state and emits effect":
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.windows[101] = WindowData(id: 101, isFullscreen: false)
    model.activeTag = 1
    
    let (nextModel, effects) = update(model, Msg(kind: CmdToggleFullscreen))
    check nextModel.windows[101].isFullscreen == true
    
    var hasFsEffect = false
    for eff in effects:
      if eff.kind == EffSetFullscreen and eff.fsWinId == 101 and eff.isFullscreen == true:
        hasFsEffect = true
    check hasFsEffect

  test "CmdResizeFloating modifies absolute geometry":
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.windows[101] = WindowData(id: 101, isFloating: true, floatingGeom: Rect(x: 100, y: 100, w: 200, h: 200))
    model.activeTag = 1
    
    let (nextModel, _) = update(model, Msg(kind: CmdResizeFloating, deltaFW: 50, deltaFH: -20))
    check nextModel.windows[101].floatingGeom.w == 250
    check nextModel.windows[101].floatingGeom.h == 180

  test "CmdScreenshot emits a screenshot effect":
    let (_, effects) = update(model, Msg(
      kind: CmdScreenshot,
      screenshotKind: ShotWindow,
      screenshotPath: "/tmp/triad-window.png",
      screenshotShowPointer: true
    ))

    check effects.len == 1
    check effects[0].kind == EffScreenshot
    check effects[0].screenshotKind == ShotWindow
    check effects[0].screenshotPath == "/tmp/triad-window.png"
    check effects[0].screenshotShowPointer == true
