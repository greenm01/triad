import std/[tables, unittest]
import ../src/layouts/[grid_math, scroller]
import ../src/types/projection_values

suite "Layout Algorithm Math":
  setup:
    let screen = Rect(x: 0, y: 0, w: 1000, h: 1000)
    let outerGap = 10.int32
    let innerGap = 20.int32

  test "layoutScroller calculates correct pixel boundaries":
    var tag =
      ProjectedTag(tagId: 1, layoutMode: LayoutMode.Scroller, focusedWindow: 101)
    # usableWidth = 1000 - 2*10 = 980
    # colWidth = 980 * 0.5 = 490
    tag.columns.add(ProjectedColumn(windows: @[101], widthProportion: 0.5))
    tag.columns.add(ProjectedColumn(windows: @[102], widthProportion: 0.5))

    var windows = initTable[ProjectionWindowId, ProjectedWindow]()
    windows[101] = ProjectedWindow(id: 101, heightProportion: 1.0)
    windows[102] = ProjectedWindow(id: 102, heightProportion: 1.0)

    let instructions =
      layoutScroller(tag, windows, screen, outerGap, innerGap, false, false, "never")

    check instructions.len == 2

    # First window: x=10, w = 490 - 20 = 470
    check instructions[0].windowId == 101
    check instructions[0].geom.x == 10
    check instructions[0].geom.w == 470

    # Second window: x = 10 + 490 = 500, w = 470
    check instructions[1].windowId == 102
    check instructions[1].geom.x == 500
    check instructions[1].geom.w == 470

  test "overview grid navigation follows row-major cells":
    check gridDimensions(5) == (cols: 3, rows: 2)
    check gridIndexByDelta(0, 5, 1, 0) == 1
    check gridIndexByDelta(1, 5, -1, 0) == 0
    check gridIndexByDelta(1, 5, 0, 1) == 4
    check gridIndexByDelta(4, 5, 0, -1) == 1
    check gridIndexByDelta(2, 5, 0, 1) == 4
    check gridIndexByDelta(4, 5, 1, 0) == -1
    check gridDimensions(8) == (cols: 3, rows: 3)
    check gridIndexByDelta(3, 8, 0, 1) == 6
    check gridIndexByDelta(6, 8, 0, -1) == 3
