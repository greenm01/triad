import std/[options, tables]
import active_workspace_ops, tag_ops
import ../state/[entity_manager, id_gen, iterators]
import ../types/[core, model]
from ../core/native_layout_codec import SplitTreeLayoutId, nativeLayoutIdString
from ../types/runtime_values import
  Direction, FrameNodeKind, FrameSplitOrientation, SplitTreeNodeMode

type SplitLeafRect* = tuple[nodeId: SplitNodeId, window: WindowId, rect: Rect]
type SplitNodeRect* = tuple[nodeId: SplitNodeId, rect: Rect]

proc splitModeIsSplit(mode: SplitTreeNodeMode): bool =
  mode in {SplitTreeNodeMode.SplitH, SplitTreeNodeMode.SplitV}

proc directionMatchesSplitMode(direction: Direction, mode: SplitTreeNodeMode): bool =
  case direction
  of Direction.DirLeft, Direction.DirRight:
    mode == SplitTreeNodeMode.SplitH
  of Direction.DirUp, Direction.DirDown:
    mode == SplitTreeNodeMode.SplitV

proc directionIsPositive(direction: Direction): bool =
  direction in {Direction.DirRight, Direction.DirDown}

proc normalizedLastSplitMode(mode: SplitTreeNodeMode): SplitTreeNodeMode =
  if mode.splitModeIsSplit(): mode else: SplitTreeNodeMode.SplitH

proc splitTreeUsesTag(model: Model, nodeId: SplitNodeId, tagId: TagId): bool =
  let nodeOpt = model.splitNodes.entity(nodeId)
  nodeOpt.isSome and nodeOpt.get().tagId == tagId

proc tagUsesSplitTree(tag: TagData): bool =
  tag.nativeLayoutId.nativeLayoutIdString() == SplitTreeLayoutId

proc modeForOrientation(orientation: FrameSplitOrientation): SplitTreeNodeMode =
  case orientation
  of FrameSplitOrientation.Horizontal: SplitTreeNodeMode.SplitH
  of FrameSplitOrientation.Vertical: SplitTreeNodeMode.SplitV

proc orientationForMode(mode: SplitTreeNodeMode): FrameSplitOrientation =
  case mode
  of SplitTreeNodeMode.SplitH:
    FrameSplitOrientation.Horizontal
  of SplitTreeNodeMode.SplitV:
    FrameSplitOrientation.Vertical
  of SplitTreeNodeMode.Stacking, SplitTreeNodeMode.Tabbed:
    FrameSplitOrientation.Horizontal

proc addSplitNode(
    model: var Model,
    tagId: TagId,
    kind = FrameNodeKind.Leaf,
    parent = NullSplitNodeId,
    winId = NullWindowId,
): SplitNodeId =
  if model.tags.entity(tagId).isNone:
    return NullSplitNodeId
  result = model.counters.generateSplitNodeId()
  model.splitNodes.insert(
    SplitNodeData(
      id: result,
      tagId: tagId,
      kind: kind,
      parent: parent,
      mode: SplitTreeNodeMode.SplitH,
      lastSplitMode: SplitTreeNodeMode.SplitH,
      weight: 1.0'f32,
      window: winId,
    )
  )

proc splitTreeWindowVisible(model: Model, tagId: TagId, winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.admissionState == WindowAdmissionState.Admitted and not win.isFloating and
    not win.isMinimized and not win.isUnmanagedGlobal and
    model.placementByTagWindow.hasKey((tagId, winId))

proc firstSplitLeaf(model: Model, nodeId: SplitNodeId): SplitNodeId =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    return NullSplitNodeId
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    return nodeId
  for child in node.children:
    result = model.firstSplitLeaf(child)
    if result != NullSplitNodeId:
      return

proc firstEmptySplitLeaf(model: Model, nodeId: SplitNodeId): SplitNodeId =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    return NullSplitNodeId
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    if node.window == NullWindowId:
      return nodeId
    return NullSplitNodeId
  for child in node.children:
    result = model.firstEmptySplitLeaf(child)
    if result != NullSplitNodeId:
      return

proc focusedSplitLeafOrRoot*(model: Model, tagId: TagId): SplitNodeId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return NullSplitNodeId
  let focused = tagOpt.get().focusedWindow
  let focusedNode =
    model.splitNodeByTagWindow.getOrDefault((tagId, focused), NullSplitNodeId)
  if focusedNode != NullSplitNodeId and model.splitTreeUsesTag(focusedNode, tagId):
    return focusedNode
  model.firstSplitLeaf(model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId))

proc focusedChildOfSplitNode(model: Model, nodeId: SplitNodeId): SplitNodeId =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return NullSplitNodeId
  let node = nodeOpt.get()
  let tagOpt = model.tags.entity(node.tagId)
  if tagOpt.isNone:
    return NullSplitNodeId
  let focused = tagOpt.get().focusedWindow
  let focusedNode =
    model.splitNodeByTagWindow.getOrDefault((node.tagId, focused), NullSplitNodeId)
  if focusedNode != NullSplitNodeId:
    var current = focusedNode
    while current != NullSplitNodeId:
      let currentOpt = model.splitNodes.entity(current)
      if currentOpt.isNone:
        break
      let parent = currentOpt.get().parent
      if parent == nodeId:
        return current
      current = parent
  if node.children.len > 0:
    node.children[0]
  else:
    NullSplitNodeId

