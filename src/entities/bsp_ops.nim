import std/[math, options, tables]
import tag_ops
import ../state/[entity_manager, id_gen]
import ../types/[core, model]
from ../types/runtime_values import FrameNodeKind, FrameSplitOrientation

type BspLeafRect* = tuple[nodeId: BspNodeId, window: WindowId, rect: Rect]

proc bspUsesTag(model: Model, nodeId: BspNodeId, tagId: TagId): bool =
  let nodeOpt = model.bspNodes.entity(nodeId)
  nodeOpt.isSome and nodeOpt.get().tagId == tagId

proc addBspNode(
    model: var Model,
    tagId: TagId,
    kind = FrameNodeKind.Leaf,
    parent = NullBspNodeId,
    winId = NullWindowId,
): BspNodeId =
  if model.tags.entity(tagId).isNone:
    return NullBspNodeId
  result = model.counters.generateBspNodeId()
  model.bspNodes.insert(
    BspNodeData(
      id: result,
      tagId: tagId,
      kind: kind,
      parent: parent,
      ratio: 0.5'f32,
      orientation: FrameSplitOrientation.Horizontal,
      window: winId,
    )
  )

proc bspWindowVisible(model: Model, tagId: TagId, winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.admissionState == WindowAdmissionState.Admitted and not win.isFloating and
    not win.isMinimized and not win.isUnmanagedGlobal and
    model.placementByTagWindow.hasKey((tagId, winId))

proc bspNodeWindow(model: Model, nodeId: BspNodeId): WindowId =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isSome:
    nodeOpt.get().window
  else:
    NullWindowId

proc splitOrientationForRect(rect: Rect): FrameSplitOrientation =
  if rect.h > rect.w:
    FrameSplitOrientation.Vertical
  else:
    FrameSplitOrientation.Horizontal

proc firstBspLeaf(model: Model, nodeId: BspNodeId): BspNodeId =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return NullBspNodeId
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    return nodeId
  result = model.firstBspLeaf(node.firstChild)
  if result == NullBspNodeId:
    result = model.firstBspLeaf(node.secondChild)

proc firstEmptyBspLeaf(model: Model, nodeId: BspNodeId): BspNodeId =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return NullBspNodeId
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    if node.window == NullWindowId:
      return nodeId
    return NullBspNodeId
  result = model.firstEmptyBspLeaf(node.firstChild)
  if result == NullBspNodeId:
    result = model.firstEmptyBspLeaf(node.secondChild)

proc bspTreeRect(
    model: Model, nodeId, target: BspNodeId, area: Rect
): tuple[found: bool, rect: Rect] =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return
  if nodeId == target:
    return (true, area)
  let node = nodeOpt.get()
  if node.kind != FrameNodeKind.Split:
    return

  let ratio = clamp(node.ratio, 0.05'f32, 0.95'f32)
  case node.orientation
  of FrameSplitOrientation.Horizontal:
    let firstW = max(1'i32, int32(floor(float32(max(1'i32, area.w)) * ratio)))
    let secondW = max(1'i32, area.w - firstW)
    result = model.bspTreeRect(
      node.firstChild, target, Rect(x: area.x, y: area.y, w: firstW, h: area.h)
    )
    if result.found:
      return
    result = model.bspTreeRect(
      node.secondChild,
      target,
      Rect(x: area.x + firstW, y: area.y, w: secondW, h: area.h),
    )
  of FrameSplitOrientation.Vertical:
    let firstH = max(1'i32, int32(floor(float32(max(1'i32, area.h)) * ratio)))
    let secondH = max(1'i32, area.h - firstH)
    result = model.bspTreeRect(
      node.firstChild, target, Rect(x: area.x, y: area.y, w: area.w, h: firstH)
    )
    if result.found:
      return
    result = model.bspTreeRect(
      node.secondChild,
      target,
      Rect(x: area.x, y: area.y + firstH, w: area.w, h: secondH),
    )

proc bspChildRects(
    node: BspNodeData, area: Rect, gap: int32
): tuple[first, second: Rect] =
  let safeGap = max(0'i32, gap)
  let ratio = clamp(node.ratio, 0.05'f32, 0.95'f32)
  case node.orientation
  of FrameSplitOrientation.Horizontal:
    let firstW = max(1'i32, int32(float32(max(1'i32, area.w - safeGap)) * ratio))
    let secondW = max(1'i32, area.w - safeGap - firstW)
    (
      Rect(x: area.x, y: area.y, w: firstW, h: area.h),
      Rect(x: area.x + firstW + safeGap, y: area.y, w: secondW, h: area.h),
    )
  of FrameSplitOrientation.Vertical:
    let firstH = max(1'i32, int32(float32(max(1'i32, area.h - safeGap)) * ratio))
    let secondH = max(1'i32, area.h - safeGap - firstH)
    (
      Rect(x: area.x, y: area.y, w: area.w, h: firstH),
      Rect(x: area.x, y: area.y + firstH + safeGap, w: area.w, h: secondH),
    )

proc collectBspLeafRects(
    model: Model,
    nodeId: BspNodeId,
    area: Rect,
    gap: int32,
    outRects: var seq[BspLeafRect],
) =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return
  let node = nodeOpt.get()
  case node.kind
  of FrameNodeKind.Leaf:
    outRects.add((nodeId, node.window, area))
  of FrameNodeKind.Split:
    let rects = bspChildRects(node, area, gap)
    model.collectBspLeafRects(node.firstChild, rects.first, gap, outRects)
    model.collectBspLeafRects(node.secondChild, rects.second, gap, outRects)

proc bspTreeLeafRects*(
    model: Model, tagId: TagId, screen: Rect, outerGap, innerGap: int32
): seq[BspLeafRect] =
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  if root == NullBspNodeId:
    return @[]
  let safeOuterGap = max(0'i32, outerGap)
  let usable = Rect(
    x: screen.x + safeOuterGap,
    y: screen.y + safeOuterGap,
    w: max(1'i32, screen.w - safeOuterGap * 2),
    h: max(1'i32, screen.h - safeOuterGap * 2),
  )
  model.collectBspLeafRects(root, usable, innerGap, result)

proc collectBspLeafWindows(
    model: Model, nodeId: BspNodeId, outWindows: var seq[WindowId]
) =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return
  let node = nodeOpt.get()
  case node.kind
  of FrameNodeKind.Leaf:
    if node.window != NullWindowId:
      outWindows.add(node.window)
  of FrameNodeKind.Split:
    model.collectBspLeafWindows(node.firstChild, outWindows)
    model.collectBspLeafWindows(node.secondChild, outWindows)

proc bspLeafWindowsInOrder*(model: Model, tagId: TagId): seq[WindowId] =
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  model.collectBspLeafWindows(root, result)

proc focusedBspLeafOrRoot*(model: var Model, tagId: TagId): BspNodeId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return NullBspNodeId
  let focused = tagOpt.get().focusedWindow
  let focusedNode =
    model.bspNodeByTagWindow.getOrDefault((tagId, focused), NullBspNodeId)
  if focusedNode != NullBspNodeId and model.bspUsesTag(focusedNode, tagId):
    return focusedNode
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  result = model.firstBspLeaf(root)

proc addWindowToBsp*(model: var Model, tagId: TagId, winId: WindowId): bool =
  if model.tags.entity(tagId).isNone or not model.bspWindowVisible(tagId, winId):
    return false
  if model.bspNodeByTagWindow.getOrDefault((tagId, winId), NullBspNodeId) !=
      NullBspNodeId:
    return false

  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  if root == NullBspNodeId or not model.bspUsesTag(root, tagId):
    let leaf = model.addBspNode(tagId, winId = winId)
    if leaf == NullBspNodeId:
      return false
    model.bspRootsByTag[tagId] = leaf
    model.bspNodeByTagWindow[(tagId, winId)] = leaf
    discard model.setTagFocus(tagId, winId)
    return true

  let empty = model.firstEmptyBspLeaf(root)
  if empty != NullBspNodeId:
    model.bspNodes.mEntity(empty).window = winId
    model.bspNodeByTagWindow[(tagId, winId)] = empty
    discard model.setTagFocus(tagId, winId)
    return true

  let target = model.focusedBspLeafOrRoot(tagId)
  if target == NullBspNodeId:
    return false
  let oldWin = model.bspNodeWindow(target)
  if oldWin == NullWindowId:
    model.bspNodes.mEntity(target).window = winId
    model.bspNodeByTagWindow[(tagId, winId)] = target
    discard model.setTagFocus(tagId, winId)
    return true

  let oldParent = model.bspNodes.entity(target).get().parent
  let screen = Rect(
    x: 0, y: 0, w: max(1'i32, model.screenWidth), h: max(1'i32, model.screenHeight)
  )
  let targetRect = model.bspTreeRect(root, target, screen)
  let split = model.addBspNode(tagId, kind = FrameNodeKind.Split, parent = oldParent)
  let second = model.addBspNode(tagId, parent = split, winId = winId)
  if split == NullBspNodeId or second == NullBspNodeId:
    return false

  if oldParent == NullBspNodeId:
    model.bspRootsByTag[tagId] = split
  else:
    if model.bspNodes.mEntity(oldParent).firstChild == target:
      model.bspNodes.mEntity(oldParent).firstChild = split
    else:
      model.bspNodes.mEntity(oldParent).secondChild = split

  model.bspNodes.mEntity(split).orientation =
    if targetRect.found:
      targetRect.rect.splitOrientationForRect()
    else:
      FrameSplitOrientation.Horizontal
  model.bspNodes.mEntity(split).ratio = 0.5'f32
  model.bspNodes.mEntity(split).firstChild = target
  model.bspNodes.mEntity(split).secondChild = second
  model.bspNodes.mEntity(target).parent = split
  model.bspNodeByTagWindow[(tagId, winId)] = second
  discard model.setTagFocus(tagId, winId)
  true

proc replaceWindowInBsp*(
    model: var Model, tagId: TagId, oldWinId, newWinId: WindowId
): bool =
  let nodeId = model.bspNodeByTagWindow.getOrDefault((tagId, oldWinId), NullBspNodeId)
  if nodeId == NullBspNodeId or model.bspNodes.entity(nodeId).isNone:
    return false
  model.bspNodeByTagWindow.del((tagId, oldWinId))
  model.bspNodeByTagWindow[(tagId, newWinId)] = nodeId
  model.bspNodes.mEntity(nodeId).window = newWinId
  true

proc swapWindowsInBsp*(
    model: var Model,
    firstTagId: TagId,
    firstWinId: WindowId,
    secondTagId: TagId,
    secondWinId: WindowId,
): bool =
  let firstNode =
    model.bspNodeByTagWindow.getOrDefault((firstTagId, firstWinId), NullBspNodeId)
  let secondNode =
    model.bspNodeByTagWindow.getOrDefault((secondTagId, secondWinId), NullBspNodeId)
  if firstNode == NullBspNodeId or secondNode == NullBspNodeId:
    return false
  if model.bspNodes.entity(firstNode).isNone or model.bspNodes.entity(secondNode).isNone:
    return false

  model.bspNodes.mEntity(firstNode).window = secondWinId
  model.bspNodes.mEntity(secondNode).window = firstWinId
  model.bspNodeByTagWindow.del((firstTagId, firstWinId))
  model.bspNodeByTagWindow.del((secondTagId, secondWinId))
  model.bspNodeByTagWindow[(firstTagId, secondWinId)] = firstNode
  model.bspNodeByTagWindow[(secondTagId, firstWinId)] = secondNode
  true

proc adjustPromotedBspSibling(model: var Model, tagId: TagId, siblingId: BspNodeId) =
  if siblingId == NullBspNodeId:
    return
  let siblingOpt = model.bspNodes.entity(siblingId)
  if siblingOpt.isNone or siblingOpt.get().kind != FrameNodeKind.Split:
    return
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  let screen = Rect(
    x: 0, y: 0, w: max(1'i32, model.screenWidth), h: max(1'i32, model.screenHeight)
  )
  let rect = model.bspTreeRect(root, siblingId, screen)
  if rect.found:
    model.bspNodes.mEntity(siblingId).orientation = rect.rect.splitOrientationForRect()

proc removeWindowFromBsp*(model: var Model, tagId: TagId, winId: WindowId): bool =
  let nodeId = model.bspNodeByTagWindow.getOrDefault((tagId, winId), NullBspNodeId)
  if nodeId == NullBspNodeId:
    return false
  model.bspNodeByTagWindow.del((tagId, winId))
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return true

  let parentId = nodeOpt.get().parent
  if parentId == NullBspNodeId:
    model.bspRootsByTag.del(tagId)
    discard model.bspNodes.delete(nodeId)
    return true

  let parentOpt = model.bspNodes.entity(parentId)
  if parentOpt.isNone:
    discard model.bspNodes.delete(nodeId)
    return true
  let parent = parentOpt.get()
  let siblingId =
    if parent.firstChild == nodeId: parent.secondChild else: parent.firstChild
  let grandParentId = parent.parent
  if siblingId != NullBspNodeId and model.bspNodes.entity(siblingId).isSome:
    model.bspNodes.mEntity(siblingId).parent = grandParentId
  if grandParentId == NullBspNodeId:
    if siblingId == NullBspNodeId:
      model.bspRootsByTag.del(tagId)
    else:
      model.bspRootsByTag[tagId] = siblingId
  elif model.bspNodes.entity(grandParentId).isSome:
    if model.bspNodes.mEntity(grandParentId).firstChild == parentId:
      model.bspNodes.mEntity(grandParentId).firstChild = siblingId
    else:
      model.bspNodes.mEntity(grandParentId).secondChild = siblingId
  model.adjustPromotedBspSibling(tagId, siblingId)
  discard model.bspNodes.delete(nodeId)
  discard model.bspNodes.delete(parentId)
  true

proc countBspLeavesAndBalance(model: var Model, nodeId: BspNodeId): int =
  let nodeOpt = model.bspNodes.entity(nodeId)
  if nodeOpt.isNone:
    return 0
  let node = nodeOpt.get()
  case node.kind
  of FrameNodeKind.Leaf:
    if node.window != NullWindowId: 1 else: 0
  of FrameNodeKind.Split:
    let firstCount = model.countBspLeavesAndBalance(node.firstChild)
    let secondCount = model.countBspLeavesAndBalance(node.secondChild)
    let total = firstCount + secondCount
    if firstCount > 0 and secondCount > 0:
      model.bspNodes.mEntity(nodeId).ratio = float32(firstCount) / float32(total)
    total

proc balanceBspTree*(model: var Model, tagId: TagId): bool =
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  if root == NullBspNodeId:
    return false
  discard model.countBspLeavesAndBalance(root)
  true

proc equalizeBspTree*(model: var Model, tagId: TagId): bool =
  let root = model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId)
  if root == NullBspNodeId:
    return false
  var stack = @[root]
  while stack.len > 0:
    let nodeId = stack.pop()
    let nodeOpt = model.bspNodes.entity(nodeId)
    if nodeOpt.isNone:
      continue
    let node = nodeOpt.get()
    if node.kind == FrameNodeKind.Split:
      model.bspNodes.mEntity(nodeId).ratio = 0.5'f32
      stack.add(node.firstChild)
      stack.add(node.secondChild)
  true

proc adjustFocusedBspSplit*(
    model: var Model, tagId: TagId, orientation: FrameSplitOrientation, delta: float32
): bool =
  let focused = model.tags.entity(tagId)
  if focused.isNone:
    return false
  var childId = model.bspNodeByTagWindow.getOrDefault(
    (tagId, focused.get().focusedWindow), NullBspNodeId
  )
  while childId != NullBspNodeId:
    let childOpt = model.bspNodes.entity(childId)
    if childOpt.isNone:
      return false
    let parentId = childOpt.get().parent
    if parentId == NullBspNodeId:
      return false
    let parentOpt = model.bspNodes.entity(parentId)
    if parentOpt.isNone:
      return false
    let parent = parentOpt.get()
    if parent.orientation == orientation:
      let signedDelta =
        if parent.firstChild == childId:
          delta
        else:
          -delta
      let next = clamp(parent.ratio + signedDelta, 0.05'f32, 0.95'f32)
      if next == parent.ratio:
        return false
      model.bspNodes.mEntity(parentId).ratio = next
      return true
    childId = parentId
  false

proc syncTagBspFromPlacement*(model: var Model, tagId: TagId): bool =
  if model.tags.entity(tagId).isNone:
    return false

  var visibleWindows: seq[WindowId] = @[]
  var visibleCounts = initTable[WindowId, int]()
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    if model.bspWindowVisible(tagId, winId):
      visibleWindows.add(winId)
      visibleCounts[winId] = visibleCounts.getOrDefault(winId, 0) + 1

  var leafCounts = initTable[WindowId, int]()
  var leafNodeByWindow = initTable[WindowId, BspNodeId]()
  var mustRebuild = false
  for node in model.bspNodes.entities:
    if node.tagId != tagId or node.kind != FrameNodeKind.Leaf or
        node.window == NullWindowId:
      continue
    if not visibleCounts.hasKey(node.window):
      mustRebuild = true
    leafCounts[node.window] = leafCounts.getOrDefault(node.window, 0) + 1
    if leafCounts[node.window] == 1:
      leafNodeByWindow[node.window] = node.id
    else:
      mustRebuild = true

  var mapKeys: seq[(TagId, WindowId)] = @[]
  var oldNodeByWindow = initTable[WindowId, BspNodeId]()
  for key in model.bspNodeByTagWindow.keys:
    if key[0] == tagId:
      mapKeys.add(key)
      oldNodeByWindow[key[1]] = model.bspNodeByTagWindow[key]
  for key in mapKeys:
    model.bspNodeByTagWindow.del(key)

  if mustRebuild:
    var nodeIds: seq[BspNodeId] = @[]
    for node in model.bspNodes.entities:
      if node.tagId == tagId:
        nodeIds.add(node.id)
    for nodeId in nodeIds:
      discard model.bspNodes.delete(nodeId)
    model.bspRootsByTag.del(tagId)

  if not mustRebuild:
    for winId, nodeId in leafNodeByWindow.pairs:
      model.bspNodeByTagWindow[(tagId, winId)] = nodeId
      if oldNodeByWindow.getOrDefault(winId, NullBspNodeId) != nodeId:
        result = true
    for winId in oldNodeByWindow.keys:
      if not leafNodeByWindow.hasKey(winId):
        result = true

  let focused = model.tags.entity(tagId).get().focusedWindow
  for winId in visibleWindows:
    if model.bspNodeByTagWindow.getOrDefault((tagId, winId), NullBspNodeId) ==
        NullBspNodeId:
      result = model.addWindowToBsp(tagId, winId) or result
  if focused != NullWindowId and visibleCounts.hasKey(focused):
    result = model.setTagFocus(tagId, focused) or result
  result = result or mustRebuild

proc restoreTagBspNodes*(
    model: var Model, tagId: TagId, restored: RestoredTagData
): bool =
  if model.tags.entity(tagId).isNone or restored.bspNodes.len == 0:
    return false
  if model.bspRootsByTag.getOrDefault(tagId, NullBspNodeId) != NullBspNodeId:
    return false

  var root = NullBspNodeId
  for node in restored.bspNodes:
    if node.id == NullBspNodeId or model.bspNodes.entity(node.id).isSome:
      continue
    model.bspNodes.insert(
      BspNodeData(
        id: node.id,
        tagId: tagId,
        kind: node.kind,
        parent: node.parent,
        firstChild: node.firstChild,
        secondChild: node.secondChild,
        orientation: node.orientation,
        ratio: clamp(node.ratio, 0.05'f32, 0.95'f32),
        window: NullWindowId,
      )
    )
    if node.parent == NullBspNodeId and root == NullBspNodeId:
      root = node.id
    let rawId = uint32(node.id)
    if rawId < high(uint32) and model.counters.nextBspNodeId <= rawId:
      model.counters.nextBspNodeId = rawId + 1

  if root == NullBspNodeId and restored.bspNodes.len > 0:
    root = restored.bspNodes[0].id
  if root == NullBspNodeId or model.bspNodes.entity(root).isNone:
    return result

  model.bspRootsByTag[tagId] = root
  true

proc restoreWindowBspPlacement*(
    model: var Model,
    tagId: TagId,
    restored: RestoredTagData,
    externalId: ExternalWindowId,
    winId: WindowId,
): bool =
  var nodeId = NullBspNodeId
  for node in restored.bspNodes:
    if node.window == externalId:
      nodeId = node.id
      break
  if nodeId == NullBspNodeId or model.bspNodes.entity(nodeId).isNone:
    return false
  model.bspNodes.mEntity(nodeId).window = winId
  model.bspNodeByTagWindow[(tagId, winId)] = nodeId
  true
