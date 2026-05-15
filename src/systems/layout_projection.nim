import std/[algorithm, math, options, tables]
import ../layouts/[scroller, tiling]
import ../state/engine
import ../types/core as core_types
import ../types/layout_projection
import ../types/model as model_types
import ../types/runtime_values as rv
import
  floating_geometry, overview_geometry, presentation_policy, popup_tree, recent_windows,
  window_rules

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
    if win.windowAdmitted() and win.isFloating and not win.isUnmanagedGlobal and
        not win.isMinimized:
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
      pid: win.pid,
      title: win.title,
      appId: win.appId,
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      isSticky: win.isSticky,
      isOverlay: win.isOverlay,
      isUnmanagedGlobal: win.isUnmanagedGlobal,
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
      idleInhibitMode: win.idleInhibitMode,
      isTerminal: win.isTerminal,
      allowSwallow: win.allowSwallow,
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
          not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId):
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

proc layoutUsesNativeViewport(mode: rv.LayoutMode): bool =
  mode in {rv.LayoutMode.Scroller, rv.LayoutMode.VerticalScroller}

proc applyLayoutViewportOffset(
    tag: rv.TagState, instructions: var seq[rv.RenderInstruction]
) =
  if tag.layoutMode.layoutUsesNativeViewport():
    return
  if tag.currentViewportXOffset == 0.0'f32 and tag.currentViewportYOffset == 0.0'f32:
    return

  let xOffset = int32(tag.currentViewportXOffset)
  let yOffset = int32(tag.currentViewportYOffset)
  for instruction in instructions.mitems:
    instruction.geom.x -= xOffset
    instruction.geom.y -= yOffset

proc upsertInstruction(
    instructions: var seq[rv.RenderInstruction], instruction: rv.RenderInstruction
) =
  for idx, existing in instructions.mpairs:
    if existing.windowId == instruction.windowId:
      instructions[idx] = instruction
      return
  instructions.add(instruction)

proc addUnmanagedGlobalInstructions(
    model: Model, screen: rv.Rect, instructions: var seq[rv.RenderInstruction]
) =
  for winId, win in model.windowsWithId():
    if not win.windowAdmitted() or not win.isUnmanagedGlobal or win.isMinimized:
      continue
    var geom = win.floatingGeom
    if geom.w == 0 or geom.h == 0:
      geom = model.defaultFloatingGeom()
    geom = win.applyFloatingSizeHints(geom).clampToScreen(screen)
    instructions.upsertInstruction(
      rv.RenderInstruction(windowId: model.externalWindowId(winId), geom: geom)
    )

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
  tagForLayout.applyLayoutViewportOffset(result)

  model.addFloatingInstructions(model.activeTag, screen, result)
  model.addUnmanagedGlobalInstructions(screen, result)

proc activeFocusIsOverlay(model: Model, focused: core_types.WindowId): bool =
  if model.activeScratchpadWindow() != NullWindowId:
    return true
  let focusedOpt = model.windowData(focused)
  focusedOpt.isSome and focusedOpt.get().windowAdmitted() and
    (focusedOpt.get().isFloating or focusedOpt.get().isOverlay)

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

proc instructionBounds(instructions: openArray[rv.RenderInstruction]): Option[rv.Rect] =
  if instructions.len == 0:
    return none(rv.Rect)

  var minX = instructions[0].geom.x
  var minY = instructions[0].geom.y
  var maxX = instructions[0].geom.x + instructions[0].geom.w
  var maxY = instructions[0].geom.y + instructions[0].geom.h
  for idx in 1 ..< instructions.len:
    let instr = instructions[idx]
    minX = min(minX, instr.geom.x)
    minY = min(minY, instr.geom.y)
    maxX = max(maxX, instr.geom.x + instr.geom.w)
    maxY = max(maxY, instr.geom.y + instr.geom.h)

  some(
    rv.Rect(x: minX, y: minY, w: max(1'i32, maxX - minX), h: max(1'i32, maxY - minY))
  )

