import std/options
import workspaces
import ../core/[layout_descriptor_codec, layout_selection_codec]
from ../core/native_layout_codec import
  BspTreeLayoutId, FrameTreeLayoutId, SplitTreeLayoutId, nativeLayoutIdString
import ../state/engine
from ../types/projection_values import RenderInstruction
from ../types/runtime_values import Direction, LayoutMode
import layout_projection
import popup_tree

type FocusCandidate = object
  winId: WindowId
  geom: typeof(RenderInstruction().geom)
  order: int

type
  DirectionalTargetKind* {.pure.} = enum
    None
    Window
    Frame

  DirectionalTarget* = object
    kind*: DirectionalTargetKind
    window*: WindowId
    frame*: FrameId

proc windowOnTag(model: Model, tagId: TagId, winId: WindowId): bool =
  model.placementForWindowOnTag(tagId, winId).isSome

proc focusedOnActiveTag*(model: Model): WindowId =
  model.effectiveTagFocusedWindow(model.activeTag)

proc recomputeVisibleFocus*(model: var Model, tagId: TagId): WindowId =
  result = model.effectiveTagFocusedWindow(tagId)
  discard model.setTagFocus(tagId, result)

proc tagForWindow*(model: Model, winId: WindowId): TagId =
  if model.activeTag != NullTagId and model.windowOnTag(model.activeTag, winId):
    return model.activeTag

  let position = model.firstWindowPosition(winId)
  if position.found:
    return position.tagId
  NullTagId