proc splitTreeActiveWindowInSubtree*(model: Model, nodeId: SplitNodeId): WindowId =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    return NullWindowId
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    if model.splitTreeWindowVisible(node.tagId, node.window):
      return node.window
    return NullWindowId

  let tagOpt = model.tags.entity(node.tagId)
  if tagOpt.isSome:
    let focused = tagOpt.get().focusedWindow
    if focused != NullWindowId and model.splitTreeWindowVisible(node.tagId, focused):
      let focusedNode =
        model.splitNodeByTagWindow.getOrDefault((node.tagId, focused), NullSplitNodeId)
      var current = focusedNode
      while current != NullSplitNodeId:
        if current == nodeId:
          return focused
        let currentOpt = model.splitNodes.entity(current)
        if currentOpt.isNone:
          break
        current = currentOpt.get().parent

  for child in node.children:
    result = model.splitTreeActiveWindowInSubtree(child)
    if result != NullWindowId:
      return

proc splitTreeTabContainerForFocus(model: Model, tagId: TagId): SplitNodeId =
  var current = model.focusedSplitLeafOrRoot(tagId)
  while current != NullSplitNodeId:
    let nodeOpt = model.splitNodes.entity(current)
    if nodeOpt.isNone:
      return NullSplitNodeId
    let node = nodeOpt.get()
    if node.kind == FrameNodeKind.Split and
        node.mode in {SplitTreeNodeMode.Stacking, SplitTreeNodeMode.Tabbed}:
      return current
    current = node.parent
  NullSplitNodeId

proc splitTreeChildForWindow(
    model: Model, containerId: SplitNodeId, winId: WindowId
): SplitNodeId =
  let nodeOpt = model.splitNodes.entity(containerId)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return NullSplitNodeId
  let tagId = nodeOpt.get().tagId
  let focusedNode =
    model.splitNodeByTagWindow.getOrDefault((tagId, winId), NullSplitNodeId)
  var current = focusedNode
  while current != NullSplitNodeId:
    let currentOpt = model.splitNodes.entity(current)
    if currentOpt.isNone:
      return NullSplitNodeId
    if currentOpt.get().parent == containerId:
      return current
    current = currentOpt.get().parent
  NullSplitNodeId

proc focusSplitTreeTab*(model: var Model, delta: int): bool =
  let tagId = model.activeTag
  if tagId == NullTagId or delta == 0:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let container = model.splitTreeTabContainerForFocus(tagId)
  if container == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(container)
  if nodeOpt.isNone:
    return false

  let node = nodeOpt.get()
  var children: seq[SplitNodeId] = @[]
  for child in node.children:
    if model.splitTreeActiveWindowInSubtree(child) != NullWindowId:
      children.add(child)
  if children.len <= 1:
    return false

  let focused = tagOpt.get().focusedWindow
  var currentChild = model.splitTreeChildForWindow(container, focused)
  if currentChild == NullSplitNodeId or children.find(currentChild) == -1:
    currentChild = children[0]
  var idx = children.find(currentChild)
  if idx == -1:
    idx = 0
  idx = (idx + delta + children.len) mod children.len

  let next = model.splitTreeActiveWindowInSubtree(children[idx])
  if next == NullWindowId or next == focused:
    return false
  model.setTagFocus(tagId, next)

proc focusSplitTreeTabAt*(
    model: var Model, containerId: SplitNodeId, tabIndex: int
): bool =
  if containerId == NullSplitNodeId or tabIndex < 0:
    return false
  let nodeOpt = model.splitNodes.entity(containerId)
  if nodeOpt.isNone:
    return false
  let node = nodeOpt.get()
  if node.kind != FrameNodeKind.Split or
      node.mode notin {SplitTreeNodeMode.Stacking, SplitTreeNodeMode.Tabbed}:
    return false
  let tagId = node.tagId
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false

  var windows: seq[WindowId] = @[]
  for child in node.children:
    let winId = model.splitTreeActiveWindowInSubtree(child)
    if winId != NullWindowId:
      windows.add(winId)
  if tabIndex >= windows.len:
    return false

  let next = windows[tabIndex]
  let workspaceChanged = model.setActiveWorkspace(tagId)
  let focused = model.tags.entity(tagId).get().focusedWindow
  let containerFocus = model.tags.entity(tagId).get().focusedSplitNode
  if next == NullWindowId or (next == focused and containerFocus == NullSplitNodeId):
    return workspaceChanged
  discard model.setTagFocus(tagId, next)
  true

proc focusSplitTreeTabWindow*(
    model: var Model, containerId: SplitNodeId, winId: WindowId
): bool =
  if containerId == NullSplitNodeId or winId == NullWindowId:
    return false
  let nodeOpt = model.splitNodes.entity(containerId)
  if nodeOpt.isNone:
    return false
  let node = nodeOpt.get()
  if node.kind != FrameNodeKind.Split or
      node.mode notin {SplitTreeNodeMode.Stacking, SplitTreeNodeMode.Tabbed}:
    return false
  let tagId = node.tagId
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let child = model.splitTreeChildForWindow(containerId, winId)
  if child == NullSplitNodeId or model.splitTreeActiveWindowInSubtree(child) != winId:
    return false

  let workspaceChanged = model.setActiveWorkspace(tagId)
  let focusChanged = tagOpt.get().focusedWindow != winId
  discard model.setTagFocus(tagId, winId)
  workspaceChanged or focusChanged

