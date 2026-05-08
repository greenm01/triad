import unittest
import ../src/core/model
import ../src/core/model_utils
import ../src/core/msg
import ../src/core/restore_state
import ../src/core/update
import json, os, tables, sequtils, strutils

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

  test "Relative tag commands focus and move by tag order":
    model.tags[1] = TagState(tagId: 1, focusedWindow: 101)
    model.tags[1].columns.add(Column(windows: @[WindowId(101)]))
    model.tags[2] = TagState(tagId: 2)
    model.tags[3] = TagState(tagId: 3, focusedWindow: 103)
    model.tags[3].columns.add(Column(windows: @[WindowId(103)]))
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
