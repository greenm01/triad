import unittest
import ../src/core/model
import ../src/core/msg
import ../src/core/update
import tables

suite "Core TEA Update Logic":
  setup:
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
    model.activeTag = 1
    
    let (nextModel, _) = update(model, Msg(kind: CmdFocusNext))
    check nextModel.activeTag == 2
    check nextModel.tags[2].focusedWindow == 102
    
    let (finalModel, _) = update(nextModel, Msg(kind: CmdFocusNext))
    check finalModel.activeTag == 1
    check finalModel.tags[1].focusedWindow == 101

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