proc focusSplitTreeSibling*(model: var Model, delta: int): bool =
  let tagId = model.activeTag
  if tagId == NullTagId or delta == 0:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let leaf = model.focusedSplitLeafOrRoot(tagId)
  if leaf == NullSplitNodeId:
    return false
  let leafOpt = model.splitNodes.entity(leaf)
  if leafOpt.isNone:
    return false
  let parentId = leafOpt.get().parent
  if parentId == NullSplitNodeId:
    return false
  let parentOpt = model.splitNodes.entity(parentId)
  if parentOpt.isNone:
    return false
  let children = parentOpt.get().children
  if children.len <= 1:
    return false
  var idx = children.find(leaf)
  if idx == -1:
    idx = 0
  idx = (idx + delta + children.len) mod children.len
  let next = model.splitTreeActiveWindowInSubtree(children[idx])
  if next == NullWindowId or next == tagOpt.get().focusedWindow:
    return false
  model.setTagFocus(tagId, next)

proc replaceSplitChild(
    model: var Model, parentId, oldChild, newChild: SplitNodeId
): bool =
  if parentId == NullSplitNodeId:
    return false
  let parentOpt = model.splitNodes.entity(parentId)
  if parentOpt.isNone:
    return false
  var children = parentOpt.get().children
  let idx = children.find(oldChild)
  if idx == -1:
    return false
  children[idx] = newChild
  model.splitNodes.mEntity(parentId).children = children
  model.splitNodes.mEntity(newChild).parent = parentId
  true

proc removeSplitChild(model: var Model, parentId, childId: SplitNodeId): bool =
  if parentId == NullSplitNodeId:
    return false
  let parentOpt = model.splitNodes.entity(parentId)
  if parentOpt.isNone:
    return false
  var children = parentOpt.get().children
  let idx = children.find(childId)
  if idx == -1:
    return false
  children.delete(idx)
  model.splitNodes.mEntity(parentId).children = children
  true

proc insertSplitChildAfter(
    model: var Model, parentId, anchorId, childId: SplitNodeId
): bool =
  let parentOpt = model.splitNodes.entity(parentId)
  if parentOpt.isNone or parentOpt.get().kind != FrameNodeKind.Split:
    return false
  var children = parentOpt.get().children
  var idx = children.find(anchorId)
  if idx == -1:
    idx = children.len - 1
  children.insert(childId, idx + 1)
  let weight =
    if children.len > 0:
      1.0'f32 / float32(children.len)
    else:
      1.0'f32
  model.splitNodes.mEntity(parentId).children = children
  for child in children:
    model.splitNodes.mEntity(child).parent = parentId
    model.splitNodes.mEntity(child).weight = weight
  true

proc insertSplitChildBefore(
    model: var Model, parentId, anchorId, childId: SplitNodeId
): bool =
  let parentOpt = model.splitNodes.entity(parentId)
  if parentOpt.isNone or parentOpt.get().kind != FrameNodeKind.Split:
    return false
  var children = parentOpt.get().children
  var idx = children.find(anchorId)
  if idx == -1:
    idx = 0
  children.insert(childId, idx)
  let weight =
    if children.len > 0:
      1.0'f32 / float32(children.len)
    else:
      1.0'f32
  model.splitNodes.mEntity(parentId).children = children
  for child in children:
    model.splitNodes.mEntity(child).parent = parentId
    model.splitNodes.mEntity(child).weight = weight
  true

proc flattenSplitTreeFrom(model: var Model, tagId: TagId, startId: SplitNodeId): bool =
  var current = startId
  while current != NullSplitNodeId:
    let currentOpt = model.splitNodes.entity(current)
    if currentOpt.isNone:
      return result
    let node = currentOpt.get()
    if node.kind != FrameNodeKind.Split:
      return result
    if node.children.len > 1:
      let weight = 1.0'f32 / float32(node.children.len)
      for child in node.children:
        model.splitNodes.mEntity(child).weight = weight
      return result

    let parentId = node.parent
    if node.children.len == 0:
      if parentId == NullSplitNodeId:
        model.splitRootsByTag.del(tagId)
      else:
        discard model.removeSplitChild(parentId, current)
      discard model.splitNodes.delete(current)
      result = true
      current = parentId
      continue

    let childId = node.children[0]
    model.splitNodes.mEntity(childId).parent = parentId
    model.splitNodes.mEntity(childId).weight = node.weight
    if parentId == NullSplitNodeId:
      model.splitRootsByTag[tagId] = childId
    else:
      discard model.replaceSplitChild(parentId, current, childId)
    discard model.splitNodes.delete(current)
    result = true
    current = parentId

proc wrapSplitLeaf(
    model: var Model,
    tagId: TagId,
    leafId: SplitNodeId,
    orientation: FrameSplitOrientation,
): SplitNodeId =
  let leafOpt = model.splitNodes.entity(leafId)
  if leafOpt.isNone:
    return NullSplitNodeId
  let oldParent = leafOpt.get().parent
  let wrapper =
    model.addSplitNode(tagId, kind = FrameNodeKind.Split, parent = oldParent)
  if wrapper == NullSplitNodeId:
    return NullSplitNodeId
  model.splitNodes.mEntity(wrapper).mode = orientation.modeForOrientation()
  model.splitNodes.mEntity(wrapper).lastSplitMode = orientation.modeForOrientation()
  model.splitNodes.mEntity(wrapper).children = @[leafId]
  model.splitNodes.mEntity(wrapper).weight = leafOpt.get().weight
  model.splitNodes.mEntity(leafId).parent = wrapper
  model.splitNodes.mEntity(leafId).weight = 1.0'f32
  if oldParent == NullSplitNodeId:
    model.splitRootsByTag[tagId] = wrapper
  else:
    discard model.replaceSplitChild(oldParent, leafId, wrapper)
  wrapper

