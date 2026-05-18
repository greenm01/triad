import std/[algorithm, math, options, tables]
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../janet/runtime as janet_runtime
import ../layouts/scroller
import ../state/engine
import ../types/core as core_types
import ../types/janet_layouts
import ../types/layout_projection
import ../types/model as model_types
import ../types/projection_values as rv
from ../types/runtime_values import
  Direction, FrameNodeKind, FrameSplitOrientation, JanetLayoutId
import
  floating_geometry, overview_geometry, presentation_policy, popup_tree, recent_windows,
  window_rules

type
  CustomLayoutEval* = proc(context: JanetLayoutContext): JanetLayoutEvalResult

  OverviewTransform = object
    source: rv.Rect
    dest: rv.Rect
    clip: rv.Rect

  OverviewTagLayout = object
    tag: rv.ProjectedTag
    mode: rv.LayoutMode
    instructions: seq[rv.RenderInstruction]
    frameEmptyChrome: seq[rv.ProjectedFrameEmptyChrome]
    viewportTarget: bool
    aggregate: bool
    representativeOnly: bool

const FrameTreeTabBarHeight* = 24'i32

proc externalWindowId(model: Model, winId: core_types.WindowId): rv.ProjectionWindowId =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return rv.ProjectionWindowId(uint32(winOpt.get().externalId))
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
    model: Model, tag: var rv.ProjectedTag, active: core_types.WindowId
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

  var geomByWindow = initTable[rv.ProjectionWindowId, rv.Rect]()
  for instr in instructions:
    geomByWindow[instr.windowId] = instr.geom

  for item in floating:
    var geom = item.win.floatingGeom
    if item.win.parentExternalId != NullExternalWindowId and
        model.parentedRoleFor(item.win) == rv.ParentedRole.Dialog:
      if not model.inActivePopupTree(item.id, activeRoot):
        continue
      let parentId = rv.ProjectionWindowId(uint32(item.win.parentExternalId))
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