proc scrollerOverviewSource(
    mode: rv.LayoutMode,
    instructions: openArray[rv.RenderInstruction],
    fallback: rv.Rect,
): rv.Rect =
  let bounds = instructions.instructionBounds()
  if bounds.isNone:
    return fallback

  let rect = bounds.get()
  case mode
  of rv.LayoutMode.Scroller:
    rv.Rect(x: rect.x, y: fallback.y, w: rect.w, h: fallback.h)
  of rv.LayoutMode.VerticalScroller:
    rv.Rect(x: fallback.x, y: rect.y, w: fallback.w, h: rect.h)
  else:
    fallback

proc scaledFitOverviewRect(source, dest, geom: rv.Rect, maxZoom: float32): rv.Rect =
  let sourceW = max(1'i32, source.w)
  let sourceH = max(1'i32, source.h)
  let scale = max(
    0.0001'f32,
    min(
      maxZoom,
      min(float32(dest.w) / float32(sourceW), float32(dest.h) / float32(sourceH)),
    ),
  )
  let scaledSourceW = int32(round(float32(sourceW) * scale))
  let scaledSourceH = int32(round(float32(sourceH) * scale))
  let originX = dest.x + (dest.w - scaledSourceW) div 2
  let originY = dest.y + (dest.h - scaledSourceH) div 2
  rv.Rect(
    x: originX + int32(round(float32(geom.x - source.x) * scale)),
    y: originY + int32(round(float32(geom.y - source.y) * scale)),
    w: max(1'i32, int32(round(float32(max(1'i32, geom.w)) * scale))),
    h: max(1'i32, int32(round(float32(max(1'i32, geom.h)) * scale))),
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
      instr.clipSet = false
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
    var targetTag = projected.tag
    var instructions = layoutForTag(
      targetTag,
      windows,
      workspaceScreen,
      model.outerGaps,
      model.innerGaps,
      retargetViewport and model.scrollerFocusCenter,
      retargetViewport and model.scrollerPreferCenter,
      if retargetViewport: model.centerFocusedColumn else: "never",
    )
    targetTag.applyLayoutViewportOffset(instructions)
    if targetTag.columns.len > 0:
      result.viewportTargets.add(
        LayoutViewportTarget(
          tagSlot: targetTag.tagId,
          targetX: targetTag.targetViewportXOffset,
          targetY: targetTag.targetViewportYOffset,
        )
      )

    var overviewSource = workspaceScreen
    let overviewNeedsFullStrip = projected.tag.layoutMode.layoutUsesNativeViewport()
    if overviewNeedsFullStrip:
      var overviewTag = projected.tag
      overviewTag.currentViewportXOffset = 0.0'f32
      overviewTag.currentViewportYOffset = 0.0'f32
      instructions = layoutForTag(
        overviewTag, windows, workspaceScreen, model.outerGaps, model.innerGaps, false,
        false, "never",
      )
      overviewSource =
        scrollerOverviewSource(overviewTag.layoutMode, instructions, workspaceScreen)

    model.addFloatingInstructions(tagId, workspaceScreen, instructions)
    let preview = model.workspacePreviewRect(screen, slots, idx)
    for instr in instructions:
      let geom =
        if overviewNeedsFullStrip:
          scaledFitOverviewRect(overviewSource, preview, instr.geom, zoom)
        else:
          scaledOverviewRect(workspaceScreen, preview, instr.geom, zoom)
      result.instructions.add(
        rv.RenderInstruction(
          windowId: instr.windowId, geom: geom, clipSet: true, clip: preview
        )
      )
  model.applyOverviewDrag(result.instructions)

proc layoutProjection*(model: Model): LayoutProjection =
  let screen = model.primaryScreen()
  let windows = model.runtimeWindowTable()

  if model.overviewActive:
    result = model.layoutWorkspaceStripOverview(windows, screen)
    model.addUnmanagedGlobalInstructions(screen, result.instructions)
    return

  if model.recentWindowsVisible():
    result.instructions = model.recentWindowLayoutInstructions(screen)
    model.addUnmanagedGlobalInstructions(screen, result.instructions)
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
  tagForLayout.applyLayoutViewportOffset(result.instructions)
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
  model.addUnmanagedGlobalInstructions(screen, result.instructions)

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