proc focusedSplitContainerOrRoot(model: var Model, tagId: TagId): SplitNodeId =
  let root = model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId)
  if root == NullSplitNodeId:
    let container = model.addSplitNode(tagId, kind = FrameNodeKind.Split)
    if container != NullSplitNodeId:
      model.splitRootsByTag[tagId] = container
    return container

  var target = model.focusedSplitLeafOrRoot(tagId)
  if target == NullSplitNodeId:
    target = root
  let targetOpt = model.splitNodes.entity(target)
  if targetOpt.isNone:
    return NullSplitNodeId
  if targetOpt.get().kind == FrameNodeKind.Split:
    return target

  let parent = targetOpt.get().parent
  if parent != NullSplitNodeId:
    return parent

  model.wrapSplitLeaf(tagId, target, FrameSplitOrientation.Horizontal)

proc splitFocusedSplitTree*(
    model: var Model, orientation: FrameSplitOrientation
): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false

  let root = model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId)
  if root == NullSplitNodeId:
    let container = model.addSplitNode(tagId, kind = FrameNodeKind.Split)
    if container == NullSplitNodeId:
      return false
    model.splitNodes.mEntity(container).mode = orientation.modeForOrientation()
    model.splitNodes.mEntity(container).lastSplitMode = orientation.modeForOrientation()
    model.splitRootsByTag[tagId] = container
    return true

  var target = model.focusedSplitLeafOrRoot(tagId)
  if target == NullSplitNodeId:
    target = root
  let targetOpt = model.splitNodes.entity(target)
  if targetOpt.isNone:
    return false
  if targetOpt.get().kind == FrameNodeKind.Split:
    model.splitNodes.mEntity(target).mode = orientation.modeForOrientation()
    model.splitNodes.mEntity(target).lastSplitMode = orientation.modeForOrientation()
    return true

  let parent = targetOpt.get().parent
  if parent != NullSplitNodeId:
    let parentOpt = model.splitNodes.entity(parent)
    if parentOpt.isSome and parentOpt.get().kind == FrameNodeKind.Split and
        parentOpt.get().children.len == 1:
      model.splitNodes.mEntity(parent).mode = orientation.modeForOrientation()
      model.splitNodes.mEntity(parent).lastSplitMode = orientation.modeForOrientation()
      return true

  model.wrapSplitLeaf(tagId, target, orientation) != NullSplitNodeId

proc setFocusedSplitTreeLayoutMode*(model: var Model, mode: SplitTreeNodeMode): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let container = model.focusedSplitContainerOrRoot(tagId)
  if container == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(container)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return false
  let current = nodeOpt.get().mode
  let nextLast =
    if mode.splitModeIsSplit():
      mode
    elif current.splitModeIsSplit():
      current
    else:
      nodeOpt.get().lastSplitMode.normalizedLastSplitMode()
  if current == mode and nodeOpt.get().lastSplitMode == nextLast:
    return false
  model.splitNodes.mEntity(container).mode = mode
  model.splitNodes.mEntity(container).lastSplitMode = nextLast
  true

proc toggleFocusedSplitTreeSplitLayout*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let container = model.focusedSplitContainerOrRoot(tagId)
  if container == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(container)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return false
  let current = nodeOpt.get().mode
  let next =
    case current
    of SplitTreeNodeMode.SplitH:
      SplitTreeNodeMode.SplitV
    of SplitTreeNodeMode.SplitV:
      SplitTreeNodeMode.SplitH
    of SplitTreeNodeMode.Stacking, SplitTreeNodeMode.Tabbed:
      nodeOpt.get().lastSplitMode.normalizedLastSplitMode()
  if current == next:
    return false
  model.splitNodes.mEntity(container).mode = next
  model.splitNodes.mEntity(container).lastSplitMode = next.normalizedLastSplitMode()
  true

proc cycleFocusedSplitTreeLayoutAll*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let container = model.focusedSplitContainerOrRoot(tagId)
  if container == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(container)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return false
  let next =
    case nodeOpt.get().mode
    of SplitTreeNodeMode.SplitH: SplitTreeNodeMode.SplitV
    of SplitTreeNodeMode.SplitV: SplitTreeNodeMode.Stacking
    of SplitTreeNodeMode.Stacking: SplitTreeNodeMode.Tabbed
    of SplitTreeNodeMode.Tabbed: SplitTreeNodeMode.SplitH
  model.setFocusedSplitTreeLayoutMode(next)

proc cycleFocusedSplitTreeLayoutList*(
    model: var Model, modes: seq[SplitTreeNodeMode]
): bool =
  if modes.len < 2:
    return false
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or not tagOpt.get().tagUsesSplitTree():
    return false
  let container = model.focusedSplitContainerOrRoot(tagId)
  if container == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(container)
  if nodeOpt.isNone or nodeOpt.get().kind != FrameNodeKind.Split:
    return false
  let current = nodeOpt.get().mode
  let idx = modes.find(current)
  let next = modes[(idx + 1) mod modes.len]
  model.setFocusedSplitTreeLayoutMode(next)