proc isFocusableWindow*(model: Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  winOpt.isSome and not winOpt.get().isUnmanagedGlobal and not winOpt.get().isMinimized and
    winOpt.get().windowAdmitted()

proc activeTagUsesFrameTree*(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and
    tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId

proc activeTagUsesBspTree*(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().nativeLayoutId.nativeLayoutIdString() == BspTreeLayoutId

proc activeTagUsesSplitTree*(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and
    tagOpt.get().nativeLayoutId.nativeLayoutIdString() == SplitTreeLayoutId

proc focusableFrameWindow(model: Model, tagId: TagId, frameId: FrameId): WindowId =
  let frameOpt = model.frameData(frameId)
  if frameOpt.isNone:
    return NullWindowId
  let active = frameOpt.get().activeWindow
  if active != NullWindowId and model.isFocusableWindow(active) and
      model.windowOnTag(tagId, active):
    return active
  for winId in model.windowsForFrame(frameId):
    if model.isFocusableWindow(winId) and model.windowOnTag(tagId, winId):
      return winId
  NullWindowId

proc popupFocusTarget(
    model: Model, winId: WindowId, tagId: TagId, restorePopupTree: bool
): WindowId =
  if not restorePopupTree:
    return winId
  let root = model.popupRoot(winId)
  if root == NullWindowId or root != winId:
    return winId
  let restored = model.lastFocusedInPopupTree(root, tagId)
  if restored != NullWindowId:
    return restored
  winId

proc focusWindow*(
    model: var Model,
    winId: WindowId,
    retargetViewport = true,
    restorePopupTree = true,
    snapViewport = false,
): bool =
  var target = winId
  if model.windowData(target).isNone:
    return false
  let tagId = model.tagForWindow(target)
  if tagId == NullTagId:
    return false
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  target = model.popupFocusTarget(target, tagId, restorePopupTree)
  if model.windowData(target).isNone:
    return false

  discard model.setGroupActiveWindow(target)
  discard model.setWindowMinimized(target, false)
  discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()
  discard model.recordWorkspace(tagId)
  discard model.setTagFocus(tagId, target)
  if retargetViewport:
    discard model.requestTagViewportRetarget(tagId)
    if snapViewport:
      discard model.requestTagViewportSnap(tagId)
  discard model.recordFocus(target)
  discard model.clearPendingDialogFocus(target)
  true

proc focusWorkspaceSlot*(model: var Model, slot: uint32): bool =
  let tagId = model.ensureWorkspaceSlot(slot)
  if tagId == NullTagId:
    return false
  discard model.setActiveWorkspace(tagId)
  model.refreshVisibleWorkspaceSlots()
  discard model.recordWorkspace(tagId)
  let focused = model.recomputeVisibleFocus(tagId)
  if focused != NullWindowId:
    discard model.recordFocus(focused)
  true

proc focusWorkspaceIndex*(model: var Model, index: uint32): bool =
  let slot = model.workspaceSlotForClampedIndex(index)
  slot != 0 and model.focusWorkspaceSlot(slot)

proc focusExternalWindow*(
    model: var Model, externalId: ExternalWindowId, restorePopupTree = true
): bool =
  let winId = model.windowForExternal(externalId)
  if winId != NullWindowId and winId == model.activeScratchpadWindow():
    discard model.setWindowMinimized(winId, false)
    discard model.recordFocus(winId)
    discard model.clearPendingDialogFocus(winId)
    return true
  winId != NullWindowId and model.focusWindow(
    winId, restorePopupTree = restorePopupTree
  )

proc focusMostRecentWindow*(model: var Model): bool =
  var candidates: seq[WindowId] = @[]
  for candidate in model.focusHistoryIds():
    if model.isFocusableWindow(candidate) and model.tagForWindow(candidate) != NullTagId:
      candidates.add(candidate)
  discard model.replaceFocusHistory(candidates)
  if candidates.len == 0:
    return false
  model.focusWindow(candidates[^1])

proc focusMostRecentWindowOnTag*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  for candidate in model.focusHistoryIdsReverse():
    if model.isFocusableWindow(candidate) and model.windowOnTag(tagId, candidate):
      return model.focusWindow(candidate)
  false

proc isRestorableWorkspace(model: Model, tagId: TagId): bool =
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  tagOpt.get().slot <= model.defaultWorkspaceCount() or
    model.tagHasNonStickyFocusableWindow(tagId)

proc focusMostRecentWorkspace*(model: var Model): bool =
  var candidates: seq[TagId] = @[]
  for candidate in model.workspaceHistoryIds():
    if model.isRestorableWorkspace(candidate):
      candidates.add(candidate)
  discard model.replaceWorkspaceHistory(candidates)
  if candidates.len == 0:
    return false

  for i in countdown(candidates.len - 1, 0):
    if candidates[i] != model.activeTag:
      let tagOpt = model.tagData(candidates[i])
      if tagOpt.isSome:
        return model.focusWorkspaceSlot(tagOpt.get().slot)
  false

proc focusLast*(model: var Model): bool =
  let current = model.focusedOnActiveTag()
  for candidate in model.focusHistoryIdsReverse():
    if candidate != current and model.isFocusableWindow(candidate):
      return model.focusWindow(candidate)
  false

proc focusableWindowsOnTag(model: Model, tagId: TagId): seq[WindowId] =
  for winId, win in model.windowsOnTagWithId(tagId):
    if not win.isUnmanagedGlobal and not win.isMinimized and win.windowAdmitted():
      result.add(winId)

proc focusCycle*(model: var Model, step: int): bool =
  if model.overviewActive and model.tagUsesAggregateOverview(model.activeTag):
    return false
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  var windows: seq[WindowId] = @[]
  if model.activeTagUsesBspTree():
    for winId in model.bspLeafWindowsInOrder(tagId):
      if model.isFocusableWindow(winId):
        windows.add(winId)
  elif model.activeTagUsesSplitTree():
    for winId in model.splitLeafWindowsInOrder(tagId):
      if model.isFocusableWindow(winId):
        windows.add(winId)
  else:
    windows = model.focusableWindowsOnTag(tagId)
  if windows.len == 0:
    return false

  let idx = windows.find(tagOpt.get().focusedWindow)
  let nextIdx =
    if idx == -1:
      0
    else:
      (idx + step + windows.len) mod windows.len
  let target = windows[nextIdx]
  discard model.setTagFocus(tagId, target)
  discard model.requestTagViewportRetarget(tagId)
  discard model.recordWorkspace(tagId)
  discard model.recordFocus(target)
  true

proc focusOverviewTabNext*(model: var Model): bool =
  if not model.overviewActive:
    return false
  let windows = model.overviewWindowIds()
  if windows.len == 0:
    return false
  let selected = model.selectedOverviewWindow()
  let idx = windows.find(selected)
  let nextIdx =
    if idx == -1:
      0
    else:
      (idx + 1) mod windows.len
  let target = windows[nextIdx]
  result = model.focusWindow(target)
  result = model.setOverviewSelection(target) or result

proc visibleWindowNear(model: Model, columnId: ColumnId, preferredIdx: int): WindowId =
  let count = model.windowCountForColumn(columnId)
  if count == 0:
    return NullWindowId

  let idx = clamp(preferredIdx, 0, count - 1)
  let preferred = model.windowAt(columnId, idx)
  if model.isFocusableWindow(preferred):
    return preferred

  for distance in 1 ..< count:
    let before = idx - distance
    let beforeWin = model.windowAt(columnId, before)
    if beforeWin != NullWindowId and model.isFocusableWindow(beforeWin):
      return beforeWin
    let after = idx + distance
    let afterWin = model.windowAt(columnId, after)
    if afterWin != NullWindowId and model.isFocusableWindow(afterWin):
      return afterWin
  NullWindowId

proc findWindowPosition(
    model: Model, tagId: TagId, winId: WindowId
): tuple[found: bool, colIdx, winIdx: int, columnId: ColumnId] =
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return (false, -1, -1, NullColumnId)
  let placement = placementOpt.get()
  let colIdx = int(model.columnIndexForTag(tagId, placement.columnId)) - 1
  if colIdx < 0:
    return (false, -1, -1, NullColumnId)
  (true, colIdx, int(placement.windowIdx) - 1, placement.columnId)

proc centerX(rect: typeof(RenderInstruction().geom)): int64 =
  int64(rect.x) * 2'i64 + int64(rect.w)

proc centerY(rect: typeof(RenderInstruction().geom)): int64 =
  int64(rect.y) * 2'i64 + int64(rect.h)

proc intervalDistance(aStart, aLen, bStart, bLen: int64): int64 =
  let aEnd = aStart + aLen
  let bEnd = bStart + bLen
  if aEnd < bStart:
    bStart - aEnd
  elif bEnd < aStart:
    aStart - bEnd
  else:
    0'i64

proc verticalDistance(a, b: typeof(RenderInstruction().geom)): int64 =
  intervalDistance(int64(a.y), int64(a.h), int64(b.y), int64(b.h))

proc horizontalDistance(a, b: typeof(RenderInstruction().geom)): int64 =
  intervalDistance(int64(a.x), int64(a.w), int64(b.x), int64(b.w))

proc sameRect(a, b: typeof(RenderInstruction().geom)): bool =
  a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h

proc overlapLen(aStart, aLen, bStart, bLen: int64): int64 =
  max(0'i64, min(aStart + aLen, bStart + bLen) - max(aStart, bStart))

proc frameTreeFocusRects(
    model: Model
): seq[tuple[frameId: FrameId, rect: typeof(RenderInstruction().geom)]] =
  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for _, win in model.windowsOnTagWithId(model.activeTag):
    if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
        not win.isUnmanagedGlobal:
      inc tiledWindowCount
  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0
  model.frameTreeLayoutRects(
    model.activeTag, model.primaryScreen(), currentOuterGap, currentInnerGap
  )

proc activeBspLeafRects(model: Model): seq[BspLeafRect] =
  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for _, win in model.windowsOnTagWithId(model.activeTag):
    if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
        not win.isUnmanagedGlobal:
      inc tiledWindowCount
  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0
  model.bspTreeLeafRects(
    model.activeTag, model.primaryScreen(), currentOuterGap, currentInnerGap
  )

proc activeSplitLeafRects(model: Model): seq[SplitLeafRect] =
  var currentOuterGap = model.outerGaps
  var currentInnerGap = model.innerGaps
  var tiledWindowCount = 0
  for _, win in model.windowsOnTagWithId(model.activeTag):
    if win.windowAdmitted() and not win.isFloating and not win.isMinimized and
        not win.isUnmanagedGlobal:
      inc tiledWindowCount
  if model.smartGaps and tiledWindowCount <= 1:
    currentOuterGap = 0
    currentInnerGap = 0
  model.splitTreeLeafRects(
    model.activeTag,
    model.primaryScreen(),
    currentOuterGap,
    currentInnerGap,
    FrameTreeTabBarHeight,
  )

proc frameTreeNeighborCandidate(
    current, candidate: typeof(RenderInstruction().geom), direction: Direction
): tuple[found: bool, distance: int64] =
  case direction
  of Direction.DirLeft:
    let overlap = overlapLen(
      int64(current.y), int64(current.h), int64(candidate.y), int64(candidate.h)
    )
    if candidate.x + candidate.w <= current.x and overlap > 0:
      return (true, int64(current.x) - int64(candidate.x + candidate.w))
  of Direction.DirRight:
    let overlap = overlapLen(
      int64(current.y), int64(current.h), int64(candidate.y), int64(candidate.h)
    )
    if candidate.x >= current.x + current.w and overlap > 0:
      return (true, int64(candidate.x) - int64(current.x + current.w))
  of Direction.DirUp:
    let overlap = overlapLen(
      int64(current.x), int64(current.w), int64(candidate.x), int64(candidate.w)
    )
    if candidate.y + candidate.h <= current.y and overlap > 0:
      return (true, int64(current.y) - int64(candidate.y + candidate.h))
  of Direction.DirDown:
    let overlap = overlapLen(
      int64(current.x), int64(current.w), int64(candidate.x), int64(candidate.w)
    )
    if candidate.y >= current.y + current.h and overlap > 0:
      return (true, int64(candidate.y) - int64(current.y + current.h))
  (false, 0'i64)

proc bspNeighborCandidate(
    current, candidate: Rect, direction: Direction
): tuple[found: bool, distance: int64] =
  case direction
  of Direction.DirLeft:
    let overlap = overlapLen(
      int64(current.y), int64(current.h), int64(candidate.y), int64(candidate.h)
    )
    if candidate.x < current.x and overlap > 0:
      return (true, max(0'i64, int64(current.x) - int64(candidate.x + candidate.w)))
  of Direction.DirRight:
    let overlap = overlapLen(
      int64(current.y), int64(current.h), int64(candidate.y), int64(candidate.h)
    )
    if candidate.x + candidate.w > current.x + current.w and overlap > 0:
      return (true, max(0'i64, int64(candidate.x) - int64(current.x + current.w)))
  of Direction.DirUp:
    let overlap = overlapLen(
      int64(current.x), int64(current.w), int64(candidate.x), int64(candidate.w)
    )
    if candidate.y < current.y and overlap > 0:
      return (true, max(0'i64, int64(current.y) - int64(candidate.y + candidate.h)))
  of Direction.DirDown:
    let overlap = overlapLen(
      int64(current.x), int64(current.w), int64(candidate.x), int64(candidate.w)
    )
    if candidate.y + candidate.h > current.y + current.h and overlap > 0:
      return (true, max(0'i64, int64(candidate.y) - int64(current.y + current.h)))
  (false, 0'i64)

proc focusHistoryRank(model: Model, winId: WindowId): int =
  result = high(int)
  var rank = 0
  for candidate in model.focusHistoryIdsReverse():
    if candidate == winId:
      return rank
    inc rank

proc bspNeighborWindow*(model: Model, direction: Direction): WindowId =
  if not model.activeTagUsesBspTree():
    return NullWindowId
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return NullWindowId

  let leaves = model.activeBspLeafRects()
  var current = Rect()
  var currentFound = false
  for leaf in leaves:
    if leaf.window == focused:
      current = leaf.rect
      currentFound = true
      break
  if not currentFound:
    return NullWindowId

  var best = NullWindowId
  var bestDistance = high(int64)
  var bestRank = high(int)
  for leaf in leaves:
    if leaf.window == NullWindowId or leaf.window == focused or
        not model.isFocusableWindow(leaf.window):
      continue
    let candidate = bspNeighborCandidate(current, leaf.rect, direction)
    if candidate.found:
      let rank = model.focusHistoryRank(leaf.window)
      if candidate.distance < bestDistance or
          (candidate.distance == bestDistance and rank < bestRank):
        best = leaf.window
        bestDistance = candidate.distance
        bestRank = rank
  best

proc splitTreeNeighborWindow*(model: Model, direction: Direction): WindowId =
  if not model.activeTagUsesSplitTree():
    return NullWindowId
  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return NullWindowId

  let structural = model.splitTreeStructuralNeighbor(direction)
  if structural != NullWindowId:
    return structural

  let leaves = model.activeSplitLeafRects()
  var current = Rect()
  var currentFound = false
  for leaf in leaves:
    if leaf.window == focused:
      current = leaf.rect
      currentFound = true
      break
  if not currentFound:
    return NullWindowId

  var best = NullWindowId
  var bestDistance = high(int64)
  var bestRank = high(int)
  for leaf in leaves:
    if leaf.window == NullWindowId or leaf.window == focused or
        not model.isFocusableWindow(leaf.window):
      continue
    let candidate = bspNeighborCandidate(current, leaf.rect, direction)
    if candidate.found:
      let rank = model.focusHistoryRank(leaf.window)
      if candidate.distance < bestDistance or
          (candidate.distance == bestDistance and rank < bestRank):
        best = leaf.window
        bestDistance = candidate.distance
        bestRank = rank
  best

proc frameNeighborTarget*(model: var Model, direction: Direction): DirectionalTarget =
  if not model.activeTagUsesFrameTree():
    return DirectionalTarget(kind: DirectionalTargetKind.None)
  let tagId = model.activeTag
  if tagId == NullTagId:
    return DirectionalTarget(kind: DirectionalTargetKind.None)
  var currentFrame = model.focusedFrameOrRoot(tagId)
  if currentFrame == NullFrameId:
    let focused = model.focusedOnActiveTag()
    currentFrame = model.frameForWindowOnTag(tagId, focused)
    if currentFrame == NullFrameId:
      return DirectionalTarget(kind: DirectionalTargetKind.None)

  let rects = model.frameTreeFocusRects()
  var currentRect = typeof(RenderInstruction().geom)()
  var currentFound = false
  for item in rects:
    if item.frameId == currentFrame:
      currentRect = item.rect
      currentFound = true
      break
  if not currentFound:
    return DirectionalTarget(kind: DirectionalTargetKind.None)

  var bestFrame = NullFrameId
  var bestDistance = high(int64)
  for item in rects:
    if item.frameId == currentFrame:
      continue
    let candidate = frameTreeNeighborCandidate(currentRect, item.rect, direction)
    if candidate.found and candidate.distance < bestDistance:
      bestFrame = item.frameId
      bestDistance = candidate.distance

  if bestFrame == NullFrameId:
    return DirectionalTarget(kind: DirectionalTargetKind.None)

  let target = model.focusableFrameWindow(tagId, bestFrame)
  DirectionalTarget(kind: DirectionalTargetKind.Frame, window: target, frame: bestFrame)

proc focusCandidateIndex(candidates: openArray[FocusCandidate], winId: WindowId): int =
  for idx, candidate in candidates:
    if candidate.winId == winId:
      return idx
  -1

proc visualFocusCandidates(model: Model): seq[FocusCandidate] =
  for order, instr in model.activeFocusLayoutInstructions():
    let winId = model.windowForExternal(ExternalWindowId(uint32(instr.windowId)))
    if winId == NullWindowId or not model.isFocusableWindow(winId):
      continue
    if result.focusCandidateIndex(winId) != -1:
      continue
    result.add(FocusCandidate(winId: winId, geom: instr.geom, order: order))

proc focusNavigationLayoutMode(model: Model): Option[LayoutMode] =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return none(LayoutMode)
  let tag = tagOpt.get()
  let customId = tag.customLayoutId.layoutIdString()
  if customId.len > 0:
    let bundled = layoutModeForBundledId(customId)
    if bundled.isSome:
      return bundled
    return none(LayoutMode)
  some(tag.layoutMode)

proc orderedFallbackTarget(
    candidates: openArray[FocusCandidate], currentIdx: int, direction: Direction
): WindowId =
  if candidates.len <= 1:
    return NullWindowId

  let step =
    case direction
    of Direction.DirLeft, Direction.DirUp: -1
    of Direction.DirRight, Direction.DirDown: 1
  let targetIdx = (currentIdx + step + candidates.len) mod candidates.len
  candidates[targetIdx].winId

proc visualDirectionalWindow*(model: Model, direction: Direction): WindowId =
  if model.activeTagUsesFrameTree():
    return NullWindowId
  if model.activeTagUsesBspTree():
    return NullWindowId

  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId:
    return NullWindowId

  let candidates = model.visualFocusCandidates()
  let currentIdx = candidates.focusCandidateIndex(focused)
  if currentIdx < 0:
    return NullWindowId
  let current = candidates[currentIdx]
  let currentCx = current.geom.centerX()
  let currentCy = current.geom.centerY()
  let layoutMode = model.focusNavigationLayoutMode()
  if layoutMode.isSome and layoutMode.get() == LayoutMode.Scroller and
      direction in {Direction.DirUp, Direction.DirDown}:
    return NullWindowId

  let useIntervalGeometry =
    layoutMode.isSome and
    layoutMode.get() in {LayoutMode.Scroller, LayoutMode.VerticalScroller}
  let preferPrimaryDistance =
    layoutMode.isSome and layoutMode.get() == LayoutMode.CenterTile and
    direction in {Direction.DirLeft, Direction.DirRight}

  var bestIdx = -1
  var bestPrimary = high(int64)
  var bestPerp = high(int64)
  var bestOrder = high(int)

  for idx, candidate in candidates:
    if idx == currentIdx:
      continue

    let cx = candidate.geom.centerX()
    let cy = candidate.geom.centerY()
    var primary: int64
    var perp: int64
    if useIntervalGeometry:
      case direction
      of Direction.DirLeft:
        if cx >= currentCx:
          continue
        primary =
          max(0'i64, int64(current.geom.x) - int64(candidate.geom.x + candidate.geom.w))
        perp = current.geom.verticalDistance(candidate.geom)
      of Direction.DirRight:
        if cx <= currentCx:
          continue
        primary =
          max(0'i64, int64(candidate.geom.x) - int64(current.geom.x + current.geom.w))
        perp = current.geom.verticalDistance(candidate.geom)
      of Direction.DirUp:
        if cy >= currentCy:
          continue
        primary =
          max(0'i64, int64(current.geom.y) - int64(candidate.geom.y + candidate.geom.h))
        perp = current.geom.horizontalDistance(candidate.geom)
      of Direction.DirDown:
        if cy <= currentCy:
          continue
        primary =
          max(0'i64, int64(candidate.geom.y) - int64(current.geom.y + current.geom.h))
        perp = current.geom.horizontalDistance(candidate.geom)
    else:
      (primary, perp) =
        case direction
        of Direction.DirLeft:
          (currentCx - cx, abs(currentCy - cy))
        of Direction.DirRight:
          (cx - currentCx, abs(currentCy - cy))
        of Direction.DirUp:
          (currentCy - cy, abs(currentCx - cx))
        of Direction.DirDown:
          (cy - currentCy, abs(currentCx - cx))
      if primary <= 0:
        continue
    let better =
      if preferPrimaryDistance:
        primary < bestPrimary or (primary == bestPrimary and perp < bestPerp) or
          (primary == bestPrimary and perp == bestPerp and candidate.order < bestOrder)
      else:
        perp < bestPerp or (perp == bestPerp and primary < bestPrimary) or
          (perp == bestPerp and primary == bestPrimary and candidate.order < bestOrder)
    if better:
      bestIdx = idx
      bestPrimary = primary
      bestPerp = perp
      bestOrder = candidate.order

  if bestIdx >= 0:
    return candidates[bestIdx].winId

  for idx, candidate in candidates:
    if idx != currentIdx and candidate.geom.sameRect(current.geom):
      return candidates.orderedFallbackTarget(currentIdx, direction)

  NullWindowId

proc placementDirectionalWindow*(model: Model, direction: Direction): WindowId =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return NullWindowId

  let columnCount = model.columnCountForTag(tagId)
  case direction
  of Direction.DirLeft:
    var i = pos.colIdx - 1
    while i >= 0:
      result = model.visibleWindowNear(model.columnAt(tagId, i), pos.winIdx)
      if result != NullWindowId:
        return
      dec i
  of Direction.DirRight:
    var i = pos.colIdx + 1
    while i < columnCount:
      result = model.visibleWindowNear(model.columnAt(tagId, i), pos.winIdx)
      if result != NullWindowId:
        return
      inc i
  of Direction.DirUp:
    if pos.winIdx > 0:
      result = model.windowAt(pos.columnId, pos.winIdx - 1)
  of Direction.DirDown:
    let count = model.windowCountForColumn(pos.columnId)
    if pos.winIdx >= 0 and pos.winIdx < count - 1:
      result = model.windowAt(pos.columnId, pos.winIdx + 1)
  if result != NullWindowId and not model.isFocusableWindow(result):
    result = NullWindowId

proc directionalTarget*(model: var Model, direction: Direction): DirectionalTarget =
  let frameTarget = model.frameNeighborTarget(direction)
  if frameTarget.kind != DirectionalTargetKind.None:
    return frameTarget

  let bspTarget = model.bspNeighborWindow(direction)
  if bspTarget != NullWindowId:
    return DirectionalTarget(kind: DirectionalTargetKind.Window, window: bspTarget)
  let splitTarget = model.splitTreeNeighborWindow(direction)
  if splitTarget != NullWindowId:
    return DirectionalTarget(kind: DirectionalTargetKind.Window, window: splitTarget)
  if model.activeTagUsesFrameTree() or model.activeTagUsesBspTree() or
      model.activeTagUsesSplitTree():
    return DirectionalTarget(kind: DirectionalTargetKind.None)

  let visualTarget = model.visualDirectionalWindow(direction)
  if visualTarget != NullWindowId:
    return DirectionalTarget(kind: DirectionalTargetKind.Window, window: visualTarget)

  let placementTarget = model.placementDirectionalWindow(direction)
  if placementTarget != NullWindowId:
    return
      DirectionalTarget(kind: DirectionalTargetKind.Window, window: placementTarget)

  DirectionalTarget(kind: DirectionalTargetKind.None)

proc focusByVisualDirection*(model: var Model, direction: Direction): bool =
  let target = model.directionalTarget(direction)
  case target.kind
  of DirectionalTargetKind.Window:
    model.focusWindow(target.window)
  of DirectionalTargetKind.Frame:
    if target.window != NullWindowId:
      model.focusWindow(target.window)
    else:
      model.setFocusedFrame(model.activeTag, target.frame)
  of DirectionalTargetKind.None:
    false

proc focusColumnByStep*(model: var Model, step: int): bool =
  if step == 0:
    return false
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if not pos.found:
    return false

  let columnCount = model.columnCountForTag(tagId)
  var colIdx = pos.colIdx + step
  while colIdx >= 0 and colIdx < columnCount:
    let target = model.visibleWindowNear(model.columnAt(tagId, colIdx), pos.winIdx)
    if target != NullWindowId:
      return model.focusWindow(target)
    colIdx += step
  false

proc focusColumnAtEdge*(model: var Model, first: bool): bool =
  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  let preferredIdx = if pos.found: pos.winIdx else: 0
  let columnCount = model.columnCountForTag(tagId)

  if first:
    for idx in 0 ..< columnCount:
      let columnId = model.columnAt(tagId, idx)
      let target = model.visibleWindowNear(columnId, preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  else:
    for i in countdown(columnCount - 1, 0):
      let target = model.visibleWindowNear(model.columnAt(tagId, i), preferredIdx)
      if target != NullWindowId:
        return model.focusWindow(target)
  false

proc focusWindowOrWorkspace*(model: var Model, direction: int): bool =
  if direction == 0:
    return false

  let tagId = model.activeTag
  let focused = model.focusedOnActiveTag()
  let pos = model.findWindowPosition(tagId, focused)
  if pos.found:
    let count = model.windowCountForColumn(pos.columnId)
    var winIdx = pos.winIdx + direction
    while winIdx >= 0 and winIdx < count:
      let candidate = model.windowAt(pos.columnId, winIdx)
      if model.isFocusableWindow(candidate):
        return model.focusWindow(candidate)
      winIdx += direction

  let target = model.nearestWorkspaceSlot(direction, false)
  target != 0 and model.focusWorkspaceSlot(target)

proc focusOverviewWorkspaceStep*(model: var Model, direction: int): bool =
  let target = model.overviewWorkspaceStepSlot(direction)
  target != 0 and model.focusWorkspaceSlot(target)

proc focusOverviewBoundaryStep(model: var Model, direction: Direction): bool =
  case direction
  of Direction.DirUp:
    model.focusOverviewWorkspaceStep(-1)
  of Direction.DirDown:
    model.focusOverviewWorkspaceStep(1)
  of Direction.DirLeft, Direction.DirRight:
    false

proc focusByDirection*(model: var Model, direction: Direction): bool =
  if model.overviewActive and model.tagUsesAggregateOverview(model.activeTag):
    return model.focusOverviewBoundaryStep(direction)
  if model.focusByVisualDirection(direction):
    return true

  if model.overviewActive:
    return model.focusOverviewBoundaryStep(direction)

  false

proc collapseEmptyActiveDynamicWorkspace*(model: var Model): bool =
  let oldSlot = model.activeWorkspaceSlot()
  if oldSlot == 0 or oldSlot <= model.defaultWorkspaceCount():
    return false
  let oldTag = model.activeTag
  if oldTag == NullTagId or model.tagData(oldTag).isNone:
    return false
  if model.tagHasNonStickyLiveWindows(oldTag):
    return false

  let fallback = model.lowerWorkspaceFallback(oldSlot)
  if fallback == 0 or fallback == oldSlot:
    return false
  model.focusWorkspaceSlot(fallback)
