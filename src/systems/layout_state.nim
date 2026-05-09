import algorithm, tables
import ../core/model
import ../core/model_utils
import ../layouts/scroller
import ../layouts/tiling
import ../types/layout_projection

proc primaryScreen*(model: Model): Rect =
  if model.primaryOutput != 0 and model.outputs.hasKey(model.primaryOutput):
    let output = model.outputs[model.primaryOutput]
    if output.hasUsable and output.usableW > 0 and output.usableH > 0:
      return Rect(
        x: output.usableX,
        y: output.usableY,
        w: output.usableW,
        h: output.usableH)
    Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  else:
    Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc activeFocus*(model: Model): WindowId =
  if model.isScratchpadVisible:
    if model.visibleScratchpad != 0:
      return model.visibleScratchpad
    if model.scratchpadWindows.len > 0:
      return model.scratchpadWindows[^1]
  model.focusedOnActiveTag()

proc tiledTagState*(tag: TagState; model: Model): TagState =
  result = tag
  result.columns = @[]
  for col in tag.columns:
    var filteredWindows: seq[WindowId] = @[]
    for winId in col.windows:
      let isFloating =
        model.windows.hasKey(winId) and model.windows[winId].isFloating
      let isMinimized =
        model.windows.hasKey(winId) and model.windows[winId].isMinimized

      var isHiddenInGroup = false
      for group in model.groups.values:
        if group.windows.contains(winId) and group.activeWindow != winId:
          isHiddenInGroup = true
          break

      if not isFloating and not isHiddenInGroup and not isMinimized:
        filteredWindows.add(winId)
    if filteredWindows.len > 0:
      var filteredCol = col
      filteredCol.windows = filteredWindows
      result.columns.add(filteredCol)

proc layoutForTag(
    tag: var TagState; windows: Table[WindowId, WindowData]; screen: Rect;
    outerGap, innerGap: int32; focusCenter, preferCenter: bool;
    centerMode: string): seq[RenderInstruction] =
  case tag.layoutMode
  of Scroller:
    layoutScroller(
      tag,
      windows,
      screen,
      outerGap,
      innerGap,
      focusCenter,
      preferCenter,
      centerMode)
  of VerticalScroller:
    layoutVerticalScroller(
      tag,
      windows,
      screen,
      outerGap,
      innerGap,
      focusCenter,
      preferCenter,
      centerMode)
  of MasterStack:
    layoutMasterStack(tag, screen, outerGap, innerGap)
  of Grid:
    layoutGrid(tag, screen, outerGap, innerGap)
  of Monocle:
    layoutMonocle(tag, screen, outerGap)
  of Deck:
    layoutDeck(tag, screen, outerGap, innerGap)
  of CenterTile:
    layoutCenterTile(tag, screen, outerGap, innerGap)
  of RightTile:
    layoutRightTile(tag, screen, outerGap, innerGap)
  of VerticalTile:
    layoutVerticalMasterStack(tag, screen, outerGap, innerGap)
  of VerticalGrid:
    layoutVerticalGrid(tag, screen, outerGap, innerGap)
  of VerticalDeck:
    layoutVerticalDeck(tag, screen, outerGap, innerGap)

proc layoutProjection*(model: Model): LayoutProjection =
  let screen = model.primaryScreen()

  if model.overviewActive:
    var overviewTag = TagState(tagId: 0, layoutMode: Grid)
    var tagIds: seq[uint32] = @[]
    for id in model.tags.keys:
      tagIds.add(id)
    tagIds.sort()
    for id in tagIds:
      let tag = model.tags[id]
      for col in tag.columns:
        for win in col.windows:
          if model.windows.hasKey(win) and not model.windows[win].isMinimized:
            overviewTag.columns.add(Column(
              windows: @[win],
              widthProportion: 1.0))

    result.instructions = layoutGrid(
      overviewTag,
      screen,
      max(0'i32, model.overview.outerGap),
      max(0'i32, int32(float32(model.innerGaps) *
        model.overview.innerGapMultiplier)))

  elif model.tags.hasKey(model.activeTag):
    let tag = model.tags[model.activeTag]
    let tiledTag = tag.tiledTagState(model)

    var currentOuterGap = model.outerGaps
    var currentInnerGap = model.innerGaps

    var tiledWindowCount = 0
    for col in tiledTag.columns:
      tiledWindowCount += col.windows.len

    if model.smartGaps and tiledWindowCount <= 1:
      currentOuterGap = 0
      currentInnerGap = 0

    var tagForLayout = tiledTag
    result.instructions = layoutForTag(
      tagForLayout,
      model.windows,
      screen,
      currentOuterGap,
      currentInnerGap,
      model.scrollerFocusCenter,
      model.scrollerPreferCenter,
      model.centerFocusedColumn)
    result.viewportTargets.add(LayoutViewportTarget(
      tagSlot: model.activeTag,
      targetX: tagForLayout.targetViewportXOffset,
      targetY: tagForLayout.targetViewportYOffset))

    for col in tag.columns:
      for winId in col.windows:
        if model.windows.hasKey(winId):
          let winData = model.windows[winId]
          if winData.isFloating and not winData.isMinimized:
            result.instructions.add(RenderInstruction(
              windowId: winId,
              geom: winData.floatingGeom))

    if model.isScratchpadVisible and model.scratchpadWindows.len > 0:
      let winId =
        if model.visibleScratchpad != 0:
          model.visibleScratchpad
        else:
          model.scratchpadWindows[^1]
      if model.windows.hasKey(winId):
        let sw = int32(float32(screen.w) * model.scratchpadWidthRatio)
        let sh = int32(float32(screen.h) * model.scratchpadHeightRatio)
        result.instructions.add(RenderInstruction(
          windowId: winId,
          geom: Rect(
            x: screen.x + (screen.w - sw) div 2,
            y: screen.y + (screen.h - sh) div 2,
            w: sw,
            h: sh)))

    let focused = model.activeFocus()
    if focused != 0 and model.windows.hasKey(focused) and
        (model.windows[focused].isFullscreen or
        model.windows[focused].isMaximized):
      result.instructions = @[
        RenderInstruction(windowId: focused, geom: screen)]

proc applyLayoutProjection*(model: var Model; projection: LayoutProjection) =
  for target in projection.viewportTargets:
    if model.tags.hasKey(target.tagSlot):
      var tag = model.tags[target.tagSlot]
      tag.targetViewportXOffset = target.targetX
      tag.targetViewportYOffset = target.targetY
      model.tags[target.tagSlot] = tag

proc layoutInstructions*(model: var Model): seq[RenderInstruction] =
  let projection = model.layoutProjection()
  model.applyLayoutProjection(projection)
  projection.instructions