proc addWindowToSplitTree*(model: var Model, tagId: TagId, winId: WindowId): bool =
  if model.tags.entity(tagId).isNone or not model.splitTreeWindowVisible(tagId, winId):
    return false
  if model.splitNodeByTagWindow.getOrDefault((tagId, winId), NullSplitNodeId) !=
      NullSplitNodeId:
    return false

  let root = model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId)
  if root == NullSplitNodeId or not model.splitTreeUsesTag(root, tagId):
    let leaf = model.addSplitNode(tagId, winId = winId)
    if leaf == NullSplitNodeId:
      return false
    model.splitRootsByTag[tagId] = leaf
    model.splitNodeByTagWindow[(tagId, winId)] = leaf
    discard model.setTagFocus(tagId, winId)
    return true

  let rootNode = model.splitNodes.entity(root).get()
  if rootNode.kind == FrameNodeKind.Split and rootNode.children.len == 0:
    let leaf = model.addSplitNode(tagId, parent = root, winId = winId)
    if leaf == NullSplitNodeId:
      return false
    model.splitNodes.mEntity(root).children = @[leaf]
    model.splitNodeByTagWindow[(tagId, winId)] = leaf
    discard model.setTagFocus(tagId, winId)
    return true

  let emptyLeaf = model.firstEmptySplitLeaf(root)
  if emptyLeaf != NullSplitNodeId:
    model.splitNodes.mEntity(emptyLeaf).window = winId
    model.splitNodeByTagWindow[(tagId, winId)] = emptyLeaf
    discard model.setTagFocus(tagId, winId)
    return true

  let target = model.focusedSplitLeafOrRoot(tagId)
  if target == NullSplitNodeId:
    return false
  let parent = model.splitNodes.entity(target).get().parent
  let leaf = model.addSplitNode(tagId, winId = winId)
  if leaf == NullSplitNodeId:
    return false
  if parent == NullSplitNodeId:
    let split = model.addSplitNode(tagId, kind = FrameNodeKind.Split)
    if split == NullSplitNodeId:
      return false
    model.splitNodes.mEntity(split).children = @[target, leaf]
    model.splitNodes.mEntity(target).parent = split
    model.splitNodes.mEntity(leaf).parent = split
    model.splitNodes.mEntity(target).weight = 0.5'f32
    model.splitNodes.mEntity(leaf).weight = 0.5'f32
    model.splitRootsByTag[tagId] = split
  elif not model.insertSplitChildAfter(parent, target, leaf):
    return false
  model.splitNodeByTagWindow[(tagId, winId)] = leaf
  discard model.setTagFocus(tagId, winId)
  true

proc removeWindowFromSplitTree*(model: var Model, tagId: TagId, winId: WindowId): bool =
  let nodeId = model.splitNodeByTagWindow.getOrDefault((tagId, winId), NullSplitNodeId)
  if nodeId == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    model.splitNodeByTagWindow.del((tagId, winId))
    return true
  let parent = nodeOpt.get().parent
  model.splitNodeByTagWindow.del((tagId, winId))
  if parent == NullSplitNodeId:
    model.splitRootsByTag.del(tagId)
  else:
    discard model.removeSplitChild(parent, nodeId)
  discard model.splitNodes.delete(nodeId)
  result = true
  if parent != NullSplitNodeId:
    result = model.flattenSplitTreeFrom(tagId, parent) or result

proc replaceWindowInSplitTree*(
    model: var Model, tagId: TagId, oldWinId, newWinId: WindowId
): bool =
  let nodeId =
    model.splitNodeByTagWindow.getOrDefault((tagId, oldWinId), NullSplitNodeId)
  if nodeId == NullSplitNodeId or model.splitNodes.entity(nodeId).isNone:
    return false
  model.splitNodes.mEntity(nodeId).window = newWinId
  model.splitNodeByTagWindow.del((tagId, oldWinId))
  model.splitNodeByTagWindow[(tagId, newWinId)] = nodeId
  true

proc swapWindowsInSplitTree*(
    model: var Model,
    firstTagId: TagId,
    firstWinId: WindowId,
    secondTagId: TagId,
    secondWinId: WindowId,
): bool =
  let firstNode =
    model.splitNodeByTagWindow.getOrDefault((firstTagId, firstWinId), NullSplitNodeId)
  let secondNode =
    model.splitNodeByTagWindow.getOrDefault((secondTagId, secondWinId), NullSplitNodeId)
  if firstNode == NullSplitNodeId or secondNode == NullSplitNodeId:
    return false
  if model.splitNodes.entity(firstNode).isNone or
      model.splitNodes.entity(secondNode).isNone:
    return false
  model.splitNodes.mEntity(firstNode).window = secondWinId
  model.splitNodes.mEntity(secondNode).window = firstWinId
  model.splitNodeByTagWindow.del((firstTagId, firstWinId))
  model.splitNodeByTagWindow.del((secondTagId, secondWinId))
  model.splitNodeByTagWindow[(firstTagId, secondWinId)] = firstNode
  model.splitNodeByTagWindow[(secondTagId, firstWinId)] = secondNode
  true

proc clearSplitTreeForTag(model: var Model, tagId: TagId) =
  var nodeIds: seq[SplitNodeId] = @[]
  for nodeId, _ in model.splitNodesOnTagWithId(tagId):
    nodeIds.add(nodeId)
  for nodeId in nodeIds:
    discard model.splitNodes.delete(nodeId)
  model.splitRootsByTag.del(tagId)
  var keys: seq[(TagId, WindowId)] = @[]
  for key in model.splitNodeByTagWindow.keys:
    if key[0] == tagId:
      keys.add(key)
  for key in keys:
    model.splitNodeByTagWindow.del(key)

