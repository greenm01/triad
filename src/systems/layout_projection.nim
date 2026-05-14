import std/[algorithm, math, options, tables]
import ../layouts/[scroller, tiling]
import ../state/engine
import ../types/core as core_types
import ../types/layout_projection
import ../types/model as model_types
import ../types/runtime_values as rv
import
  floating_geometry, overview_geometry, presentation_policy, popup_tree, window_rules

proc externalWindowId(model: Model, winId: core_types.WindowId): rv.WindowId =
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
          x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH
        )
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

proc isDescendantOf(model: Model, child, ancestor: core_types.WindowId): bool =
  if child == NullWindowId or ancestor == NullWindowId or child == ancestor:
    return false
  var current = child
  var depth = 0
  while current != NullWindowId and depth < 64:
    let winOpt = model.windowData(current)
    if winOpt.isNone:
      return false
    let parentExternalId = winOpt.get().parentExternalId
    if parentExternalId == NullExternalWindowId:
      return false
    let parent = model.windowForExternal(parentExternalId)
    if parent == ancestor:
      return true
    current = parent
    inc depth
  false

proc inActivePopupTree(model: Model, winId, activeRoot: core_types.WindowId): bool =
  activeRoot != NullWindowId and model.popupRoot(winId) == activeRoot

proc popupStackRank(model: Model, winId: core_types.WindowId): int =
  result = -1
  var idx = 0
  for candidate in model.focusHistoryIds():
    if candidate == winId:
      result = idx
    inc idx

proc floatingStackCmp(
    model: Model, a, b: tuple[id: core_types.WindowId, win: model_types.WindowData]
): int =
  if model.isDescendantOf(a.id, b.id):
    return 1
  if model.isDescendantOf(b.id, a.id):
    return -1
  let rankA = model.popupStackRank(a.id)
  let rankB = model.popupStackRank(b.id)
  if rankA != rankB:
    return cmp(rankA, rankB)
  cmp(uint32(a.id), uint32(b.id))

proc applyPopupLayoutFocus(
    model: Model, tag: var rv.TagState, active: core_types.WindowId
) =
  let layoutFocus = model.popupTreeLayoutFocus(active)
  if tag.layoutMode in {rv.LayoutMode.Deck, rv.LayoutMode.VerticalDeck}:
    tag.focusedWindow = 0'u32
    return
  if layoutFocus != NullWindowId and layoutFocus != active:
    tag.focusedWindow = model.externalWindowId(layoutFocus)

proc addFloatingInstructions(
    model: Model,
    tagId: core_types.TagId,
    screen: rv.Rect,
    instructions: var seq[rv.RenderInstruction],
) =
  let activeRoot = model.popupRoot(model.activeFocus())
  var floating: seq[tuple[id: core_types.WindowId, win: model_types.WindowData]] = @[]
  for winId, win in model.windowsOnTagWithId(tagId):
    if win.windowAdmitted() and win.isFloating and not win.isMinimized:
      floating.add((id: winId, win: win))
  floating.sort(
    proc(a, b: tuple[id: core_types.WindowId, win: model_types.WindowData]): int =
      model.floatingStackCmp(a, b)
  )

  var geomByWindow = initTable[rv.WindowId, rv.Rect]()
  for instr in instructions:
    geomByWindow[instr.windowId] = instr.geom

  for item in floating:
    var geom = item.win.floatingGeom
    if item.win.parentExternalId != NullExternalWindowId and
        model.parentedRoleFor(item.win) == rv.ParentedRole.Dialog:
      if not model.inActivePopupTree(item.id, activeRoot):
        continue
      let parentId = rv.WindowId(uint32(item.win.parentExternalId))
      if not geomByWindow.hasKey(parentId):
        continue
      let parentGeom = geomByWindow[parentId]
      if not parentGeom.fullyWithin(screen):
        continue
      if item.win.manualFloatingPosition:
        geom =
          item.win.applyFloatingSizeHints(item.win.floatingGeom).clampToScreen(screen)
      else:
        geom = item.win.anchoredFloatingGeom(parentGeom, item.win.floatingGeom, screen)
    let externalId = model.externalWindowId(item.id)
    instructions.add(rv.RenderInstruction(windowId: externalId, geom: geom))
    geomByWindow[externalId] = geom

proc runtimeWindowTable(model: Model): Table[rv.WindowId, rv.WindowData] =
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
      isSticky: win.isSticky,
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
      keyboardShortcutsInhibitBypass: win.keyboardShortcutsInhibitBypass,
    )