proc runtimeWindowTable(
    model: Model
): Table[rv.ProjectionWindowId, rv.ProjectedWindow] =
  for winId, win in model.windowsWithId():
    result[model.externalWindowId(winId)] = rv.ProjectedWindow(
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
      parentId: rv.ProjectionWindowId(uint32(win.parentExternalId)),
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
): tuple[found: bool, tag: rv.ProjectedTag] =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return (false, rv.ProjectedTag())

  let tag = tagOpt.get()
  result.found = true
  result.tag = rv.ProjectedTag(
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
    var windows: seq[rv.ProjectionWindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(column.id):
      if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
          not win.isUnmanagedGlobal and not model.windowHiddenByGroup(winId):
        windows.add(model.externalWindowId(winId))
    if windows.len > 0:
      result.tag.columns.add(
        rv.ProjectedColumn(
          windows: windows,
          widthProportion: column.widthProportion,
          scrollerSingleProportion: column.scrollerSingleProportion,
          isFullWidth: column.isFullWidth,
        )
      )

  for frameId, frame in model.framesOnTagWithId(tagId):
    var frameWindows: seq[rv.ProjectionWindowId] = @[]
    for winId in model.windowsByFrame.getOrDefault(frameId, @[]):
      let winOpt = model.windowData(winId)
      if winOpt.isSome and winOpt.get().windowAdmitted() and not winOpt.get().isFloating and
          not winOpt.get().isMinimized and not winOpt.get().isUnmanagedGlobal and
          not model.windowHiddenByGroup(winId):
        frameWindows.add(model.externalWindowId(winId))
    result.tag.frames.add(
      rv.ProjectedFrame(
        id: uint32(frame.id),
        kind: frame.kind,
        parent: uint32(frame.parent),
        firstChild: uint32(frame.firstChild),
        secondChild: uint32(frame.secondChild),
        orientation: frame.orientation,
        ratio: frame.ratio,
        windows: frameWindows,
        activeWindow: model.externalWindowId(frame.activeWindow),
        focused: frameId == tag.focusedFrame,
      )
    )

  for nodeId, node in model.bspNodesOnTagWithId(tagId):
    result.tag.bspNodes.add(
      rv.ProjectedBspNode(
        id: uint32(nodeId),
        kind: node.kind,
        parent: uint32(node.parent),
        firstChild: uint32(node.firstChild),
        secondChild: uint32(node.secondChild),
        orientation: node.orientation,
        ratio: node.ratio,
        window: model.externalWindowId(node.window),
        focused: node.window != NullWindowId and node.window == tag.focusedWindow,
        hasPreselection: node.hasPreselection,
        preselectDirection: node.preselectDirection,
        preselectRatio: node.preselectRatio,
      )
    )

proc layoutForTag(
    tag: var rv.ProjectedTag,
    windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow],
    screen: rv.Rect,
    outerGap, innerGap: int32,
    focusCenter, preferCenter: bool,
    centerMode: string,
): seq[rv.RenderInstruction] =
  case tag.layoutMode
  of rv.LayoutMode.Scroller:
    result = layoutScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter, centerMode
    )
  of rv.LayoutMode.VerticalScroller:
    result = layoutVerticalScroller(
      tag, windows, screen, outerGap, innerGap, focusCenter, preferCenter, centerMode
    )
  else:
    let safeOuterGap = max(0'i32, outerGap)
    let safeInnerGap = max(0'i32, innerGap)
    let usable = rv.Rect(
      x: screen.x + safeOuterGap,
      y: screen.y + safeOuterGap,
      w: max(1'i32, screen.w - safeOuterGap * 2),
      h: max(1'i32, screen.h - safeOuterGap * 2),
    )
    var allWindows: seq[rv.ProjectionWindowId] = @[]
    for col in tag.columns:
      for winId in col.windows:
        allWindows.add(winId)
    if allWindows.len == 0:
      return
    let count = int32(allWindows.len)
    let maxTotalGap = max(0'i32, usable.w - count)
    let totalGap = min(safeInnerGap * max(0'i32, count - 1), maxTotalGap)
    let gap =
      if count > 1:
        totalGap div (count - 1)
      else:
        0'i32
    let baseWidth = max(1'i32, (usable.w - gap * max(0'i32, count - 1)) div count)
    var x = usable.x
    for idx, winId in allWindows:
      let remaining = max(1'i32, usable.x + usable.w - x)
      let width =
        if idx == allWindows.high:
          remaining
        else:
          min(baseWidth, remaining)
      result.add(
        rv.RenderInstruction(
          windowId: winId, geom: rv.Rect(x: x, y: usable.y, w: width, h: usable.h)
        )
      )
      x += width + gap

proc layoutUsesNativeViewport(mode: rv.LayoutMode): bool =
  mode in {rv.LayoutMode.Scroller, rv.LayoutMode.VerticalScroller}

proc tagDataUsesCoreScroller(tag: TagData): bool =
  tag.customLayoutId.layoutIdString().len == 0 and
    tag.nativeLayoutId.nativeLayoutIdString().len == 0 and
    tag.layoutMode.layoutUsesNativeViewport()

proc frameTreeActive(tag: TagData): bool =
  tag.nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId

proc bspTreeActive(tag: TagData): bool =
  tag.nativeLayoutId.nativeLayoutIdString() == BspTreeLayoutId

proc frameTreeTabHeight(rect: rv.Rect): int32 =
  min(FrameTreeTabBarHeight, max(0'i32, rect.h - 1'i32))

proc frameTreeClientRect(rect: rv.Rect, borderWidth: int32): rv.Rect =
  let tabHeight = frameTreeTabHeight(rect)
  let border = max(0'i32, borderWidth)
  rv.Rect(
    x: rect.x + border,
    y: rect.y + border + tabHeight,
    w: max(1'i32, rect.w - border * 2),
    h: max(1'i32, rect.h - border * 2 - tabHeight),
  )

proc frameTreeRects(
    model: Model,
    frameId: FrameId,
    area: rv.Rect,
    gap: int32,
    outRects: var seq[tuple[frameId: FrameId, rect: rv.Rect]],
) =
  let frameOpt = model.frameData(frameId)
  if frameOpt.isNone:
    return
  let frame = frameOpt.get()
  case frame.kind
  of FrameNodeKind.Leaf:
    outRects.add((frameId, area))
  of FrameNodeKind.Split:
    let safeGap = max(0'i32, gap)
    let ratio = clamp(frame.ratio, 0.05'f32, 0.95'f32)
    case frame.orientation
    of FrameSplitOrientation.Horizontal:
      let firstW = max(1'i32, int32(float32(max(1'i32, area.w - safeGap)) * ratio))
      let secondW = max(1'i32, area.w - safeGap - firstW)
      model.frameTreeRects(
        frame.firstChild,
        rv.Rect(x: area.x, y: area.y, w: firstW, h: area.h),
        safeGap,
        outRects,
      )
      model.frameTreeRects(
        frame.secondChild,
        rv.Rect(x: area.x + firstW + safeGap, y: area.y, w: secondW, h: area.h),
        safeGap,
        outRects,
      )
    of FrameSplitOrientation.Vertical:
      let firstH = max(1'i32, int32(float32(max(1'i32, area.h - safeGap)) * ratio))
      let secondH = max(1'i32, area.h - safeGap - firstH)
      model.frameTreeRects(
        frame.firstChild,
        rv.Rect(x: area.x, y: area.y, w: area.w, h: firstH),
        safeGap,
        outRects,
      )
      model.frameTreeRects(
        frame.secondChild,
        rv.Rect(x: area.x, y: area.y + firstH + safeGap, w: area.w, h: secondH),
        safeGap,
        outRects,
      )

proc frameTreeLayoutRects*(
    model: Model, tagId: TagId, screen: rv.Rect, outerGap, innerGap: int32
): seq[tuple[frameId: FrameId, rect: rv.Rect]] =
  let root = model.frameRootForTag(tagId)
  if root == NullFrameId:
    return @[]
  let usable = rv.Rect(x: screen.x, y: screen.y, w: screen.w, h: screen.h)
  model.frameTreeRects(root, usable, innerGap, result)

proc applyFrameTreeRects(
    model: Model,
    tagId: TagId,
    tag: var rv.ProjectedTag,
    screen: rv.Rect,
    outerGap, innerGap: int32,
) =
  let root = model.frameRootForTag(tagId)
  if root == NullFrameId:
    return
  let usable = rv.Rect(x: screen.x, y: screen.y, w: screen.w, h: screen.h)
  var rects: seq[tuple[frameId: FrameId, rect: rv.Rect]] = @[]
  model.frameTreeRects(root, usable, innerGap, rects)
  for item in rects:
    for frame in tag.frames.mitems:
      if frame.id == uint32(item.frameId):
        frame.rectSet = true
        frame.rect = item.rect
        break

proc frameTreeVisibleWindowIds(model: Model, frameId: FrameId): seq[WindowId] =
  let frameOpt = model.frameData(frameId)
  if frameOpt.isNone:
    return
  for winId in model.windowsByFrame.getOrDefault(frameId, @[]):
    let winOpt = model.windowData(winId)
    if winOpt.isNone or not winOpt.get().windowAdmitted() or winOpt.get().isFloating or
        winOpt.get().isMinimized or winOpt.get().isUnmanagedGlobal or
        model.windowHiddenByGroup(winId):
      continue
    result.add(winId)

proc frameTreeVisibleActiveWindow(model: Model, frameId: FrameId): WindowId =
  let visible = model.frameTreeVisibleWindowIds(frameId)
  if visible.len == 0:
    return NullWindowId
  let frameOpt = model.frameData(frameId)
  if frameOpt.isSome and visible.find(frameOpt.get().activeWindow) != -1:
    return frameOpt.get().activeWindow
  visible[^1]

proc layoutFrameTree*(
    model: Model, tagId: TagId, screen: rv.Rect, outerGap, innerGap: int32
): seq[rv.RenderInstruction] =
  let rects = model.frameTreeLayoutRects(tagId, screen, outerGap, innerGap)
  let tagOpt = model.tagData(tagId)
  for item in rects:
    let frameOpt = model.frameData(item.frameId)
    if frameOpt.isNone:
      continue
    let active = model.frameTreeVisibleActiveWindow(item.frameId)
    if active == NullWindowId:
      continue
    let focused = tagOpt.isSome and item.frameId == tagOpt.get().focusedFrame
    let border = model.effectiveWindowBorder(active, focused)
    result.add(
      rv.RenderInstruction(
        windowId: model.externalWindowId(active),
        geom: frameTreeClientRect(item.rect, border.width),
      )
    )

proc frameTreeVisibleTabs(model: Model, frameId: FrameId): seq[rv.ProjectedFrameTab] =
  let frameOpt = model.frameData(frameId)
  if frameOpt.isNone:
    return
  let active = model.frameTreeVisibleActiveWindow(frameId)
  for winId in model.frameTreeVisibleWindowIds(frameId):
    let winOpt = model.windowData(winId)
    if winOpt.isNone:
      continue
    let win = winOpt.get()
    result.add(
      rv.ProjectedFrameTab(
        windowId: model.externalWindowId(winId),
        title: win.title,
        appId: win.appId,
        active: winId == active,
      )
    )

proc frameTreeTabBars*(
    model: Model, tagId: TagId, rects: openArray[tuple[frameId: FrameId, rect: rv.Rect]]
): seq[rv.ProjectedFrameTabBar] =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return @[]
  for item in rects:
    let frameOpt = model.frameData(item.frameId)
    if frameOpt.isNone:
      continue
    let frame = frameOpt.get()
    let active = model.frameTreeVisibleActiveWindow(item.frameId)
    if active == NullWindowId:
      continue
    let tabHeight = frameTreeTabHeight(item.rect)
    if tabHeight <= 0:
      continue
    let tabs = model.frameTreeVisibleTabs(item.frameId)
    if tabs.len == 0:
      continue
    let border =
      model.effectiveWindowBorder(active, item.frameId == tagOpt.get().focusedFrame)
    result.add(
      rv.ProjectedFrameTabBar(
        frameId: uint32(item.frameId),
        windowId: model.externalWindowId(active),
        geom: rv.Rect(x: item.rect.x, y: item.rect.y, w: item.rect.w, h: tabHeight),
        focused: item.frameId == tagOpt.get().focusedFrame,
        frameTabs: model.frameTabs,
        ringWidth: border.width,
        ringColor:
          if item.frameId == tagOpt.get().focusedFrame:
            border.activeColor
          else:
            border.inactiveColor,
        tabs: tabs,
      )
    )

proc frameTreeTabBars*(
    model: Model, tagId: TagId, screen: rv.Rect, outerGap, innerGap: int32
): seq[rv.ProjectedFrameTabBar] =
  let rects = model.frameTreeLayoutRects(tagId, screen, outerGap, innerGap)
  model.frameTreeTabBars(tagId, rects)

proc frameTreeEmptyChrome*(
    model: Model, tagId: TagId, rects: openArray[tuple[frameId: FrameId, rect: rv.Rect]]
): seq[rv.ProjectedFrameEmptyChrome] =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return @[]
  for item in rects:
    let frameOpt = model.frameData(item.frameId)
    if frameOpt.isNone or frameOpt.get().kind != FrameNodeKind.Leaf:
      continue
    if model.frameTreeVisibleTabs(item.frameId).len > 0:
      continue
    let focused = item.frameId == tagOpt.get().focusedFrame
    let border = model.effectiveWindowBorder(NullWindowId, focused)
    result.add(
      rv.ProjectedFrameEmptyChrome(
        frameId: uint32(item.frameId),
        geom: item.rect,
        focused: focused,
        ringWidth: border.width,
        ringColor: if focused: border.activeColor else: border.inactiveColor,
        backgroundColor: model.frameTabs.emptyBackgroundColor,
      )
    )

proc frameTreeEmptyChrome*(
    model: Model, tagId: TagId, screen: rv.Rect, outerGap, innerGap: int32
): seq[rv.ProjectedFrameEmptyChrome] =
  let rects = model.frameTreeLayoutRects(tagId, screen, outerGap, innerGap)
  model.frameTreeEmptyChrome(tagId, rects)

proc applyBspTreeRects(
    model: Model,
    tagId: TagId,
    tag: var rv.ProjectedTag,
    screen: rv.Rect,
    outerGap, innerGap: int32,
) =
  let rects = model.bspTreeLeafRects(tagId, screen, outerGap, innerGap)
  for item in rects:
    for node in tag.bspNodes.mitems:
      if node.id == uint32(item.nodeId):
        node.rectSet = true
        node.rect = item.rect
        break

proc bspPreselectionRect(node: rv.ProjectedBspNode, gap: int32): rv.Rect =
  let safeGap = max(0'i32, gap)
  let ratio = clamp(node.preselectRatio, 0.05'f32, 0.95'f32)
  let rect = node.rect
  case node.preselectDirection
  of Direction.DirLeft:
    let w = max(1'i32, int32(float32(max(1'i32, rect.w - safeGap)) * ratio))
    rv.Rect(x: rect.x, y: rect.y, w: w, h: rect.h)
  of Direction.DirRight:
    let firstW = max(1'i32, int32(float32(max(1'i32, rect.w - safeGap)) * ratio))
    let w = max(1'i32, rect.w - safeGap - firstW)
    rv.Rect(x: rect.x + firstW + safeGap, y: rect.y, w: w, h: rect.h)
  of Direction.DirUp:
    let h = max(1'i32, int32(float32(max(1'i32, rect.h - safeGap)) * ratio))
    rv.Rect(x: rect.x, y: rect.y, w: rect.w, h: h)
  of Direction.DirDown:
    let firstH = max(1'i32, int32(float32(max(1'i32, rect.h - safeGap)) * ratio))
    let h = max(1'i32, rect.h - safeGap - firstH)
    rv.Rect(x: rect.x, y: rect.y + firstH + safeGap, w: rect.w, h: h)

proc bspPreselectionOverlays(
    model: Model, tag: rv.ProjectedTag, innerGap: int32
): seq[rv.ProjectedBspPreselection] =
  let ringWidth = max(1'i32, min(max(0'i32, model.borderWidth), 8'i32))
  for node in tag.bspNodes:
    if node.kind == FrameNodeKind.Leaf and node.hasPreselection and node.rectSet and
        node.rect.w > 0 and node.rect.h > 0:
      result.add(
        rv.ProjectedBspPreselection(
          nodeId: node.id,
          geom: node.bspPreselectionRect(innerGap),
          direction: node.preselectDirection,
          ringWidth: ringWidth,
          ringColor: model.focusedBorderColor,
          backgroundColor: 0x62a8ff33'u32,
        )
      )

proc layoutBspTree*(
    model: Model, tagId: TagId, screen: rv.Rect, outerGap, innerGap: int32
): seq[rv.RenderInstruction] =
  let rects = model.bspTreeLeafRects(tagId, screen, outerGap, innerGap)
  for item in rects:
    let winId = item.window
    if winId == NullWindowId:
      continue
    let winOpt = model.windowData(winId)
    if winOpt.isSome and winOpt.get().windowAdmitted() and not winOpt.get().isFloating and
        not winOpt.get().isMinimized and not winOpt.get().isUnmanagedGlobal:
      result.add(
        rv.RenderInstruction(windowId: model.externalWindowId(winId), geom: item.rect)
      )

proc frameTreeFrameRectsFromInstructions(
    tag: rv.ProjectedTag, instructions: openArray[rv.RenderInstruction]
): seq[tuple[frameId: FrameId, rect: rv.Rect]] =
  for instr in instructions:
    for frame in tag.frames:
      if frame.kind == FrameNodeKind.Leaf and frame.activeWindow == instr.windowId:
        result.add((FrameId(frame.id), instr.geom))
        break

proc frameTreeFrameRectsFromInstructions(
    instructions: openArray[JanetLayoutInstruction]
): seq[tuple[frameId: FrameId, rect: rv.Rect]] =
  for instr in instructions:
    if instr.targetKind == JanetLayoutTargetKind.Frame:
      result.add((FrameId(instr.targetId), instr.geom))

proc applyLayoutViewportOffset(
    tag: rv.ProjectedTag, instructions: var seq[rv.RenderInstruction]
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

proc customLayoutInstructions(
  layoutEval: CustomLayoutEval,
  tag: rv.ProjectedTag,
  windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow],
  screen: rv.Rect,
  customLayoutId: JanetLayoutId,
  outerGap, innerGap: int32,
): tuple[
  applied: bool,
  outputTargetKind: JanetLayoutTargetKind,
  instructions: seq[rv.RenderInstruction],
  frameInstructions: seq[JanetLayoutInstruction],
]

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
  let activeTagData = model.tagData(model.activeTag).get()
  var localRuntime: janet_runtime.JanetRuntime
  var localRuntimeOpen = false
  defer:
    if localRuntimeOpen:
      localRuntime.close()

  if activeTagData.frameTreeActive():
    result =
      model.layoutFrameTree(model.activeTag, screen, currentOuterGap, currentInnerGap)
  elif activeTagData.bspTreeActive():
    result =
      model.layoutBspTree(model.activeTag, screen, currentOuterGap, currentInnerGap)
  else:
    var custom:
      tuple[
        applied: bool,
        outputTargetKind: JanetLayoutTargetKind,
        instructions: seq[rv.RenderInstruction],
        frameInstructions: seq[JanetLayoutInstruction],
      ]
    if activeTagData.customLayoutId.layoutIdString().len > 0:
      localRuntime = janet_runtime.initJanetRuntime(model.janet)
      localRuntimeOpen = true
      let snapshot = model.shellSnapshot()
      proc evalLocalLayout(context: JanetLayoutContext): JanetLayoutEvalResult =
        localRuntime.evalLayoutDetailed(snapshot, context)

      custom = customLayoutInstructions(
        evalLocalLayout, tagForLayout, windows, screen, activeTagData.customLayoutId,
        currentOuterGap, currentInnerGap,
      )
    if custom.applied:
      result = custom.instructions
    else:
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

proc customLayoutInstructions(
    layoutEval: CustomLayoutEval,
    tag: rv.ProjectedTag,
    windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow],
    screen: rv.Rect,
    customLayoutId: JanetLayoutId,
    outerGap, innerGap: int32,
): tuple[
  applied: bool,
  outputTargetKind: JanetLayoutTargetKind,
  instructions: seq[rv.RenderInstruction],
  frameInstructions: seq[JanetLayoutInstruction],
] =
  if layoutEval == nil or customLayoutId.layoutIdString().len == 0:
    return
  let evalResult = layoutEval(
    JanetLayoutContext(
      layoutId: customLayoutId,
      screen: screen,
      outerGap: outerGap,
      innerGap: innerGap,
      tag: tag,
      windows: windows,
    )
  )
  if evalResult.outcome != JanetLayoutOutcome.Applied:
    return
  (
    true, evalResult.outputTargetKind, evalResult.instructions,
    evalResult.frameInstructions,
  )

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
  let maxSupported = tagOpt.isSome and tagOpt.get().tagDataUsesCoreScroller()
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