proc syncTagSplitTreeFromPlacement*(model: var Model, tagId: TagId): bool =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  model.clearSplitTreeForTag(tagId)
  for winId, _ in model.windowsOnTagWithId(tagId):
    if model.splitTreeWindowVisible(tagId, winId):
      result = model.addWindowToSplitTree(tagId, winId) or result

proc restoreTagSplitNodes*(
    model: var Model, tagId: TagId, restored: RestoredTagData
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  if model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId) != NullSplitNodeId:
    return false

  var root = NullSplitNodeId
  for node in restored.splitNodes:
    if node.id == NullSplitNodeId or model.splitNodes.entity(node.id).isSome:
      continue
    model.splitNodes.insert(
      SplitNodeData(
        id: node.id,
        tagId: tagId,
        kind: node.kind,
        parent: node.parent,
        children: node.children,
        mode: node.mode,
        lastSplitMode: node.lastSplitMode.normalizedLastSplitMode(),
        weight: clamp(node.weight, 0.05'f32, 1.0'f32),
        window: NullWindowId,
      )
    )
    if node.parent == NullSplitNodeId and root == NullSplitNodeId:
      root = node.id
    let rawId = uint32(node.id)
    if rawId < high(uint32) and model.counters.nextSplitNodeId <= rawId:
      model.counters.nextSplitNodeId = rawId + 1

  if root == NullSplitNodeId and restored.splitNodes.len > 0:
    root = restored.splitNodes[0].id
  if root == NullSplitNodeId or model.splitNodes.entity(root).isNone:
    return result

  model.splitRootsByTag[tagId] = root
  true

proc restoreWindowSplitTreePlacement*(
    model: var Model,
    tagId: TagId,
    restored: RestoredTagData,
    externalId: ExternalWindowId,
    winId: WindowId,
): bool =
  var nodeId = NullSplitNodeId
  for node in restored.splitNodes:
    if node.window == externalId:
      nodeId = node.id
      break
  if nodeId == NullSplitNodeId or model.splitNodes.entity(nodeId).isNone:
    return false

  let displaced = model.splitNodes.entity(nodeId).get().window
  if displaced != NullWindowId and displaced != winId:
    model.splitNodeByTagWindow.del((tagId, displaced))

  var duplicateNodes: seq[SplitNodeId] = @[]
  for node in model.splitNodes.entities:
    if node.tagId == tagId and node.kind == FrameNodeKind.Leaf and node.id != nodeId and
        node.window == winId:
      duplicateNodes.add(node.id)
  for duplicateNode in duplicateNodes:
    if model.splitNodes.entity(duplicateNode).isSome:
      model.splitNodes.mEntity(duplicateNode).window = NullWindowId

  let mappedNode =
    model.splitNodeByTagWindow.getOrDefault((tagId, winId), NullSplitNodeId)
  if mappedNode != NullSplitNodeId and mappedNode != nodeId:
    model.splitNodeByTagWindow.del((tagId, winId))

  model.splitNodes.mEntity(nodeId).window = winId
  model.splitNodeByTagWindow[(tagId, winId)] = nodeId
  true

