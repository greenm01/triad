import algorithm, options, tables
import ../layouts/scroller
import ../layouts/tiling
import ../state/engine
import ../types/core as dod_core
import ../types/legacy_model as legacy

proc externalWindowId(model: DodModel; winId: dod_core.WindowId):
    legacy.WindowId =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacy.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc primaryScreen*(model: DodModel): legacy.Rect =
  if model.primaryOutput != NullOutputId:
    let outputOpt = model.outputData(model.primaryOutput)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return legacy.Rect(
          x: output.usableX,
          y: output.usableY,
          w: output.usableW,
          h: output.usableH)
      return legacy.Rect(x: output.x, y: output.y, w: output.w, h: output.h)

  legacy.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc activeFocus*(model: DodModel): dod_core.WindowId =
  if model.isScratchpadVisible:
    if model.visibleScratchpad != NullWindowId:
      return model.visibleScratchpad
    if model.scratchpadWindows.len > 0:
      return model.scratchpadWindows[^1]
  if model.activeTag == NullTagId:
    return NullWindowId
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().focusedWindow
  NullWindowId

proc legacyWindowTable(
    model: DodModel): Table[legacy.WindowId, legacy.WindowData] =
  for winId, win in model.windowsWithId():
    result[model.externalWindowId(winId)] = legacy.WindowData(
      id: model.externalWindowId(winId),
      title: win.title,
      appId: win.appId,
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      fullscreenOutput: uint32(win.fullscreenOutput),
      parentId: legacy.WindowId(uint32(win.parentExternalId)),
      identifier: win.identifier,
      actualW: win.actualW,
      actualH: win.actualH,
      minWidth: win.minWidth,
      minHeight: win.minHeight,
      maxWidth: win.maxWidth,
      maxHeight: win.maxHeight,
      hasDecorationHint: win.hasDecorationHint,
      decorationHint: win.decorationHint,
      hasPresentationHint: win.hasPresentationHint,
      presentationHint: win.presentationHint,
      floatingGeom: win.floatingGeom,
      keyboardShortcutsInhibit: win.keyboardShortcutsInhibit,
      keyboardShortcutsInhibitBypass: win.keyboardShortcutsInhibitBypass)

proc projectedTag(model: DodModel; tagId: dod_core.TagId):
    tuple[found: bool, tag: legacy.TagState] =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return (false, legacy.TagState())

  let tag = tagOpt.get()
  result.found = true
  result.tag = legacy.TagState(
    tagId: tag.slot,
    name: tag.name,
    layoutMode: tag.layoutMode,
    focusedWindow: model.externalWindowId(tag.focusedWindow),
    targetViewportXOffset: tag.targetViewportXOffset,
    currentViewportXOffset: tag.currentViewportXOffset,
    targetViewportYOffset: tag.targetViewportYOffset,
    currentViewportYOffset: tag.currentViewportYOffset,
    masterCount: tag.masterCount,
    masterSplitRatio: tag.masterSplitRatio)

  for _, column in model.columnsOnTagWithId(tagId):
    var windows: seq[legacy.WindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(column.id):
      if not win.isFloating and not win.isMinimized:
        windows.add(model.externalWindowId(winId))
    if windows.len > 0:
      result.tag.columns.add(legacy.Column(
        windows: windows,
        widthProportion: column.widthProportion))

proc layoutForTag(
    tag: var legacy.TagState;
    windows: Table[legacy.WindowId, legacy.WindowData]; screen: legacy.Rect;
    outerGap, innerGap: int32; focusCenter, preferCenter: bool;
    centerMode: string): seq[legacy.RenderInstruction] =
  case tag.layoutMode
  of legacy.Scroller:
    layoutScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter,
      centerMode)
  of legacy.VerticalScroller:
    layoutVerticalScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter,
      centerMode)
  of legacy.MasterStack:
    layoutMasterStack(tag, screen, outerGap, innerGap)
  of legacy.Grid:
    layoutGrid(tag, screen, outerGap, innerGap)
  of legacy.Monocle:
    layoutMonocle(tag, screen, outerGap)
  of legacy.Deck:
    layoutDeck(tag, screen, outerGap, innerGap)
  of legacy.CenterTile:
    layoutCenterTile(tag, screen, outerGap, innerGap)
  of legacy.RightTile:
    layoutRightTile(tag, screen, outerGap, innerGap)
  of legacy.VerticalTile:
    layoutVerticalMasterStack(tag, screen, outerGap, innerGap)
  of legacy.VerticalGrid:
    layoutVerticalGrid(tag, screen, outerGap, innerGap)
  of legacy.VerticalDeck:
    layoutVerticalDeck(tag, screen, outerGap, innerGap)

proc dodLayoutInstructions*(model: var DodModel):
    seq[legacy.RenderInstruction] =
  let screen = model.primaryScreen()
  let windows = model.legacyWindowTable()

  if model.overviewActive:
    var overviewTag = legacy.TagState(tagId: 0, layoutMode: legacy.Grid)
    var slots = model.sortedSlots()
    slots.sort()
    for slot in slots:
      let tagId = model.tagForSlot(slot)
      if tagId == NullTagId:
        continue
      for winId, win in model.windowsOnTagWithId(tagId):
        if not win.isMinimized:
          overviewTag.columns.add(legacy.Column(
            windows: @[model.externalWindowId(winId)],
            widthProportion: 1.0))
    return layoutGrid(
      overviewTag,
      screen,
      max(0'i32, model.overviewOuterGap),
      max(0'i32, int32(float32(model.innerGaps) *
        model.overviewInnerGapMultiplier)))

  if model.activeTag == NullTagId:
    return @[]

  let projected = model.projectedTag(model.activeTag)
  if not projected.found:
    return @[]

  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for col in projected.tag.columns:
    tiledWindowCount += col.windows.len

  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0

  var tagForLayout = projected.tag
  result = layoutForTag(
    tagForLayout,
    windows,
    screen,
    currentOuterGap,
    currentInnerGap,
    model.scrollerFocusCenter,
    model.scrollerPreferCenter,
    model.centerFocusedColumn)

  discard model.setTagViewportTarget(
    model.activeTag,
    tagForLayout.targetViewportXOffset,
    tagForLayout.targetViewportYOffset)

  for winId, win in model.windowsOnTagWithId(model.activeTag):
    if win.isFloating and not win.isMinimized:
      result.add(legacy.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: win.floatingGeom))

  if model.isScratchpadVisible and model.scratchpadWindows.len > 0:
    let winId =
      if model.visibleScratchpad != NullWindowId:
        model.visibleScratchpad
      else:
        model.scratchpadWindows[^1]
    if model.windowData(winId).isSome:
      let sw = int32(float32(screen.w) * model.dodScratchpadWidthRatio())
      let sh = int32(float32(screen.h) * model.dodScratchpadHeightRatio())
      result.add(legacy.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: legacy.Rect(
          x: screen.x + (screen.w - sw) div 2,
          y: screen.y + (screen.h - sh) div 2,
          w: sw,
          h: sh)))

  let focused = model.activeFocus()
  let focusedOpt = model.windowData(focused)
  if focusedOpt.isSome:
    let win = focusedOpt.get()
    if win.isFullscreen or win.isMaximized:
      result = @[legacy.RenderInstruction(
        windowId: model.externalWindowId(focused),
        geom: screen)]
