import std/algorithm
import tcore_support
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/types/janet_layouts

proc geomWithinPreview(geom, preview: Rect): bool =
  geom.x >= preview.x and geom.y >= preview.y and
    geom.x + geom.w <= preview.x + preview.w and geom.y + geom.h <= preview.y + preview.h

proc rectsIntersect(a, b: Rect): bool =
  a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y

proc intersection(a, b: Rect): Rect =
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.w, b.x + b.w)
  let y2 = min(a.y + a.h, b.y + b.h)
  if x2 <= x1 or y2 <= y1:
    return Rect(x: x1, y: y1, w: 0, h: 0)
  Rect(x: x1, y: y1, w: x2 - x1, h: y2 - y1)

proc positiveArea(geom: Rect): bool =
  geom.w > 0 and geom.h > 0

proc centerX(geom: Rect): int32 =
  geom.x + geom.w div 2

proc centerY(geom: Rect): int32 =
  geom.y + geom.h div 2

proc near(a, b: int32, tolerance = 1'i32): bool =
  abs(a - b) <= tolerance

proc aspectRatio(geom: Rect): float32 =
  float32(geom.w) / float32(max(1'i32, geom.h))

proc aspectRatioClose(geom: Rect, expected: float32, tolerance = 0.02'f32): bool =
  abs(geom.aspectRatio() - expected) <= tolerance

proc horizontalOverviewLane(screen, preview: Rect): Rect =
  Rect(x: screen.x, y: preview.y, w: screen.w, h: preview.h)

proc markColumnsFullWidth(model: var Model, slot: uint32) =
  let tagId = model.tagForSlot(slot)
  for columnId, _ in model.columnsOnTagWithId(tagId):
    discard model.setColumnFullWidth(columnId, true)

proc allLayoutModes(): seq[LayoutMode] =
  @[
    LayoutMode.Scroller, LayoutMode.VerticalScroller, LayoutMode.MasterStack,
    LayoutMode.Grid, LayoutMode.Monocle, LayoutMode.Deck, LayoutMode.CenterTile,
    LayoutMode.RightTile, LayoutMode.VerticalTile, LayoutMode.VerticalGrid,
    LayoutMode.VerticalDeck, LayoutMode.TGMix,
  ]

proc includesId(ids: openArray[uint32], id: uint32): bool =
  for candidate in ids:
    if candidate == id:
      return true

proc overviewInstructionsFor(
    instructions: openArray[RenderInstruction], ids: openArray[uint32]
): seq[RenderInstruction] =
  for instr in instructions:
    if ids.includesId(uint32(instr.windowId)):
      result.add(instr)

proc overviewInstructionGeom(
    instructions: openArray[RenderInstruction], id: uint32
): Rect =
  for instr in instructions:
    if uint32(instr.windowId) == id:
      return instr.geom
  Rect()

proc checkOverviewGroup(
    instructions: openArray[RenderInstruction],
    ids: openArray[uint32],
    clip: Rect,
    otherPreviews: openArray[Rect],
    requireRawInsideClip = true,
): seq[RenderInstruction] =
  result = instructions.overviewInstructionsFor(ids)
  check result.len == ids.len
  check result.allIt(it.clipSet)
  check result.allIt(it.clip == clip)
  if requireRawInsideClip:
    check result.allIt(it.geom.geomWithinPreview(clip))
  check result.allIt(it.geom.intersection(clip).geomWithinPreview(clip))
  for otherPreview in otherPreviews:
    check result.allIt(not it.geom.intersection(clip).rectsIntersect(otherPreview))

suite "Core Runtime Logic: overview navigation":
  test "Opening overview initializes visible selection":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    let effects = model.updateModel(Msg(kind: MsgKind.CmdOpenOverview))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Overview tab mode opens, cycles with opener, and closes on modifier release":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2),
        overview: OverviewConfig(tabMode: true),
      )
    ).model
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))

    discard
      model.updateModel(Msg(kind: MsgKind.CmdOverviewTab, overviewTabModifiers: 64'u32))

    check model.overviewActive
    check model.overviewTabModeActive
    check model.overviewTabModeModifiers == 64'u32
    check model.selectedOverviewWindow() == WindowId(1)

    discard
      model.updateModel(Msg(kind: MsgKind.CmdOverviewTab, overviewTabModifiers: 64'u32))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == WindowId(2)

    let effects = model.updateModel(
      Msg(kind: MsgKind.WlModifiersChanged, oldModifiers: 64'u32, newModifiers: 0)
    )

    check not model.overviewActive
    check not model.overviewTabModeActive
    check model.overviewTabModeModifiers == 0'u32
    check model.focusedWindowId() == 2
    check effects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 2
    )

  test "Overview tab command is ignored while tab mode is off":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdOverviewTab, overviewTabModifiers: 64'u32))

    check not model.overviewActive
    check not model.overviewTabModeActive
    check effects.len == 0

  test "Overview shell focus clear preserves selected window":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects = model.updateModel(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 0))

    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(1)
    check model.focusedWindowId() == 1
    check model.activeWorkspaceFocusId() == 1
    check effects.len == 0

  test "Overview hit testing uses topmost preview under pointer":
    let instructions =
      @[
        RenderInstruction(windowId: 1, geom: Rect(x: 0, y: 0, w: 100, h: 100)),
        RenderInstruction(windowId: 2, geom: Rect(x: 50, y: 50, w: 100, h: 100)),
        RenderInstruction(windowId: 3, geom: Rect(x: 200, y: 50, w: 100, h: 100)),
      ]

    check overviewHitTest(instructions, 10, 10) == 1
    check overviewHitTest(instructions, 60, 60) == 2
    check overviewHitTest(instructions, 220, 70) == 3
    check overviewHitTest(instructions, 400, 400) == 0

  test "Overview hit testing ignores clipped preview overflow":
    let instructions =
      @[
        RenderInstruction(
          windowId: 1,
          geom: Rect(x: 0, y: 0, w: 100, h: 200),
          clipSet: true,
          clip: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
        RenderInstruction(
          windowId: 2,
          geom: Rect(x: 0, y: 100, w: 100, h: 100),
          clipSet: true,
          clip: Rect(x: 0, y: 100, w: 100, h: 100),
        ),
      ]

    check overviewHitTest(instructions, 10, 50) == 1
    check overviewHitTest(instructions, 10, 150) == 2

  test "Scroller overview projects workspace previews":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let one = projection.instructions.filterIt(uint32(it.windowId) == 1)[0].geom
    let two = projection.instructions.filterIt(uint32(it.windowId) == 2)[0].geom
    let activePreview = model.workspacePreviewRect(screen, slots, 0)
    let secondPreview = model.workspacePreviewRect(screen, slots, 1)

    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check one.x >= activePreview.x
    check one.y >= activePreview.y
    check one.x + one.w <= activePreview.x + activePreview.w
    check one.y + one.h <= activePreview.y + activePreview.h
    check two.x >= secondPreview.x
    check two.y >= secondPreview.y
    check two.x + two.w <= secondPreview.x + secondPreview.w
    check two.y + two.h <= secondPreview.y + secondPreview.h

  test "Scroller overview fits the full horizontal strip":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.markColumnsFullWidth(1)
    model.setViewport(1, targetX = 1000.0, currentX = 1000.0)
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let activeLane =
      Rect(x: screen.x, y: activePreview.y, w: screen.w, h: activePreview.h)
    let usableWidth = max(1'i32, screen.w - 2 * model.outerGaps)
    let usableHeight = max(1'i32, screen.h - 2 * model.outerGaps)
    let expectedAspect = float32(usableWidth - model.innerGaps) / float32(usableHeight)
    let workspaceOne =
      projection.instructions.filterIt(uint32(it.windowId) in @[1'u32, 2'u32, 3'u32])
    var geoms = workspaceOne.mapIt(it.geom)
    geoms.sort(
      proc(a, b: Rect): int =
        cmp(a.x, b.x)
    )

    check workspaceOne.len == 3
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == activeLane)
    check workspaceOne.allIt(
      it.geom.intersection(activeLane).geomWithinPreview(activeLane)
    )
    check workspaceOne.countIt(it.geom.intersection(activeLane).positiveArea()) >= 2
    check geoms.anyIt(it.h >= activePreview.h - 20)
    check geoms[0].x < geoms[1].x
    check geoms[1].x < geoms[2].x
    check geoms.allIt(it.aspectRatioClose(expectedAspect))

  test "Vertical scroller overview fits the full vertical strip":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.markColumnsFullWidth(1)
    model.setViewport(
      1, targetX = 0.0, currentX = 0.0, targetY = 700.0, currentY = 700.0
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let usableWidth = max(1'i32, screen.w - 2 * model.outerGaps)
    let usableHeight = max(1'i32, screen.h - 2 * model.outerGaps)
    let expectedAspect = float32(usableWidth) / float32(usableHeight - model.innerGaps)
    let workspaceOne =
      projection.instructions.filterIt(uint32(it.windowId) in @[1'u32, 2'u32, 3'u32])
    var geoms = workspaceOne.mapIt(it.geom)
    geoms.sort(
      proc(a, b: Rect): int =
        cmp(a.y, b.y)
    )

    check workspaceOne.len == 3
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == activePreview)
    check workspaceOne.allIt(
      it.geom.intersection(activePreview).geomWithinPreview(activePreview)
    )
    check workspaceOne.countIt(it.geom.intersection(activePreview).positiveArea()) >= 1
    check geoms[0].y < geoms[1].y
    check geoms[1].y < geoms[2].y
    check geoms.allIt(it.aspectRatioClose(expectedAspect))

  test "Scroller overview centers focused edge columns on screen":
    var firstModel = configuredModel()
    firstModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    for id in 1'u32 .. 3'u32:
      firstModel.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    firstModel.markColumnsFullWidth(1)
    firstModel.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    firstModel.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let firstScreen = firstModel.primaryScreen()
    let firstSlots = firstModel.previewSlots()
    let firstPreview =
      firstModel.workspacePreviewRect(firstScreen, firstSlots, firstSlots.find(1'u32))
    let firstLane =
      Rect(x: firstScreen.x, y: firstPreview.y, w: firstScreen.w, h: firstPreview.h)
    let firstProjection = firstModel.layoutProjection()
    let firstGeom = firstProjection.instructions.overviewInstructionGeom(1)

    check firstGeom.centerX().near(firstLane.centerX())
    check firstProjection.instructions.overviewInstructionGeom(2).centerX() >
      firstGeom.centerX()

    var lastModel = configuredModel()
    lastModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    for id in 1'u32 .. 3'u32:
      lastModel.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    lastModel.markColumnsFullWidth(1)
    lastModel.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    lastModel.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let lastScreen = lastModel.primaryScreen()
    let lastSlots = lastModel.previewSlots()
    let lastPreview =
      lastModel.workspacePreviewRect(lastScreen, lastSlots, lastSlots.find(1'u32))
    let lastLane =
      Rect(x: lastScreen.x, y: lastPreview.y, w: lastScreen.w, h: lastPreview.h)
    let lastProjection = lastModel.layoutProjection()
    let lastGeom = lastProjection.instructions.overviewInstructionGeom(3)

    check lastGeom.centerX().near(lastLane.centerX())
    check lastProjection.instructions.overviewInstructionGeom(2).centerX() <
      lastGeom.centerX()

  test "Vertical scroller overview centers focused edge rows in preview":
    var firstModel = configuredModel()
    firstModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    firstModel.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 1'u32 .. 3'u32:
      firstModel.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    firstModel.markColumnsFullWidth(1)
    firstModel.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    firstModel.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let firstScreen = firstModel.primaryScreen()
    let firstSlots = firstModel.previewSlots()
    let firstPreview =
      firstModel.workspacePreviewRect(firstScreen, firstSlots, firstSlots.find(1'u32))
    let firstProjection = firstModel.layoutProjection()
    let firstGeom = firstProjection.instructions.overviewInstructionGeom(1)

    check firstGeom.centerY().near(firstPreview.centerY())
    check firstProjection.instructions.overviewInstructionGeom(2).centerY() >
      firstGeom.centerY()

    var lastModel = configuredModel()
    lastModel.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    lastModel.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 1'u32 .. 3'u32:
      lastModel.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    lastModel.markColumnsFullWidth(1)
    lastModel.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))
    lastModel.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let lastScreen = lastModel.primaryScreen()
    let lastSlots = lastModel.previewSlots()
    let lastPreview =
      lastModel.workspacePreviewRect(lastScreen, lastSlots, lastSlots.find(1'u32))
    let lastProjection = lastModel.layoutProjection()
    let lastGeom = lastProjection.instructions.overviewInstructionGeom(3)

    check lastGeom.centerY().near(lastPreview.centerY())
    check lastProjection.instructions.overviewInstructionGeom(2).centerY() <
      lastGeom.centerY()

  test "Mixed layout overview previews stay isolated":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Scroller " & $id,
        )
      )
    model.markColumnsFullWidth(1)
    model.setViewport(1, targetX = 1000.0, currentX = 1000.0)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 4'u32 .. 6'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Vertical " & $id,
        )
      )
    model.markColumnsFullWidth(2)
    model.setViewport(
      2, targetX = 0.0, currentX = 0.0, targetY = 700.0, currentY = 700.0
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    for id in 7'u32 .. 9'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Grid " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let scrollerPreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let scrollerLane = horizontalOverviewLane(screen, scrollerPreview)
    let verticalPreview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let gridPreview = model.workspacePreviewRect(screen, slots, slots.find(3'u32))
    let gridLane = horizontalOverviewLane(screen, gridPreview)

    discard projection.instructions.checkOverviewGroup(
      [1'u32, 2'u32, 3'u32],
      scrollerLane,
      [verticalPreview, gridPreview],
      requireRawInsideClip = false,
    )
    discard projection.instructions.checkOverviewGroup(
      [4'u32, 5'u32, 6'u32],
      verticalPreview,
      [scrollerLane, gridPreview],
      requireRawInsideClip = false,
    )
    let gridGroup = projection.instructions.checkOverviewGroup(
      [7'u32, 8, 9],
      gridLane,
      [scrollerLane, verticalPreview],
      requireRawInsideClip = false,
    )
    check gridGroup.len == 3

  test "Overview clips overflowing workspace preview contents":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller)
    )
    for id in 2'u32 .. 4'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.setViewport(
      2, targetX = 0.0, currentX = 0.0, targetY = -700.0, currentY = -700.0
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let secondPreview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let workspaceTwo =
      projection.instructions.filterIt(uint32(it.windowId) in @[2'u32, 3'u32, 4'u32])

    check workspaceTwo.len == 3
    check workspaceTwo.allIt(it.clipSet)
    check workspaceTwo.allIt(it.clip == secondPreview)
    check workspaceTwo.allIt(
      it.geom.intersection(secondPreview).geomWithinPreview(secondPreview)
    )

  test "Non-scroller overview projects workspace previews":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let projection = model.layoutProjection()
    let activePreview = model.workspacePreviewRect(screen, slots, 0)
    let activeLane = horizontalOverviewLane(screen, activePreview)

    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check model.overviewUsesWorkspacePreviews()
    let workspaceOne = projection.instructions.overviewInstructionsFor([1'u32, 2])
    check workspaceOne.len == 2
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == activeLane)
    check workspaceOne.allIt(
      it.geom.intersection(activeLane).geomWithinPreview(activeLane)
    )

  test "Overview renders bundled Janet layout as finder strip":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("right-tile"))
    )
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let preview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let projection = model.layoutProjection()
    let workspaceTwo = projection.instructions.overviewInstructionsFor([1'u32, 2, 3])

    check workspaceTwo.len == 3
    check workspaceTwo.allIt(it.clipSet)
    check workspaceTwo.allIt(it.clip == lane)
    check workspaceTwo.allIt(it.geom.intersection(lane).geomWithinPreview(lane))

  test "Overview renders user Janet layout as finder strip without evaluator":
    let config = Config(
      janet: JanetConfig(
        layouts:
          @[
            JanetLayoutConfig(
              id: janetLayoutId("custom-overview"),
              fallback: builtinSelection(LayoutMode.Scroller),
            )
          ]
      ),
      workspaces: WorkspaceConfig(defaultCount: 3),
    )
    var model = initRuntimeStateFromConfig(config).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("custom-overview")
      )
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    var evaluated = false
    proc customEval(context: JanetLayoutContext): JanetLayoutEvalResult =
      evaluated = true
      JanetLayoutEvalResult(
        layoutId: context.layoutId,
        outcome: JanetLayoutOutcome.Applied,
        outputTargetKind: JanetLayoutTargetKind.Window,
        instructions:
          @[
            RenderInstruction(windowId: 1, geom: Rect(x: 700, y: 20, w: 200, h: 200)),
            RenderInstruction(windowId: 2, geom: Rect(x: 100, y: 20, w: 200, h: 200)),
          ],
      )

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let preview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let projection = model.layoutProjection(customEval)
    let workspaceOne = projection.instructions.overviewInstructionsFor([1'u32, 2])

    check not evaluated
    check workspaceOne.len == 2
    check workspaceOne.allIt(it.clipSet)
    check workspaceOne.allIt(it.clip == lane)
    check workspaceOne.allIt(it.geom.intersection(lane).geomWithinPreview(lane))

  test "Overview renders frame layouts as finder strips":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let frameWindows =
      model.layoutProjection().instructions.overviewInstructionsFor([1'u32, 2, 3])

    check frameWindows.len == 3
    check frameWindows.anyIt(it.windowId == 1'u32)
    check frameWindows.anyIt(it.windowId == 2'u32)
    check frameWindows.anyIt(it.windowId == 3'u32)

    discard model.updateModel(Msg(kind: MsgKind.WlFocusChanged, newFocusedId: 3))
    check not model.overviewActive
    check model.focusedWindowId() == 3

    var notion = configuredModel()
    notion.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    notion.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("notion"))
    )
    notion.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "app", title: "Four")
    )
    notion.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 5, appId: "app", title: "Five")
    )
    notion.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    notion.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 6, appId: "app", title: "Six")
    )
    notion.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let notionWindows =
      notion.layoutProjection().instructions.overviewInstructionsFor([4'u32, 5, 6])
    check notionWindows.len == 3
    check notionWindows.anyIt(it.windowId == 4'u32)
    check notionWindows.anyIt(it.windowId == 5'u32)
    check notionWindows.anyIt(it.windowId == 6'u32)

  test "Overview renders BSP layouts as finder strips":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "app", title: "Four")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 5, appId: "app", title: "Five")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 6, appId: "app", title: "Six")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let preview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let bspWindows =
      model.layoutProjection().instructions.overviewInstructionsFor([4'u32, 5, 6])

    check bspWindows.len == 3
    check bspWindows.allIt(it.geom.intersection(lane).geomWithinPreview(lane))
    check bspWindows.anyIt(it.windowId == 4'u32)
    check bspWindows.anyIt(it.windowId == 5'u32)
    check bspWindows.anyIt(it.windowId == 6'u32)

  test "Overview renders i3 split layouts as finder strips":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("i3"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 10))
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeSplitVertical))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let preview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let splitWindows =
      model.layoutProjection().instructions.overviewInstructionsFor([10'u32, 11, 12])

    check splitWindows.len == 3
    check splitWindows.allIt(it.clipSet)
    check splitWindows.allIt(it.clip == lane)
    check splitWindows.allIt(it.geom.intersection(lane).geomWithinPreview(lane))
    check splitWindows.anyIt(it.windowId == 10'u32)
    check splitWindows.anyIt(it.windowId == 11'u32)
    check splitWindows.anyIt(it.windowId == 12'u32)

  test "Overview renders i3 tabbed layouts as finder strips without tab chrome":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("i3"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeLayoutTabbed))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 10))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let preview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let projection = model.layoutProjection()
    let tabbedWindows =
      projection.instructions.overviewInstructionsFor([10'u32, 11, 12])

    check model.selectedOverviewWindow() == model.windowForExternal(
      ExternalWindowId(10)
    )
    check tabbedWindows.len == 3
    check tabbedWindows.allIt(it.clipSet)
    check tabbedWindows.allIt(it.clip == lane)
    check tabbedWindows.anyIt(it.windowId == 10'u32)
    check tabbedWindows.anyIt(it.windowId == 11'u32)
    check tabbedWindows.anyIt(it.windowId == 12'u32)
    check projection.frameTabBars.len == 0

  test "Overview exposes every i3 tabbed column window":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("i3"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "Two")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeSplitVertical))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 13, appId: "app", title: "Four")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdSplitTreeLayoutTabbed))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let projection = model.layoutProjection()
    let overviewWindows =
      projection.instructions.overviewInstructionsFor([10'u32, 11, 12, 13])

    check overviewWindows.len == 4
    check overviewWindows.allIt(positiveArea(it.geom))
    check projection.frameTabBars.len == 0

  test "Overview renders notion previews as finder strips without frame chrome":
    var notion = configuredModel()
    notion.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    notion.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("notion"))
    )
    notion.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "app", title: "Four")
    )
    notion.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    check notion.tagData(notion.activeTag).get().nativeLayoutId.nativeLayoutIdString() ==
      "frame-tree"
    notion.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let screen = notion.primaryScreen()
    let slots = notion.previewSlots()
    let preview = notion.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let lane = horizontalOverviewLane(screen, preview)
    let projection = notion.layoutProjection()
    let notionWindows = projection.instructions.overviewInstructionsFor([4'u32])

    check notionWindows.len == 1
    check notionWindows[0].clip == lane
    check notionWindows[0].geom.intersection(lane).geomWithinPreview(lane)
    check projection.frameTabBars.len == 0
    check projection.frameEmptyChrome.len == 0

  test "Overview overlay resolves bundled Janet badges and custom indicators":
    var bundled = configuredModel()
    bundled.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    bundled.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("deck"))
    )
    for id in 1'u32 .. 4'u32:
      bundled.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    bundled.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let bundledScreen = bundled.primaryScreen()
    let bundledSlots = bundled.previewSlots()
    let badge = bundled.overviewHiddenCountBadge(
      bundledScreen, bundledSlots, bundledSlots.find(1'u32)
    )
    check badge.count == 0

    let config = Config(
      janet: JanetConfig(
        layouts:
          @[
            JanetLayoutConfig(
              id: janetLayoutId("custom-overview"),
              fallback: builtinSelection(LayoutMode.Scroller),
            )
          ]
      ),
      workspaces: WorkspaceConfig(defaultCount: 3),
    )
    var custom = initRuntimeStateFromConfig(config).model
    custom.overviewScrollerIndicators = true
    custom.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    custom.applyMsg(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("custom-overview")
      )
    )
    for id in 1'u32 .. 3'u32:
      custom.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    custom.setViewport(1, targetX = 100.0, currentX = 100.0)
    custom.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let customScreen = custom.primaryScreen()
    let customSlots = custom.previewSlots()
    let indicator =
      custom.overviewScrollIndicator(customScreen, customSlots, customSlots.find(1'u32))
    check indicator.before
    check not indicator.after

  test "Overview finder includes floating windows":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(
        kind: MsgKind.CmdSetWindowFloatingById,
        floatingWindowId: 1,
        windowFloating: true,
      )
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let workspaceOne =
      model.layoutProjection().instructions.overviewInstructionsFor([1'u32])

    check workspaceOne.len == 1
    check workspaceOne[0].windowId == 1'u32

  test "Unified overview aggregate layout uses finder navigation":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid"))
    )
    for id in 1'u32 .. 5'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))

    let activeTag = model.activeTag
    check model.overviewActive
    check model.selectedOverviewWindow() == WindowId(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
    check model.activeTag == activeTag
    check model.focusedWindowId() == 3
    check model.selectedOverviewWindow() == WindowId(3)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusNext))
    check model.focusedWindowId() == 4
    check model.selectedOverviewWindow() == WindowId(4)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == NullWindowId

  test "Overview blocks frame commands while active":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    let tagId = model.activeTag
    let frameId = model.tagData(tagId).get().focusedFrame
    let frameCount = model.shellSnapshot().workspaces[0].frames.len
    let focused = model.focusedWindowId()
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    model.applyMsg(Msg(kind: MsgKind.CmdFrameTabNext))
    model.applyMsg(
      Msg(
        kind: MsgKind.WlFrameTabClicked,
        frameClickFrameId: uint32(frameId),
        frameClickTabIndex: 0,
      )
    )

    check model.overviewActive
    check model.activeTag == tagId
    check model.shellSnapshot().workspaces[0].frames.len == frameCount
    check model.focusedWindowId() == focused

  test "Unified overview scroller direction focus follows strip layout":
    var model = configuredModel()
    for id in 1'u32 .. 3'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let activeTag = model.activeTag

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let rightEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
    )
    check model.selectedOverviewWindow() == WindowId(2)
    check model.activeWorkspaceFocusId() == 2
    let previewSnapshot = model.shellSnapshot()
    check previewSnapshot.overviewSelectedWindow == 2
    check rightEffects.anyIt(it.kind == EffectKind.EffFocusShellUi)
    check not rightEffects.anyIt(it.kind == EffectKind.EffFocusWindow)
    check rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowFocusChanged")
    )
    check not rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspacesChanged")
    )
    check not rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowsChanged")
    )
    check rightEffects.anyIt(
      it.kind == EffectKind.EffBroadcastTriadJson and it.triadEventName == "state"
    )

    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusNext))
    check model.selectedOverviewWindow() == WindowId(2)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusPrev))
    check model.selectedOverviewWindow() == WindowId(1)

    check model.activeTag == activeTag

    let closeEffects = model.updateModel(Msg(kind: MsgKind.CmdCloseOverview))
    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == 1
    check closeEffects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 1
    )

  test "Unified overview horizontal boundary stays in focused workspace":
    for mode in allLayoutModes():
      var model = configuredModel()
      model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: mode))
      model.applyMsg(
        Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
      )
      model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
      model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))

      let activeTag = model.activeTag
      let leftEffects = model.updateModel(
        Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft)
      )

      check model.overviewActive
      check model.activeTag == activeTag
      check model.selectedOverviewWindow() == WindowId(1)
      check not leftEffects.anyIt(it.kind == EffectKind.EffManageDirty)
      check not leftEffects.anyIt(
        it.kind == EffectKind.EffBroadcastJson and
          it.jsonPayload.contains("WorkspaceActivated")
      )
      check not leftEffects.anyIt(
        it.kind == EffectKind.EffBroadcastJson and
          it.jsonPayload.contains("WorkspacesChanged")
      )

      let rightEffects = model.updateModel(
        Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
      )

      check model.overviewActive
      check model.activeTag == activeTag
      check model.selectedOverviewWindow() == WindowId(1)
      check not rightEffects.anyIt(it.kind == EffectKind.EffManageDirty)
      check not rightEffects.anyIt(
        it.kind == EffectKind.EffBroadcastJson and
          it.jsonPayload.contains("WorkspaceActivated")
      )
      check not rightEffects.anyIt(
        it.kind == EffectKind.EffBroadcastJson and
          it.jsonPayload.contains("WorkspacesChanged")
      )

  test "Unified overview vertical boundary still moves workspaces":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let upEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)
    )

    check model.overviewActive
    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(1)
    check upEffects.anyIt(it.kind == EffectKind.EffManageDirty)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    let downEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)
    )

    check model.overviewActive
    check model.activeTag == model.tagForSlot(3)
    check model.selectedOverviewWindow() == NullWindowId
    check downEffects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Unified overview empty workspace ignores horizontal arrows":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))

    let activeTag = model.activeTag
    check model.selectedOverviewWindow() == NullWindowId

    let leftEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft)
    )
    check model.activeTag == activeTag
    check model.selectedOverviewWindow() == NullWindowId
    check not leftEffects.anyIt(it.kind == EffectKind.EffManageDirty)

    let rightEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
    )
    check model.activeTag == activeTag
    check model.selectedOverviewWindow() == NullWindowId
    check not rightEffects.anyIt(it.kind == EffectKind.EffManageDirty)

    let upEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)
    )
    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(1)
    check upEffects.anyIt(it.kind == EffectKind.EffManageDirty)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    let downEffects = model.updateModel(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)
    )
    check model.activeTag == model.tagForSlot(3)
    check model.selectedOverviewWindow() == NullWindowId
    check downEffects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Unified overview keeps workspace focus commands live":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == WindowId(2)
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

    let downEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(3)
    check model.selectedOverviewWindow() == NullWindowId
    check downEffects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Unified overview workspace crossing updates shell workspaces":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1))
    let windowEffects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check windowEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )

    let navEffects = model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(3)
    check navEffects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WorkspaceActivated")
    )

  test "Unified overview aggregate up key moves workspace before internal grid":
    var model = configuredModel()
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    for id in 1'u32 .. 4'u32:
      model.applyMsg(
        Msg(
          kind: MsgKind.WlWindowCreated,
          windowId: id,
          appId: "app",
          title: "Window " & $id,
        )
      )
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 3))

    let effects = model.updateModel(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == NullWindowId
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)

  test "Unified overview workspace navigation visits visible previews and wraps":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(2)
    check model.activeWorkspaceFocusId() == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(3)
    check model.activeWorkspaceFocusId() == 3

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
    check model.activeTag == model.tagForSlot(4)
    check model.activeWorkspaceFocusId() == 0

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.activeTag == model.tagForSlot(1)
    check model.selectedOverviewWindow() == WindowId(1)

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
    check model.activeTag == model.tagForSlot(4)
    check model.activeWorkspaceFocusId() == 0

  test "Unified overview keeps workspace navigation live":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    let effects =
      model.updateModel(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 2
    check model.overviewSelectedWindow == NullWindowId
    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(it.kind == EffectKind.EffFocusShellUi)

  test "Unified overview keeps preview style after navigating to grid workspace":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid, layoutTargetTag: 2)
    )
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.overviewStyle() == OverviewStyle.WorkspaceStrip
    check model.overviewUsesWorkspacePreviews()

  test "Selecting empty overview workspace enters it without window fallback":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusTagRight))
    check model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.selectedOverviewWindow() == NullWindowId

    let effects = model.updateModel(Msg(kind: MsgKind.CmdSelectWindow))
    check not model.overviewActive
    check model.activeTag == model.tagForSlot(2)
    check model.focusedWindowId() == 0
    check model.activeWorkspaceFocusId() == 0
    check not effects.anyIt(it.kind == EffectKind.EffFocusWindow)

  test "Selecting overview window commits focus":
    var model = configuredModel()
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 2))
    model.applyMsg(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two")
    )
    model.applyMsg(Msg(kind: MsgKind.CmdFocusTag, focusTag: 1))
    model.applyMsg(Msg(kind: MsgKind.CmdOpenOverview))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 2))
    let effects = model.updateModel(Msg(kind: MsgKind.CmdSelectWindow))

    check not model.overviewActive
    check model.overviewSelectedWindow == NullWindowId
    check model.activeWorkspaceFocusId() == 2
    check model.activeTag == model.tagForSlot(2)
    check effects.anyIt(
      it.kind == EffectKind.EffFocusWindow and uint32(it.focusId) == 2
    )
