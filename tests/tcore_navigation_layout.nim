import tcore_support

suite "Core Runtime Logic: navigation layout":
  test "Grid directional focus follows rendered rows":
    var model = directionalModel(LayoutMode.Grid)

    model.focusExternal(2)
    check model.focusDirection(Direction.DirDown) == 5
    check model.focusDirection(Direction.DirUp) == 2

    model.focusExternal(3)
    check model.focusDirection(Direction.DirDown) == 5

  test "Vertical grid directional focus follows rendered columns":
    var model = directionalModel(LayoutMode.VerticalGrid)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirDown) == 2
    check model.focusDirection(Direction.DirUp) == 1

    model.focusExternal(2)
    check model.focusDirection(Direction.DirRight) == 5
    check model.focusDirection(Direction.DirLeft) == 2

  test "Vertical scroller directional focus follows visual rows":
    var model = directionalModel(LayoutMode.VerticalScroller, 3)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirDown) == 2
    check model.focusDirection(Direction.DirUp) == 1

    let tagId = model.activeTag
    let firstColumn = model.columnAt(tagId, 0)
    let second = model.windowForExternal(ExternalWindowId(2))
    discard model.moveWindowToColumn(tagId, second, firstColumn, 1)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirRight) == 2
    check model.focusDirection(Direction.DirLeft) == 1

  test "Scroller directional focus enters adjacent stacked column":
    var model = directionalModel(LayoutMode.Scroller, 5)
    let tagId = model.activeTag
    let middleColumn = model.columnAt(tagId, 1)
    let third = model.windowForExternal(ExternalWindowId(3))
    discard model.moveWindowToColumn(tagId, third, middleColumn, 1)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirRight) in [2'u32, 3'u32]

    model.focusExternal(4)
    check model.focusDirection(Direction.DirLeft) in [2'u32, 3'u32]

  test "Scroller up down focus stays within current column stack":
    var model = directionalModel(LayoutMode.Scroller, 5)
    let tagId = model.activeTag
    let middleColumn = model.columnAt(tagId, 1)
    let third = model.windowForExternal(ExternalWindowId(3))
    discard model.moveWindowToColumn(tagId, third, middleColumn, 1)

    model.focusExternal(1)
    check model.focusDirection(Direction.DirDown) == 1
    check model.focusDirection(Direction.DirUp) == 1

    model.focusExternal(2)
    check model.focusDirection(Direction.DirDown) == 3
    check model.focusDirection(Direction.DirUp) == 2

    model.focusExternal(3)
    check model.focusDirection(Direction.DirUp) == 2
    check model.focusDirection(Direction.DirDown) == 3

  test "Master layouts use visual directional focus":
    var tile = directionalModel(LayoutMode.MasterStack, 3)
    tile.focusExternal(1)
    check tile.focusDirection(Direction.DirRight) == 3
    check tile.focusDirection(Direction.DirUp) == 2

    var vertical = directionalModel(LayoutMode.VerticalTile, 3)
    vertical.focusExternal(1)
    check vertical.focusDirection(Direction.DirDown) == 3

    var rightTile = directionalModel(LayoutMode.RightTile, 3)
    rightTile.focusExternal(1)
    check rightTile.focusDirection(Direction.DirLeft) == 3

    var centerTile = directionalModel(LayoutMode.CenterTile, 5)
    centerTile.focusExternal(1)
    check centerTile.focusDirection(Direction.DirLeft) == 4
    centerTile.focusExternal(1)
    check centerTile.focusDirection(Direction.DirRight) == 5

  test "Overlapping layouts use ordered directional fallback":
    var deck = directionalModel(LayoutMode.Deck, 3)
    deck.focusExternal(2)
    check deck.focusDirection(Direction.DirDown) == 3
    check deck.focusDirection(Direction.DirUp) == 2

    var verticalDeck = directionalModel(LayoutMode.VerticalDeck, 3)
    verticalDeck.focusExternal(2)
    check verticalDeck.focusDirection(Direction.DirRight) == 3
    check verticalDeck.focusDirection(Direction.DirLeft) == 2

    var monocle = directionalModel(LayoutMode.Monocle, 3)
    monocle.focusExternal(1)
    check monocle.focusDirection(Direction.DirRight) == 2
    check monocle.focusDirection(Direction.DirLeft) == 1

  test "Render visibility suppresses clipped scroller border rails":
    let screen = runtime_values.Rect(x: 0, y: 0, w: 100, h: 80)

    let full =
      renderVisibility(runtime_values.Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)
    check full.visible
    check not full.clipped
    check full.borderEdges == RenderAllEdges

    let leftClip =
      renderVisibility(runtime_values.Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    check leftClip.visible
    check leftClip.clipped
    check (leftClip.borderEdges and RenderEdgeLeft) == 0
    check (leftClip.borderEdges and RenderEdgeRight) == 0
    let leftClips = leftClip.renderClipBoxes(3)
    check leftClips.contentX == 20
    check leftClips.contentY == 0
    check leftClips.contentW == 40
    check leftClips.contentH == 30
    check leftClips.windowX == 20
    check leftClips.windowW == 40
    check leftClips.windowY == -3
    check leftClips.windowH == 36

    let sliver =
      renderVisibility(runtime_values.Rect(x: -98, y: 10, w: 100, h: 30), screen, 4)
    check not sliver.visible
    check sliver.borderEdges == 0

  test "Forced cell clipping preserves border space":
    let screen = runtime_values.Rect(x: 0, y: 0, w: 100, h: 80)
    let cell =
      renderVisibility(runtime_values.Rect(x: 10, y: 10, w: 40, h: 30), screen, 4)

    let clips = cell.renderClipBoxes(3)
    check clips.contentX == 0
    check clips.contentY == 0
    check clips.contentW == 40
    check clips.contentH == 30
    check clips.windowX == -3
    check clips.windowY == -3
    check clips.windowW == 46
    check clips.windowH == 36

    let clipped =
      renderVisibility(runtime_values.Rect(x: -20, y: 10, w: 60, h: 30), screen, 4)
    let clippedBoxes = clipped.renderClipBoxes(3)
    check clippedBoxes.contentX == 20
    check clippedBoxes.contentW == 40
    check clippedBoxes.windowX == 20
    check clippedBoxes.windowW == 40
    check clippedBoxes.windowY == -3
    check clippedBoxes.windowH == 36