proc splitChildRect(
    parent: SplitNodeData,
    area: Rect,
    children: openArray[SplitNodeId],
    weights: seq[float32],
    idx: int,
    gap: int32,
): Rect =
  if children.len == 0:
    return area
  let totalGap = max(0'i32, gap) * int32(max(0, children.len - 1))
  var offset = 0'i32
  for i in 0 ..< idx:
    let size =
      if parent.mode == SplitTreeNodeMode.SplitH:
        int32(float32(max(1'i32, area.w - totalGap)) * weights[i])
      else:
        int32(float32(max(1'i32, area.h - totalGap)) * weights[i])
    offset += max(1'i32, size) + max(0'i32, gap)
  let remaining =
    if parent.mode == SplitTreeNodeMode.SplitH:
      max(1'i32, area.w - totalGap)
    else:
      max(1'i32, area.h - totalGap)
  let size =
    if idx == children.high:
      max(1'i32, remaining - offset + max(0'i32, gap) * int32(idx))
    else:
      max(1'i32, int32(float32(remaining) * weights[idx]))
  if parent.mode == SplitTreeNodeMode.SplitH:
    Rect(x: area.x + offset, y: area.y, w: size, h: area.h)
  else:
    Rect(x: area.x, y: area.y + offset, w: area.w, h: size)

proc collectSplitRects(
    model: Model,
    nodeId: SplitNodeId,
    area: Rect,
    gap: int32,
    chromeHeight: int32,
    outLeaves: var seq[SplitLeafRect],
    outNodes: var seq[SplitNodeRect],
) =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    return
  let node = nodeOpt.get()
  outNodes.add((nodeId, area))
  if node.kind == FrameNodeKind.Leaf:
    outLeaves.add((nodeId, node.window, area))
    return
  if node.children.len == 0:
    return
  if not node.mode.splitModeIsSplit():
    let tabHeight = min(max(0'i32, chromeHeight), max(0'i32, area.h - 1'i32))
    let childArea = Rect(
      x: area.x, y: area.y + tabHeight, w: area.w, h: max(1'i32, area.h - tabHeight)
    )
    let child = model.focusedChildOfSplitNode(nodeId)
    if child != NullSplitNodeId:
      model.collectSplitRects(child, childArea, gap, chromeHeight, outLeaves, outNodes)
    return
  var total = 0.0'f32
  for child in node.children:
    let childOpt = model.splitNodes.entity(child)
    if childOpt.isSome:
      total += max(0.01'f32, childOpt.get().weight)
  if total <= 0.0'f32:
    total = float32(node.children.len)
  var weights: seq[float32] = @[]
  for child in node.children:
    let childOpt = model.splitNodes.entity(child)
    weights.add(
      if childOpt.isSome:
        max(0.01'f32, childOpt.get().weight) / total
      else:
        1.0'f32 / total
    )
  for idx, child in node.children:
    model.collectSplitRects(
      child,
      node.splitChildRect(area, node.children, weights, idx, gap),
      gap,
      chromeHeight,
      outLeaves,
      outNodes,
    )

proc splitTreeLeafRects*(
    model: Model,
    tagId: TagId,
    screen: Rect,
    outerGap, innerGap: int32,
    chromeHeight = 0'i32,
): seq[SplitLeafRect] =
  let root = model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId)
  if root == NullSplitNodeId:
    return
  let outer = max(0'i32, outerGap)
  let usable = Rect(
    x: screen.x + outer,
    y: screen.y + outer,
    w: max(1'i32, screen.w - outer * 2),
    h: max(1'i32, screen.h - outer * 2),
  )
  var nodes: seq[SplitNodeRect] = @[]
  model.collectSplitRects(
    root, usable, max(0'i32, innerGap), chromeHeight, result, nodes
  )

proc splitTreeNodeRects*(
    model: Model,
    tagId: TagId,
    screen: Rect,
    outerGap, innerGap: int32,
    chromeHeight = 0'i32,
): seq[SplitNodeRect] =
  let root = model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId)
  if root == NullSplitNodeId:
    return
  let outer = max(0'i32, outerGap)
  let usable = Rect(
    x: screen.x + outer,
    y: screen.y + outer,
    w: max(1'i32, screen.w - outer * 2),
    h: max(1'i32, screen.h - outer * 2),
  )
  var leaves: seq[SplitLeafRect] = @[]
  model.collectSplitRects(
    root, usable, max(0'i32, innerGap), chromeHeight, leaves, result
  )

proc collectSplitLeafWindows(
    model: Model, nodeId: SplitNodeId, outWindows: var seq[WindowId]
) =
  let nodeOpt = model.splitNodes.entity(nodeId)
  if nodeOpt.isNone:
    return
  let node = nodeOpt.get()
  if node.kind == FrameNodeKind.Leaf:
    if node.window != NullWindowId:
      outWindows.add(node.window)
    return
  for child in node.children:
    model.collectSplitLeafWindows(child, outWindows)

proc splitLeafWindowsInOrder*(model: Model, tagId: TagId): seq[WindowId] =
  model.collectSplitLeafWindows(
    model.splitRootsByTag.getOrDefault(tagId, NullSplitNodeId), result
  )

proc adjustFocusedSplitTreeSplit*(
    model: var Model, tagId: TagId, orientation: FrameSplitOrientation, delta: float32
): bool =
  let leaf = model.focusedSplitLeafOrRoot(tagId)
  if leaf == NullSplitNodeId:
    return false
  var current = leaf
  while current != NullSplitNodeId:
    let currentOpt = model.splitNodes.entity(current)
    if currentOpt.isNone:
      return false
    let parentId = currentOpt.get().parent
    if parentId == NullSplitNodeId:
      return false
    let parentOpt = model.splitNodes.entity(parentId)
    if parentOpt.isNone:
      return false
    let parent = parentOpt.get()
    if parent.kind == FrameNodeKind.Split and parent.mode.splitModeIsSplit() and
        parent.mode.orientationForMode() == orientation and parent.children.len >= 2:
      let idx = parent.children.find(current)
      if idx == -1:
        return false
      let siblingIdx =
        if idx < parent.children.high:
          idx + 1
        else:
          idx - 1
      if siblingIdx < 0 or siblingIdx >= parent.children.len:
        return false
      let sibling = parent.children[siblingIdx]
      let currentWeight = model.splitNodes.entity(current).get().weight
      let siblingWeight = model.splitNodes.entity(sibling).get().weight
      let nextCurrent = clamp(currentWeight + delta, 0.05'f32, 0.95'f32)
      let diff = nextCurrent - currentWeight
      let nextSibling = clamp(siblingWeight - diff, 0.05'f32, 0.95'f32)
      model.splitNodes.mEntity(current).weight = nextCurrent
      model.splitNodes.mEntity(sibling).weight = nextSibling
      return true
    current = parentId
  false

proc moveWindowInSplitTree*(
    model: var Model, tagId: TagId, winId: WindowId, direction: Direction
): bool =
  let leafId = model.splitNodeByTagWindow.getOrDefault((tagId, winId), NullSplitNodeId)
  if leafId == NullSplitNodeId:
    return false
  let positive = direction.directionIsPositive()
  var current = leafId
  while current != NullSplitNodeId:
    let currentOpt = model.splitNodes.entity(current)
    if currentOpt.isNone:
      return false
    let parentId = currentOpt.get().parent
    if parentId == NullSplitNodeId:
      break
    let parentOpt = model.splitNodes.entity(parentId)
    if parentOpt.isNone:
      return false
    let parent = parentOpt.get()
    if direction.directionMatchesSplitMode(parent.mode):
      let idx = parent.children.find(current)
      if idx == -1:
        return false
      let siblingIdx =
        if positive:
          idx + 1
        else:
          idx - 1
      if siblingIdx >= 0 and siblingIdx < parent.children.len:
        let siblingId = parent.children[siblingIdx]
        if current == leafId:
          # Leaf is a direct child of the matching parent — reorder within parent.
          discard model.removeSplitChild(parentId, leafId)
          if positive:
            discard model.insertSplitChildAfter(parentId, siblingId, leafId)
          else:
            discard model.insertSplitChildBefore(parentId, siblingId, leafId)
        else:
          # Leaf is nested inside current sub-container. Detach leaf, flatten the
          # old parent chain, then insert adjacent to the sibling in the ancestor.
          let oldLeafParentId = model.splitNodes.entity(leafId).get().parent
          discard model.removeSplitChild(oldLeafParentId, leafId)
          discard model.flattenSplitTreeFrom(tagId, oldLeafParentId)
          let siblingNodeOpt = model.splitNodes.entity(siblingId)
          let newParentId =
            if siblingNodeOpt.isSome:
              siblingNodeOpt.get().parent
            else:
              NullSplitNodeId
          if newParentId == NullSplitNodeId:
            # Sibling became the new root after flatten; wrap it and insert.
            let orientation =
              if direction in {Direction.DirLeft, Direction.DirRight}:
                FrameSplitOrientation.Horizontal
              else:
                FrameSplitOrientation.Vertical
            let wrapper = model.wrapSplitLeaf(tagId, siblingId, orientation)
            if wrapper == NullSplitNodeId:
              return false
            if positive:
              discard model.insertSplitChildAfter(wrapper, siblingId, leafId)
            else:
              discard model.insertSplitChildBefore(wrapper, siblingId, leafId)
            model.splitNodes.mEntity(leafId).parent = wrapper
          else:
            if positive:
              discard model.insertSplitChildAfter(newParentId, siblingId, leafId)
            else:
              discard model.insertSplitChildBefore(newParentId, siblingId, leafId)
        return true
    current = parentId
  false

proc lastFocusedWindowInSubtree(
    model: Model, tagId: TagId, nodeId: SplitNodeId
): WindowId =
  for histWinId in model.focusHistoryIdsReverse():
    if not model.splitTreeWindowVisible(tagId, histWinId):
      continue
    var check =
      model.splitNodeByTagWindow.getOrDefault((tagId, histWinId), NullSplitNodeId)
    while check != NullSplitNodeId:
      if check == nodeId:
        return histWinId
      let checkOpt = model.splitNodes.entity(check)
      if checkOpt.isNone:
        break
      check = checkOpt.get().parent
  model.splitTreeActiveWindowInSubtree(nodeId)

proc focusSplitTreeParent*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let current = tagOpt.get().focusedSplitNode
  let startNode =
    if current != NullSplitNodeId:
      current
    else:
      model.focusedSplitLeafOrRoot(tagId)
  if startNode == NullSplitNodeId:
    return false
  let nodeOpt = model.splitNodes.entity(startNode)
  if nodeOpt.isNone:
    return false
  let parentId = nodeOpt.get().parent
  if parentId == NullSplitNodeId:
    return false
  model.tags.mEntity(tagId).focusedSplitNode = parentId
  true

proc focusSplitTreeChild*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let current = tagOpt.get().focusedSplitNode
  if current == NullSplitNodeId:
    return false
  let child = model.focusedChildOfSplitNode(current)
  if child == NullSplitNodeId:
    return false
  let childOpt = model.splitNodes.entity(child)
  if childOpt.isNone:
    return false
  if childOpt.get().kind == FrameNodeKind.Leaf:
    let winId = childOpt.get().window
    if winId != NullWindowId:
      model.tags.mEntity(tagId).focusedSplitNode = NullSplitNodeId
      return model.setTagFocus(tagId, winId)
    return false
  model.tags.mEntity(tagId).focusedSplitNode = child
  true

proc splitTreeStructuralNeighbor*(model: Model, direction: Direction): WindowId =
  let tagId = model.activeTag
  if tagId == NullTagId or model.tags.entity(tagId).isNone:
    return NullWindowId
  let positive = direction.directionIsPositive()
  let containerFocus = model.tags.entity(tagId).get().focusedSplitNode
  var current =
    if containerFocus != NullSplitNodeId and
        model.splitNodes.entity(containerFocus).isSome:
      containerFocus
    else:
      model.focusedSplitLeafOrRoot(tagId)
  if current == NullSplitNodeId:
    return NullWindowId
  while current != NullSplitNodeId:
    let currentOpt = model.splitNodes.entity(current)
    if currentOpt.isNone:
      return NullWindowId
    let parentId = currentOpt.get().parent
    if parentId == NullSplitNodeId:
      return NullWindowId
    let parentOpt = model.splitNodes.entity(parentId)
    if parentOpt.isNone:
      return NullWindowId
    let parent = parentOpt.get()
    if direction.directionMatchesSplitMode(parent.mode):
      let idx = parent.children.find(current)
      if idx == -1:
        return NullWindowId
      let siblingIdx =
        if positive:
          idx + 1
        else:
          idx - 1
      if siblingIdx >= 0 and siblingIdx < parent.children.len:
        return model.lastFocusedWindowInSubtree(tagId, parent.children[siblingIdx])
    current = parentId
  NullWindowId
