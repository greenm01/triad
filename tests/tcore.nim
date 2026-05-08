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
    tag.columns.add(Column(windows: @[101], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[102, 103], widthProportion: 0.5))
    model.tags[1] = tag
    
    let msg = Msg(kind: CmdFocusNext)
    let (nextModel, _) = update(model, msg)
    check nextModel.tags[1].focusedWindow == 102
    
    let (finalModel, _) = update(nextModel, msg)
    check finalModel.tags[1].focusedWindow == 103

  test "CmdMoveColumnRight swaps columns":
    var tag = TagState(tagId: 1, layoutMode: Scroller, focusedWindow: 101)
    tag.columns.add(Column(windows: @[101], widthProportion: 0.5))
    tag.columns.add(Column(windows: @[102], widthProportion: 0.5))
    model.tags[1] = tag
    
    let msg = Msg(kind: CmdMoveColumnRight)
    let (nextModel, _) = update(model, msg)
    
    check nextModel.tags[1].columns[0].windows[0] == 102
    check nextModel.tags[1].columns[1].windows[0] == 101
