import unittest, tables
import ../src/core/model
import ../src/layouts/scroller
import ../src/layouts/tiling

suite "Layout Algorithm Math":
  setup:
    let screen = Rect(x: 0, y: 0, w: 1000, h: 1000)
    let outerGap = 10.int32
    let innerGap = 20.int32

  test "layoutScroller calculates correct pixel boundaries":
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    # usableWidth = 1000 - 2*10 = 980
    # colWidth = 980 * 0.5 = 490
    tag.columns.add(Column(windows: @[101], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[102], widthProportion: 0.5))
    
    var windows = initTable[WindowId, WindowData]()
    windows[101] = WindowData(id: 101, heightProportion: 1.0)
    windows[102] = WindowData(id: 102, heightProportion: 1.0)

    let instructions = layoutScroller(tag, windows, screen, outerGap, innerGap, false, false, "never")
    
    check instructions.len == 2
    
    # First window: x=10, w = 490 - 20 = 470
    check instructions[0].windowId == 101
    check instructions[0].geom.x == 10
    check instructions[0].geom.w == 470
    
    # Second window: x = 10 + 490 = 500, w = 470
    check instructions[1].windowId == 102
    check instructions[1].geom.x == 500
    check instructions[1].geom.w == 470

  test "layoutMasterStack splits screen accurately":
    var tag = TagState(tagId: 1, layoutMode: MasterStack, masterCount: 1, masterSplitRatio: 0.6)
    tag.columns.add(Column(windows: @[101], widthProportion: 1.0))
    tag.columns.add(Column(windows: @[102], widthProportion: 1.0))
    
    let instructions = layoutMasterStack(tag, screen, outerGap, innerGap)
    
    check instructions.len == 2
    # Master (101): w = 980 * 0.6 = 588
    check instructions[0].windowId == 101
    check instructions[0].geom.w == 588 - 10 # 588 - innerGap/2
    
    # Stack (102): w = 980 - 588 = 392
    check instructions[1].windowId == 102
    check instructions[1].geom.w == 392 - 10

  test "deck layout keeps stack windows in one deck area":
    var tag = TagState(tagId: 1, layoutMode: Deck, masterCount: 1, masterSplitRatio: 0.6)
    tag.columns.add(Column(windows: @[WindowId(101), 102, 103], widthProportion: 1.0))

    let instructions = layoutDeck(tag, screen, outerGap, innerGap)

    check instructions.len == 3
    check instructions[0].windowId == 101
    check instructions[1].geom == instructions[2].geom
    check instructions[1].geom.x > instructions[0].geom.x

  test "center tile places master between side stacks":
    var tag = TagState(tagId: 1, layoutMode: CenterTile, masterCount: 1, masterSplitRatio: 0.5)
    tag.columns.add(Column(windows: @[WindowId(101), 102, 103], widthProportion: 1.0))

    let instructions = layoutCenterTile(tag, screen, outerGap, innerGap)

    check instructions.len == 3
    check instructions[0].windowId == 102
    check instructions[1].windowId == 101
    check instructions[2].windowId == 103
    check instructions[0].geom.x < instructions[1].geom.x
    check instructions[1].geom.x < instructions[2].geom.x

  test "vertical grid fills rows before columns":
    var tag = TagState(tagId: 1, layoutMode: VerticalGrid)
    tag.columns.add(Column(windows: @[WindowId(101), 102, 103, 104], widthProportion: 1.0))

    let instructions = layoutVerticalGrid(tag, screen, outerGap, innerGap)

    check instructions.len == 4
    check instructions[0].geom.x == instructions[1].geom.x
    check instructions[1].geom.y > instructions[0].geom.y
    check instructions[2].geom.x > instructions[0].geom.x