proc scaledOverviewRect(source, dest, geom: rv.Rect, maxZoom: float32): rv.Rect =
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

proc focusedInstructionCenterX(
    tag: rv.ProjectedTag,
    instructions: openArray[rv.RenderInstruction],
    fallback: rv.Rect,
): int32 =
  for instr in instructions:
    if instr.windowId == tag.focusedWindow:
      return instr.geom.x + instr.geom.w div 2
  fallback.x + fallback.w div 2

proc focusedInstructionCenterY(
    tag: rv.ProjectedTag,
    instructions: openArray[rv.RenderInstruction],
    fallback: rv.Rect,
): int32 =
  for instr in instructions:
    if instr.windowId == tag.focusedWindow:
      return instr.geom.y + instr.geom.h div 2
  fallback.y + fallback.h div 2

proc horizontalScrollerOverviewSource(
    tag: rv.ProjectedTag,
    instructions: openArray[rv.RenderInstruction],
    fallback, lane: rv.Rect,
    zoom: float32,
): rv.Rect =
  let sourceW = max(fallback.w, int32(ceil(float32(max(1'i32, lane.w)) / zoom)))
  let focusedCenter = tag.focusedInstructionCenterX(instructions, fallback)
  let sourceX = focusedCenter - sourceW div 2
  rv.Rect(x: sourceX, y: fallback.y, w: sourceW, h: fallback.h)

proc verticalScrollerOverviewSource(
    tag: rv.ProjectedTag,
    instructions: openArray[rv.RenderInstruction],
    fallback, preview: rv.Rect,
    zoom: float32,
): rv.Rect =
  let sourceH = max(fallback.h, int32(ceil(float32(max(1'i32, preview.h)) / zoom)))
  let focusedCenter = tag.focusedInstructionCenterY(instructions, fallback)
  let sourceY = focusedCenter - sourceH div 2
  rv.Rect(x: fallback.x, y: sourceY, w: fallback.w, h: sourceH)

proc overviewTransform(
    mode: rv.LayoutMode,
    tag: rv.ProjectedTag,
    instructions: openArray[rv.RenderInstruction],
    workspaceScreen, screen, preview: rv.Rect,
    zoom: float32,
): OverviewTransform =
  result = OverviewTransform(source: workspaceScreen, dest: preview, clip: preview)
  case mode
  of rv.LayoutMode.Scroller:
    let lane = rv.Rect(x: screen.x, y: preview.y, w: screen.w, h: preview.h)
    result = OverviewTransform(
      source:
        tag.horizontalScrollerOverviewSource(instructions, workspaceScreen, lane, zoom),
      dest: lane,
      clip: lane,
    )
  of rv.LayoutMode.VerticalScroller:
    result.source =
      tag.verticalScrollerOverviewSource(instructions, workspaceScreen, preview, zoom)
  else:
    discard

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
    col: rv.ProjectedColumn, windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow]
): bool =
  for winId in col.windows:
    if windows.hasKey(winId) and windows[winId].isMaximized:
      return true
  false

proc applyOverviewMaximizedColumnSizing(
    tag: var rv.ProjectedTag, windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow]
) =
  if not tag.layoutMode.layoutSupportsMaximize():
    return
  for col in tag.columns.mitems:
    if col.columnHasMaximizedWindow(windows):
      col.isFullWidth = true

proc applyFrameInstructionClientRects(
    model: Model, tagId: TagId, instructions: var seq[rv.RenderInstruction]
) =
  for instr in instructions.mitems:
    let logicalId = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    let frameId = model.frameForWindowOnTag(tagId, logicalId)
    let focused =
      frameId != NullFrameId and model.tagData(tagId).isSome and
      frameId == model.tagData(tagId).get().focusedFrame
    let border = model.effectiveWindowBorder(logicalId, focused)
    instr.geom = frameTreeClientRect(instr.geom, border.width)

proc overviewTagLayout(
    model: Model,
    tagId: TagId,
    tag: rv.ProjectedTag,
    windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow],
    screen: rv.Rect,
    layoutEval: CustomLayoutEval,
): OverviewTagLayout =
  let tagDataOpt = model.tagData(tagId)
  if tagDataOpt.isNone:
    return

  let tagData = tagDataOpt.get()
  let retargetViewport = model.viewportRetargetRequested(tagId)
  result.tag = tag
  model.applyPopupLayoutFocus(result.tag, model.activeFocus())

  if tagData.tagUsesFrameOverview():
    result.mode = rv.LayoutMode.Grid
    result.aggregate = true
    let rects =
      model.frameTreeLayoutRects(tagId, screen, model.outerGaps, model.innerGaps)
    result.instructions =
      model.layoutFrameTree(tagId, screen, model.outerGaps, model.innerGaps)
    result.frameEmptyChrome = model.frameTreeEmptyChrome(tagId, rects)
    return

  if tagData.tagUsesBspOverview():
    result.mode = rv.LayoutMode.Grid
    result.aggregate = true
    result.instructions =
      model.layoutBspTree(tagId, screen, model.outerGaps, model.innerGaps)
    return

  if tagData.tagUsesAggregateOverview():
    result.mode = rv.LayoutMode.Grid
    result.aggregate = true
    result.representativeOnly = true
    let representative = model.overviewRepresentativeWindow(tagId)
    if representative != NullWindowId:
      result.instructions.add(
        rv.RenderInstruction(
          windowId: model.externalWindowId(representative), geom: screen
        )
      )
    return

  if tagData.tagDataUsesCoreScroller():
    result.tag.applyOverviewMaximizedColumnSizing(windows)
  let custom = customLayoutInstructions(
    layoutEval, result.tag, windows, screen, tagData.customLayoutId, model.outerGaps,
    model.innerGaps,
  )
  if custom.applied:
    result.mode = rv.LayoutMode.Grid
    result.instructions = custom.instructions
    return

  result.mode = result.tag.layoutMode
  result.instructions = layoutForTag(
    result.tag,
    windows,
    screen,
    model.outerGaps,
    model.innerGaps,
    retargetViewport and model.scrollerFocusCenter,
    retargetViewport and model.scrollerPreferCenter,
    if retargetViewport: model.centerFocusedColumn else: "never",
  )
  result.tag.applyLayoutViewportOffset(result.instructions)
  result.viewportTarget =
    result.tag.columns.len > 0 and result.mode.layoutUsesNativeViewport()

proc layoutWorkspaceStripOverview(
    model: Model,
    windows: Table[rv.ProjectionWindowId, rv.ProjectedWindow],
    screen: rv.Rect,
    layoutEval: CustomLayoutEval,
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
    let layout = model.overviewTagLayout(
      tagId, projected.tag, windows, workspaceScreen, layoutEval
    )
    var instructions = layout.instructions
    if layout.viewportTarget:
      result.viewportTargets.add(
        LayoutViewportTarget(
          tagSlot: layout.tag.tagId,
          targetX: layout.tag.targetViewportXOffset,
          targetY: layout.tag.targetViewportYOffset,
        )
      )

    let overviewNeedsFullStrip = layout.mode.layoutUsesNativeViewport()
    if overviewNeedsFullStrip:
      var overviewTag = layout.tag
      overviewTag.currentViewportXOffset = 0.0'f32
      overviewTag.currentViewportYOffset = 0.0'f32
      instructions = layoutForTag(
        overviewTag, windows, workspaceScreen, model.outerGaps, model.innerGaps, false,
        false, "never",
      )

    let preview = model.workspacePreviewRect(screen, slots, idx)
    let transform = overviewTransform(
      layout.mode, layout.tag, instructions, workspaceScreen, screen, preview, zoom
    )
    if not layout.representativeOnly:
      model.addFloatingInstructions(tagId, workspaceScreen, instructions)
    for instr in instructions:
      result.instructions.add(
        rv.RenderInstruction(
          windowId: instr.windowId,
          geom: scaledOverviewRect(transform.source, transform.dest, instr.geom, zoom),
          clipSet: true,
          clip: transform.clip,
        )
      )
    for frame in layout.frameEmptyChrome:
      result.frameEmptyChrome.add(
        rv.ProjectedFrameEmptyChrome(
          frameId: frame.frameId,
          geom: scaledOverviewRect(transform.source, transform.dest, frame.geom, zoom),
          focused: frame.focused,
          ringWidth: frame.ringWidth,
          ringColor: frame.ringColor,
          backgroundColor: frame.backgroundColor,
        )
      )
  model.applyOverviewDrag(result.instructions)

proc needsLocalLayoutEval(model: Model): bool =
  if model.overviewActive:
    for slot in model.previewSlots():
      let tagId = model.tagForSlot(slot)
      if tagId == NullTagId:
        continue
      let tagOpt = model.tagData(tagId)
      if tagOpt.isSome and tagOpt.get().customLayoutId.layoutIdString().len > 0:
        return true
    return false

  if model.activeTag == NullTagId:
    return false
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().customLayoutId.layoutIdString().len > 0

proc layoutProjection*(
    model: Model, layoutEval: CustomLayoutEval = nil
): LayoutProjection =
  var localRuntime: janet_runtime.JanetRuntime
  var localRuntimeOpen = false
  var effectiveLayoutEval = layoutEval
  if effectiveLayoutEval == nil and model.needsLocalLayoutEval():
    localRuntime = janet_runtime.initJanetRuntime(model.janet)
    localRuntimeOpen = true
    let snapshot = model.shellSnapshot()
    proc evalLocalLayout(context: JanetLayoutContext): JanetLayoutEvalResult =
      localRuntime.evalLayoutDetailed(snapshot, context)

    effectiveLayoutEval = evalLocalLayout
  defer:
    if localRuntimeOpen:
      localRuntime.close()

  let screen = model.primaryScreen()
  let windows = model.runtimeWindowTable()

  if model.overviewActive:
    result = model.layoutWorkspaceStripOverview(windows, screen, effectiveLayoutEval)
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
  let activeTagData = model.tagData(model.activeTag).get()
  if activeTagData.frameTreeActive():
    model.applyFrameTreeRects(
      model.activeTag, tagForLayout, screen, currentOuterGap, currentInnerGap
    )
  elif activeTagData.bspTreeActive():
    model.applyBspTreeRects(
      model.activeTag, tagForLayout, screen, currentOuterGap, currentInnerGap
    )
  let customOuterGap = if activeTagData.frameTreeActive(): 0'i32 else: currentOuterGap
  let custom = customLayoutInstructions(
    effectiveLayoutEval, tagForLayout, windows, screen, activeTagData.customLayoutId,
    customOuterGap, currentInnerGap,
  )
  var customFrameRects: seq[tuple[frameId: FrameId, rect: rv.Rect]] = @[]
  if custom.applied:
    result.instructions = custom.instructions
    if activeTagData.frameTreeActive() and
        custom.outputTargetKind == JanetLayoutTargetKind.Frame:
      customFrameRects =
        if custom.frameInstructions.len > 0:
          frameTreeFrameRectsFromInstructions(custom.frameInstructions)
        else:
          tagForLayout.frameTreeFrameRectsFromInstructions(result.instructions)
      model.applyFrameInstructionClientRects(model.activeTag, result.instructions)
  elif activeTagData.frameTreeActive():
    result.instructions =
      model.layoutFrameTree(model.activeTag, screen, currentOuterGap, currentInnerGap)
  elif activeTagData.bspTreeActive():
    result.instructions =
      model.layoutBspTree(model.activeTag, screen, currentOuterGap, currentInnerGap)
  else:
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
  if customFrameRects.len > 0:
    result.frameTabBars = model.frameTreeTabBars(model.activeTag, customFrameRects)
    result.frameEmptyChrome =
      model.frameTreeEmptyChrome(model.activeTag, customFrameRects)
  elif activeTagData.frameTreeActive() and not custom.applied:
    result.frameTabBars =
      model.frameTreeTabBars(model.activeTag, screen, currentOuterGap, currentInnerGap)
    result.frameEmptyChrome = model.frameTreeEmptyChrome(
      model.activeTag, screen, currentOuterGap, currentInnerGap
    )
  elif activeTagData.bspTreeActive():
    result.bspPreselections =
      model.bspPreselectionOverlays(tagForLayout, currentInnerGap)
  if tagForLayout.columns.len > 0 and not custom.applied and
      not activeTagData.frameTreeActive() and not activeTagData.bspTreeActive():
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
    let maxSupported = activeTagData.tagDataUsesCoreScroller()
    let effectivelyMaximized =
      win.isMaximized and maxSupported and
      not model.columnFullWidthForWindowOnTag(model.activeTag, focused)
    if win.isFullscreen or effectivelyMaximized:
      result.instructions =
        @[rv.RenderInstruction(windowId: model.externalWindowId(focused), geom: screen)]
      result.frameTabBars.setLen(0)
      result.bspPreselections.setLen(0)

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