proc projectedTag(
    model: Model, tagId: core_types.TagId
): tuple[found: bool, tag: rv.TagState] =
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
    masterSplitRatio: tag.masterSplitRatio,
  )

  for _, column in model.columnsOnTagWithId(tagId):
    var windows: seq[rv.WindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(column.id):
      if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
          not model.windowHiddenByGroup(winId):
        windows.add(model.externalWindowId(winId))
    if windows.len > 0:
      result.tag.columns.add(
        rv.Column(
          windows: windows,
          widthProportion: column.widthProportion,
          scrollerSingleProportion: column.scrollerSingleProportion,
          isFullWidth: column.isFullWidth,
        )
      )

proc layoutForTag(
    tag: var rv.TagState,
    windows: Table[rv.WindowId, rv.WindowData],
    screen: rv.Rect,
    outerGap, innerGap: int32,
    focusCenter, preferCenter: bool,
    centerMode: string,
): seq[rv.RenderInstruction] =
  case tag.layoutMode
  of rv.LayoutMode.Scroller:
    layoutScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter, centerMode
    )
  of rv.LayoutMode.VerticalScroller:
    layoutVerticalScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter, centerMode
    )
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
  of rv.LayoutMode.TGMix:
    layoutTGMix(tag, screen, outerGap, innerGap)

proc activeFocusLayoutInstructions*(model: Model): seq[rv.RenderInstruction] =
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
  model.applyPopupLayoutFocus(tagForLayout, model.activeFocus())
  result = layoutForTag(
    tagForLayout,
    windows,
    screen,
    currentOuterGap,
    currentInnerGap,
    retargetViewport and model.scrollerFocusCenter,
    retargetViewport and model.scrollerPreferCenter,
    if retargetViewport: model.centerFocusedColumn else: "never",
  )

  model.addFloatingInstructions(model.activeTag, screen, result)

proc upsertInstruction(
    instructions: var seq[rv.RenderInstruction], instruction: rv.RenderInstruction
) =
  for idx, existing in instructions.mpairs:
    if existing.windowId == instruction.windowId:
      instructions[idx] = instruction
      return
  instructions.add(instruction)

proc activeFocusIsOverlay(model: Model, focused: core_types.WindowId): bool =
  if model.activeScratchpadWindow() != NullWindowId:
    return true
  let focusedOpt = model.windowData(focused)
  focusedOpt.isSome and focusedOpt.get().windowAdmitted() and focusedOpt.get().isFloating

proc preserveBackingPresentation(
    model: Model,
    instructions: var seq[rv.RenderInstruction],
    screen: rv.Rect,
    scopedRoot = NullWindowId,
) =
  let tagOpt = model.tagData(model.activeTag)
  let maxSupported = tagOpt.isSome and tagOpt.get().layoutMode.layoutSupportsMaximize()
  for winId, win in model.windowsOnTagWithId(model.activeTag):
    if scopedRoot != NullWindowId and winId != scopedRoot:
      continue
    if win.windowAdmitted() and not win.isFloating and not win.isMinimized and (
      win.isFullscreen or (
        win.isMaximized and maxSupported and
        not model.columnFullWidthForWindowOnTag(model.activeTag, winId)
      )
    ):
      instructions.upsertInstruction(
        rv.RenderInstruction(windowId: model.externalWindowId(winId), geom: screen)
      )

proc scaledOverviewRect(source, dest, geom: rv.Rect, zoom: float32): rv.Rect =
  rv.Rect(
    x: dest.x + int32(round(float32(geom.x - source.x) * zoom)),
    y: dest.y + int32(round(float32(geom.y - source.y) * zoom)),
    w: max(1'i32, int32(round(float32(max(1'i32, geom.w)) * zoom))),
    h: max(1'i32, int32(round(float32(max(1'i32, geom.h)) * zoom))),
  )

proc applyOverviewDrag(model: Model, instructions: var seq[rv.RenderInstruction]) =
  let op = model.pointerOp
  if op.kind != rv.PointerOpKind.OpOverviewDrag:
    return
  if abs(op.totalDX) < OverviewDragThreshold and abs(op.totalDY) < OverviewDragThreshold:
    return
  let externalId = model.externalWindowId(op.windowId)
  for instr in instructions.mitems:
    if instr.windowId == externalId:
      instr.geom.x += op.totalDX
      instr.geom.y += op.totalDY
      return

proc columnHasMaximizedWindow(
    col: rv.Column, windows: Table[rv.WindowId, rv.WindowData]
): bool =
  for winId in col.windows:
    if windows.hasKey(winId) and windows[winId].isMaximized:
      return true
  false

proc applyOverviewMaximizedColumnSizing(
    tag: var rv.TagState, windows: Table[rv.WindowId, rv.WindowData]
) =
  if not tag.layoutMode.layoutSupportsMaximize():
    return
  for col in tag.columns.mitems:
    if col.columnHasMaximizedWindow(windows):
      col.isFullWidth = true

