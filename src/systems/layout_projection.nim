import options, tables
import ../layouts/scroller
import ../layouts/tiling
import ../state/engine
import ../types/core as core_types
import ../types/layout_projection
import ../types/runtime_values as rv
import presentation_policy

proc externalWindowId(model: Model; winId: core_types.WindowId):
    rv.WindowId =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return rv.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc primaryScreen*(model: Model): rv.Rect =
  if model.primaryOutput != NullOutputId:
    let outputOpt = model.outputData(model.primaryOutput)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return rv.Rect(
          x: output.usableX,
          y: output.usableY,
          w: output.usableW,
          h: output.usableH)
      return rv.Rect(x: output.x, y: output.y, w: output.w, h: output.h)

  rv.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc activeFocus*(model: Model): core_types.WindowId =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return scratchpad
  if model.activeTag == NullTagId:
    return NullWindowId
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().focusedWindow
  NullWindowId

proc runtimeWindowTable(
    model: Model): Table[rv.WindowId, rv.WindowData] =
  for winId, win in model.windowsWithId():
    result[model.externalWindowId(winId)] = rv.WindowData(
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
      parentId: rv.WindowId(uint32(win.parentExternalId)),
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

proc projectedTag(model: Model; tagId: core_types.TagId):
    tuple[found: bool; tag: rv.TagState] =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return (false, rv.TagState())

  let tag = tagOpt.get()
  result.found = true
  result.tag = rv.TagState(
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
    var windows: seq[rv.WindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(column.id):
      if not win.isFloating and not win.isMinimized and
          not model.windowHiddenByGroup(winId):
        windows.add(model.externalWindowId(winId))
    if windows.len > 0:
      result.tag.columns.add(rv.Column(
        windows: windows,
        widthProportion: column.widthProportion))

proc layoutForTag(
    tag: var rv.TagState;
    windows: Table[rv.WindowId, rv.WindowData]; screen: rv.Rect;
    outerGap, innerGap: int32; focusCenter, preferCenter: bool;
    centerMode: string): seq[rv.RenderInstruction] =
  case tag.layoutMode
  of rv.LayoutMode.Scroller:
    layoutScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter,
      centerMode)
  of rv.LayoutMode.VerticalScroller:
    layoutVerticalScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter,
      centerMode)
  of rv.LayoutMode.MasterStack:
    layoutMasterStack(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.Grid:
    layoutGrid(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.Monocle:
    layoutMonocle(tag, screen, outerGap)
  of rv.LayoutMode.Deck:
    layoutDeck(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.CenterTile:
    layoutCenterTile(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.RightTile:
    layoutRightTile(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.VerticalTile:
    layoutVerticalMasterStack(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.VerticalGrid:
    layoutVerticalGrid(tag, screen, outerGap, innerGap)
  of rv.LayoutMode.VerticalDeck:
    layoutVerticalDeck(tag, screen, outerGap, innerGap)

proc activeFocusLayoutInstructions*(model: Model):
    seq[rv.RenderInstruction] =
  if model.activeTag == NullTagId:
    return

  let projected = model.projectedTag(model.activeTag)
  if not projected.found:
    return

  let screen = model.primaryScreen()
  let windows = model.runtimeWindowTable()
  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for col in projected.tag.columns:
    tiledWindowCount += col.windows.len

  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0

  let retargetViewport = model.viewportRetargetRequested(model.activeTag)
  var tagForLayout = projected.tag
  result = layoutForTag(
    tagForLayout,
    windows,
    screen,
    currentOuterGap,
    currentInnerGap,
    retargetViewport and model.scrollerFocusCenter,
    retargetViewport and model.scrollerPreferCenter,
    if retargetViewport: model.centerFocusedColumn else: "never")

  for winId, win in model.windowsOnTagWithId(model.activeTag):
    if win.isFloating and not win.isMinimized:
      result.add(rv.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: win.floatingGeom))

proc upsertInstruction(
    instructions: var seq[rv.RenderInstruction]; instruction:
    rv.RenderInstruction) =
  for idx, existing in instructions.mpairs:
    if existing.windowId == instruction.windowId:
      instructions[idx] = instruction
      return
  instructions.add(instruction)

proc activeFocusIsOverlay(model: Model; focused: core_types.WindowId): bool =
  if model.activeScratchpadWindow() != NullWindowId:
    return true
  let focusedOpt = model.windowData(focused)
  focusedOpt.isSome and focusedOpt.get().isFloating

proc preserveBackingPresentation(
    model: Model; instructions: var seq[rv.RenderInstruction];
    screen: rv.Rect) =
  let tagOpt = model.tagData(model.activeTag)
  let maxSupported = tagOpt.isSome and
    tagOpt.get().layoutMode.layoutSupportsMaximize()
  for winId, win in model.windowsOnTagWithId(model.activeTag):
    if not win.isFloating and not win.isMinimized and
        (win.isFullscreen or (win.isMaximized and maxSupported)):
      instructions.upsertInstruction(rv.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: screen))

proc layoutProjection*(model: Model): LayoutProjection =
  let screen = model.primaryScreen()
  let windows = model.runtimeWindowTable()

  if model.overviewActive:
    var overviewTag = rv.TagState(tagId: 0, layoutMode: rv.LayoutMode.Grid)
    for winId in model.overviewWindowIds():
      overviewTag.columns.add(rv.Column(
        windows: @[model.externalWindowId(winId)],
        widthProportion: 1.0))
    result.instructions = layoutGrid(
      overviewTag,
      screen,
      max(0'i32, model.overviewOuterGap),
      max(0'i32, int32(float32(model.innerGaps) *
        model.overviewInnerGapMultiplier)))
    return

  if model.activeTag == NullTagId:
    return

  let projected = model.projectedTag(model.activeTag)
  if not projected.found:
    return

  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for col in projected.tag.columns:
    tiledWindowCount += col.windows.len

  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0

  let retargetViewport = model.viewportRetargetRequested(model.activeTag)
  var tagForLayout = projected.tag
  result.instructions = layoutForTag(
    tagForLayout,
    windows,
    screen,
    currentOuterGap,
    currentInnerGap,
    retargetViewport and model.scrollerFocusCenter,
    retargetViewport and model.scrollerPreferCenter,
    if retargetViewport: model.centerFocusedColumn else: "never")
  if tagForLayout.columns.len > 0:
    result.viewportTargets.add(LayoutViewportTarget(
      tagSlot: projected.tag.tagId,
      targetX: tagForLayout.targetViewportXOffset,
      targetY: tagForLayout.targetViewportYOffset))

  let focused = model.activeFocus()
  let focusedOpt = model.windowData(focused)
  let overlayActive = model.activeFocusIsOverlay(focused)
  if overlayActive:
    model.preserveBackingPresentation(result.instructions, screen)

  for winId, win in model.windowsOnTagWithId(model.activeTag):
    if win.isFloating and not win.isMinimized:
      result.instructions.add(rv.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: win.floatingGeom))

  let winId = model.activeScratchpadWindow()
  if winId != NullWindowId:
    if model.windowData(winId).isSome:
      let sw = int32(float32(screen.w) * model.effectiveScratchpadWidthRatio())
      let sh = int32(float32(screen.h) * model.effectiveScratchpadHeightRatio())
      result.instructions.add(rv.RenderInstruction(
        windowId: model.externalWindowId(winId),
        geom: rv.Rect(
          x: screen.x + (screen.w - sw) div 2,
          y: screen.y + (screen.h - sh) div 2,
          w: sw,
          h: sh)))

  if focusedOpt.isSome and not overlayActive:
    let win = focusedOpt.get()
    let maxSupported = projected.tag.layoutMode.layoutSupportsMaximize()
    if win.isFullscreen or (win.isMaximized and maxSupported):
      result.instructions = @[rv.RenderInstruction(
        windowId: model.externalWindowId(focused),
        geom: screen)]

proc applyLayoutProjection*(model: var Model; projection: LayoutProjection) =
  for target in projection.viewportTargets:
    let tagId = model.tagForSlot(target.tagSlot)
    if tagId != NullTagId:
      discard model.setTagViewportTarget(tagId, target.targetX, target.targetY)
      discard model.clearTagViewportRetarget(tagId)

proc layoutInstructions*(model: var Model):
    seq[rv.RenderInstruction] =
  let projection = model.layoutProjection()
  model.applyLayoutProjection(projection)
  projection.instructions