proc layoutWorkspaceStripOverview(
    model: Model, windows: Table[rv.WindowId, rv.WindowData], screen: rv.Rect
): LayoutProjection =
  let slots = model.previewSlots()
  if slots.len == 0:
    return

  let zoom = model.effectiveOverviewZoom()
  let workspaceScreen = rv.Rect(x: screen.x, y: screen.y, w: screen.w, h: screen.h)
  for idx, slot in slots:
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    var projected = model.projectedTag(tagId)
    if not projected.found:
      continue
    model.applyPopupLayoutFocus(projected.tag, model.activeFocus())
    projected.tag.applyOverviewMaximizedColumnSizing(windows)
    let retargetViewport = model.viewportRetargetRequested(tagId)
    var instructions = layoutForTag(
      projected.tag,
      windows,
      workspaceScreen,
      model.outerGaps,
      model.innerGaps,
      retargetViewport and model.scrollerFocusCenter,
      retargetViewport and model.scrollerPreferCenter,
      if retargetViewport: model.centerFocusedColumn else: "never",
    )
    if projected.tag.columns.len > 0:
      result.viewportTargets.add(
        LayoutViewportTarget(
          tagSlot: projected.tag.tagId,
          targetX: projected.tag.targetViewportXOffset,
          targetY: projected.tag.targetViewportYOffset,
        )
      )
    model.addFloatingInstructions(tagId, workspaceScreen, instructions)
    let preview = model.workspacePreviewRect(screen, slots, idx)
    for instr in instructions:
      result.instructions.add(
        rv.RenderInstruction(
          windowId: instr.windowId,
          geom: scaledOverviewRect(workspaceScreen, preview, instr.geom, zoom),
        )
      )
  model.applyOverviewDrag(result.instructions)

proc layoutProjection*(model: Model): LayoutProjection =
  let screen = model.primaryScreen()
  let windows = model.runtimeWindowTable()

  if model.overviewActive:
    result = model.layoutWorkspaceStripOverview(windows, screen)
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
  model.applyPopupLayoutFocus(tagForLayout, model.activeFocus())
  result.instructions = layoutForTag(
    tagForLayout,
    windows,
    screen,
    currentOuterGap,
    currentInnerGap,
    retargetViewport and model.scrollerFocusCenter,
    retargetViewport and model.scrollerPreferCenter,
    if retargetViewport: model.centerFocusedColumn else: "never",
  )
  if tagForLayout.columns.len > 0:
    result.viewportTargets.add(
      LayoutViewportTarget(
        tagSlot: projected.tag.tagId,
        targetX: tagForLayout.targetViewportXOffset,
        targetY: tagForLayout.targetViewportYOffset,
      )
    )

  let focused = model.activeFocus()
  let focusedOpt = model.windowData(focused)
  let overlayActive = model.activeFocusIsOverlay(focused)
  if overlayActive:
    let root = model.popupRoot(focused)
    model.preserveBackingPresentation(
      result.instructions, screen, if root != focused: root else: NullWindowId
    )
  elif focusedOpt.isSome:
    let win = focusedOpt.get()
    let maxSupported = projected.tag.layoutMode.layoutSupportsMaximize()
    let effectivelyMaximized =
      win.isMaximized and maxSupported and
      not model.columnFullWidthForWindowOnTag(model.activeTag, focused)
    if win.isFullscreen or effectivelyMaximized:
      result.instructions =
        @[rv.RenderInstruction(windowId: model.externalWindowId(focused), geom: screen)]

  model.addFloatingInstructions(model.activeTag, screen, result.instructions)

  let winId = model.activeScratchpadWindow()
  if winId != NullWindowId:
    if model.windowData(winId).isSome:
      let sw = int32(float32(screen.w) * model.effectiveScratchpadWidthRatio())
      let sh = int32(float32(screen.h) * model.effectiveScratchpadHeightRatio())
      result.instructions.add(
        rv.RenderInstruction(
          windowId: model.externalWindowId(winId),
          geom: rv.Rect(
            x: screen.x + (screen.w - sw) div 2,
            y: screen.y + (screen.h - sh) div 2,
            w: sw,
            h: sh,
          ),
        )
      )

proc applyLayoutProjection*(model: var Model, projection: LayoutProjection) =
  for target in projection.viewportTargets:
    let tagId = model.tagForSlot(target.tagSlot)
    if tagId != NullTagId:
      discard model.setTagViewportTarget(tagId, target.targetX, target.targetY)
      if model.viewportSnapRequested(tagId) or not model.enableAnimations:
        discard model.setTagViewportCurrent(tagId, target.targetX, target.targetY)
      discard model.clearTagViewportRetarget(tagId)
      discard model.clearTagViewportSnap(tagId)

proc layoutInstructions*(model: var Model): seq[rv.RenderInstruction] =
  let projection = model.layoutProjection()
  model.applyLayoutProjection(projection)
  projection.instructions
