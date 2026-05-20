import std/[options, tables]
import tag_ops
import ../state/[entity_manager, id_gen, iterators]
import ../types/[core, model]
from ../types/runtime_values import FrameNodeKind, FrameSplitOrientation

proc frameUsesTag(model: Model, frameId: FrameId, tagId: TagId): bool =
  let frameOpt = model.frames.entity(frameId)
  frameOpt.isSome and frameOpt.get().tagId == tagId

proc addFrame(
    model: var Model, tagId: TagId, kind = FrameNodeKind.Leaf, parent = NullFrameId
): FrameId =
  if model.tags.entity(tagId).isNone:
    return NullFrameId
  result = model.counters.generateFrameId()
  model.frames.insert(
    FrameData(
      id: result,
      tagId: tagId,
      kind: kind,
      parent: parent,
      ratio: 0.5'f32,
      orientation: FrameSplitOrientation.Horizontal,
      activeWindow: NullWindowId,
    )
  )
  if kind == FrameNodeKind.Leaf:
    model.windowsByFrame[result] = @[]

proc ensureFrameRoot*(model: var Model, tagId: TagId): FrameId =
  result = model.frameRootsByTag.getOrDefault(tagId, NullFrameId)
  if result != NullFrameId and model.frameUsesTag(result, tagId):
    return
  result = model.addFrame(tagId)
  if result == NullFrameId:
    return
  model.frameRootsByTag[tagId] = result
  model.tags.mEntity(tagId).focusedFrame = result

proc frameWindowVisible(model: Model, tagId: TagId, winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.admissionState == WindowAdmissionState.Admitted and not win.isFloating and
    not win.isMinimized and not win.isUnmanagedGlobal and
    model.placementByTagWindow.hasKey((tagId, winId))

proc repairFrameActiveWindow*(model: var Model, frameId: FrameId): bool =
  let frameOpt = model.frames.entity(frameId)
  if frameOpt.isNone or frameOpt.get().kind != FrameNodeKind.Leaf:
    return false
  let tagId = frameOpt.get().tagId
  var kept: seq[WindowId] = @[]
  for winId in model.windowsByFrame.getOrDefault(frameId, @[]):
    if model.frameWindowVisible(tagId, winId):
      kept.add(winId)
    else:
      model.frameByTagWindow.del((tagId, winId))
      result = true
  if kept != model.windowsByFrame.getOrDefault(frameId, @[]):
    model.windowsByFrame[frameId] = kept
    result = true
  let active = model.frames.mEntity(frameId).activeWindow
  if active == NullWindowId or kept.find(active) == -1:
    let next =
      if kept.len > 0:
        kept[^1]
      else:
        NullWindowId
    if active != next:
      model.frames.mEntity(frameId).activeWindow = next
      result = true

proc setFocusedFrame*(model: var Model, tagId: TagId, frameId: FrameId): bool =
  if frameId == NullFrameId or not model.frameUsesTag(frameId, tagId):
    return false
  if model.frames.entity(frameId).get().kind != FrameNodeKind.Leaf:
    return false
  if model.tags.entity(tagId).isNone:
    return false
  if model.tags.mEntity(tagId).focusedFrame == frameId:
    return false
  model.tags.mEntity(tagId).focusedFrame = frameId
  true

proc focusedFrameOrRoot*(model: var Model, tagId: TagId): FrameId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return NullFrameId
  let focused = tagOpt.get().focusedFrame
  let focusedWindow = tagOpt.get().focusedWindow
  let focusedWindowFrame =
    model.frameByTagWindow.getOrDefault((tagId, focusedWindow), NullFrameId)
  if focusedWindowFrame != NullFrameId and
      (
        focused == NullFrameId or model.windowsByFrame.getOrDefault(focused, @[]).len > 0
      ) and model.frameUsesTag(focusedWindowFrame, tagId) and
      model.frames.entity(focusedWindowFrame).get().kind == FrameNodeKind.Leaf and
      focusedWindowFrame != focused:
    discard model.setFocusedFrame(tagId, focusedWindowFrame)
    return focusedWindowFrame
  if focused != NullFrameId and model.frameUsesTag(focused, tagId) and
      model.frames.entity(focused).get().kind == FrameNodeKind.Leaf:
    return focused
  if focusedWindowFrame != NullFrameId and model.frameUsesTag(focusedWindowFrame, tagId) and
      model.frames.entity(focusedWindowFrame).get().kind == FrameNodeKind.Leaf:
    discard model.setFocusedFrame(tagId, focusedWindowFrame)
    return focusedWindowFrame
  result = model.ensureFrameRoot(tagId)
  discard model.setFocusedFrame(tagId, result)

proc frameForAppBinding*(model: Model, tagId: TagId, appId: string): FrameId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone or appId.len == 0:
    return NullFrameId
  tagOpt.get().frameAppBindings.getOrDefault(appId, NullFrameId)

proc bindAppToFrame*(
    model: var Model, tagId: TagId, appId: string, frameId: FrameId
): bool =
  if model.tags.entity(tagId).isNone or appId.len == 0 or frameId == NullFrameId:
    return false
  model.tags.mEntity(tagId).frameAppBindings[appId] = frameId
  true

proc unbindAppFromFrame*(model: var Model, tagId: TagId, appId: string): bool =
  if model.tags.entity(tagId).isNone or appId.len == 0:
    return false
  let had = model.tags.entity(tagId).get().frameAppBindings.hasKey(appId)
  if had:
    model.tags.mEntity(tagId).frameAppBindings.del(appId)
  had

proc addWindowToFrame*(
    model: var Model, tagId: TagId, winId: WindowId, frameId = NullFrameId
): bool =
  if model.tags.entity(tagId).isNone or model.windows.entity(winId).isNone:
    return false
  let target =
    if frameId != NullFrameId:
      frameId
    else:
      let winOpt = model.windows.entity(winId)
      let appId =
        if winOpt.isSome:
          winOpt.get().appId
        else:
          ""
      let bound = model.frameForAppBinding(tagId, appId)
      if bound != NullFrameId and model.frameUsesTag(bound, tagId) and
          model.frames.entity(bound).isSome and
          model.frames.entity(bound).get().kind == FrameNodeKind.Leaf:
        bound
      else:
        model.focusedFrameOrRoot(tagId)
  if target == NullFrameId or not model.frameUsesTag(target, tagId):
    return false
  if model.frames.entity(target).get().kind != FrameNodeKind.Leaf:
    return false
  let old = model.frameByTagWindow.getOrDefault((tagId, winId), NullFrameId)
  if old != NullFrameId and model.windowsByFrame.hasKey(old):
    let idx = model.windowsByFrame[old].find(winId)
    if idx != -1:
      model.windowsByFrame[old].delete(idx)
      discard model.repairFrameActiveWindow(old)
  if model.windowsByFrame.mgetOrPut(target, @[]).find(winId) == -1:
    model.windowsByFrame[target].add(winId)
  model.frameByTagWindow[(tagId, winId)] = target
  model.frames.mEntity(target).activeWindow = winId
  discard model.setFocusedFrame(tagId, target)
  true

proc frameLeafValid(model: Model, tagId: TagId, frameId: FrameId): bool =
  if frameId == NullFrameId:
    return false
  let frameOpt = model.frames.entity(frameId)
  frameOpt.isSome and frameOpt.get().tagId == tagId and
    frameOpt.get().kind == FrameNodeKind.Leaf

proc firstLeafFrame(model: Model, tagId: TagId): FrameId =
  for frameId, frame in model.framesOnTagWithId(tagId):
    if frame.kind == FrameNodeKind.Leaf:
      return frameId
  NullFrameId

proc firstOccupiedLeafFrame(model: Model, tagId: TagId): FrameId =
  for frameId, frame in model.framesOnTagWithId(tagId):
    if frame.kind == FrameNodeKind.Leaf and
        model.windowsByFrame.getOrDefault(frameId, @[]).len > 0:
      return frameId
  NullFrameId

proc focusedWindowFrame(model: Model, tagId: TagId): FrameId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return NullFrameId
  model.frameByTagWindow.getOrDefault((tagId, tagOpt.get().focusedWindow), NullFrameId)

proc visibleTiledWindowsInPlacementOrder(model: Model, tagId: TagId): seq[WindowId] =
  for columnId, _ in model.columnsOnTagWithId(tagId):
    for winId, _ in model.windowsOnColumnWithId(columnId):
      if result.find(winId) == -1 and model.frameWindowVisible(tagId, winId):
        result.add(winId)

proc clearTagFrames(model: var Model, tagId: TagId): bool =
  var frameIds: seq[FrameId] = @[]
  for frameId, _ in model.framesOnTagWithId(tagId):
    frameIds.add(frameId)
  for frameId in frameIds:
    model.windowsByFrame.del(frameId)
    result = model.frames.delete(frameId) or result

  var keys: seq[(TagId, WindowId)] = @[]
  for key in model.frameByTagWindow.keys:
    if key[0] == tagId:
      keys.add(key)
  for key in keys:
    model.frameByTagWindow.del(key)
    result = true

  if model.frameRootsByTag.hasKey(tagId):
    model.frameRootsByTag.del(tagId)
    result = true

proc importTagWindowsAsTabbedFrame*(model: var Model, tagId: TagId): bool =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let windows = model.visibleTiledWindowsInPlacementOrder(tagId)
  if windows.len == 0:
    return model.clearTagFrames(tagId)

  result = model.clearTagFrames(tagId)
  let frameId = model.addFrame(tagId)
  if frameId == NullFrameId:
    return result

  model.frameRootsByTag[tagId] = frameId
  model.windowsByFrame[frameId] = @[]
  for winId in windows:
    model.windowsByFrame[frameId].add(winId)
    model.frameByTagWindow[(tagId, winId)] = frameId

  var active = tagOpt.get().focusedWindow
  if windows.find(active) == -1:
    active = windows[^1]
  model.frames.mEntity(frameId).activeWindow = active
  model.tags.mEntity(tagId).focusedFrame = frameId
  model.tags.mEntity(tagId).focusedWindow = active
  result = true

proc syncTargetFrame(
    model: var Model, tagId: TagId, preferFocusedWindow = false
): FrameId =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return NullFrameId
  let focusedWindowFrame = model.focusedWindowFrame(tagId)
  if preferFocusedWindow and model.frameLeafValid(tagId, focusedWindowFrame):
    discard model.setFocusedFrame(tagId, focusedWindowFrame)
    return focusedWindowFrame
  if preferFocusedWindow:
    result = model.firstOccupiedLeafFrame(tagId)
    if result != NullFrameId:
      discard model.setFocusedFrame(tagId, result)
      return
  let focused = tagOpt.get().focusedFrame
  if model.frameLeafValid(tagId, focused):
    return focused
  if model.frameLeafValid(tagId, focusedWindowFrame):
    discard model.setFocusedFrame(tagId, focusedWindowFrame)
    return focusedWindowFrame
  result = model.firstLeafFrame(tagId)
  if result != NullFrameId:
    discard model.setFocusedFrame(tagId, result)
    return
  result = model.ensureFrameRoot(tagId)
  if not model.frameLeafValid(tagId, result):
    result = NullFrameId

proc syncTagFramesFromPlacement*(
    model: var Model, tagId: TagId, preferFocusedWindow = false
): bool =
  if model.ensureFrameRoot(tagId) == NullFrameId:
    return false
  for frameId, frame in model.framesOnTagWithId(tagId):
    if frame.kind == FrameNodeKind.Leaf:
      result = model.repairFrameActiveWindow(frameId) or result
  let target = model.syncTargetFrame(tagId, preferFocusedWindow)
  if target == NullFrameId:
    return result
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    if model.frameWindowVisible(tagId, winId) and
        model.frameByTagWindow.getOrDefault((tagId, winId), NullFrameId) == NullFrameId:
      result = model.addWindowToFrame(tagId, winId, target) or result
  if preferFocusedWindow:
    let focusedWindowFrame = model.focusedWindowFrame(tagId)
    if model.frameLeafValid(tagId, focusedWindowFrame):
      result = model.setFocusedFrame(tagId, focusedWindowFrame) or result

proc removeWindowFromFrame*(model: var Model, tagId: TagId, winId: WindowId): bool =
  let frameId = model.frameByTagWindow.getOrDefault((tagId, winId), NullFrameId)
  if frameId == NullFrameId:
    return false
  if model.windowsByFrame.hasKey(frameId):
    let idx = model.windowsByFrame[frameId].find(winId)
    if idx != -1:
      model.windowsByFrame[frameId].delete(idx)
      result = true
  model.frameByTagWindow.del((tagId, winId))
  discard model.repairFrameActiveWindow(frameId)

proc splitFocusedFrame*(model: var Model, orientation: FrameSplitOrientation): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let target = model.focusedFrameOrRoot(tagId)
  if target == NullFrameId or model.frames.entity(target).isNone:
    return false
  if model.frames.entity(target).get().kind != FrameNodeKind.Leaf:
    return false
  discard model.repairFrameActiveWindow(target)
  let active = model.frames.entity(target).get().activeWindow
  let oldWindows = model.windowsByFrame.getOrDefault(target, @[])
  let moveActive =
    oldWindows.len > 1 and active != NullWindowId and oldWindows.find(active) != -1
  let oldParent = model.frames.entity(target).get().parent
  let split = model.addFrame(tagId, kind = FrameNodeKind.Split, parent = oldParent)
  let second = model.addFrame(tagId, parent = split)
  if split == NullFrameId or second == NullFrameId:
    return false
  if oldParent == NullFrameId:
    model.frameRootsByTag[tagId] = split
  else:
    if model.frames.mEntity(oldParent).firstChild == target:
      model.frames.mEntity(oldParent).firstChild = split
    else:
      model.frames.mEntity(oldParent).secondChild = split
  model.frames.mEntity(target).parent = split
  model.windowsByFrame[second] = @[]
  if moveActive:
    let idx = model.windowsByFrame[target].find(active)
    if idx != -1:
      model.windowsByFrame[target].delete(idx)
    model.windowsByFrame[second].add(active)
    model.frameByTagWindow[(tagId, active)] = second
    model.frames.mEntity(second).activeWindow = active
  model.frames.mEntity(split).orientation = orientation
  model.frames.mEntity(split).ratio = model.defaultFrameSplitRatio
  model.frames.mEntity(split).firstChild = target
  model.frames.mEntity(split).secondChild = second
  discard model.repairFrameActiveWindow(target)
  if moveActive:
    discard model.setFocusedFrame(tagId, second)
    model.tags.mEntity(tagId).focusedWindow = active
  else:
    discard model.setFocusedFrame(tagId, target)
  true

proc unsplitFocusedFrame*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let target = model.focusedFrameOrRoot(tagId)
  if target == NullFrameId or model.windowsByFrame.getOrDefault(target, @[]).len > 0:
    return false
  let frame = model.frames.entity(target)
  if frame.isNone or frame.get().parent == NullFrameId:
    return false
  let parentId = frame.get().parent
  let parent = model.frames.entity(parentId)
  if parent.isNone or parent.get().kind != FrameNodeKind.Split:
    return false
  let sibling =
    if parent.get().firstChild == target:
      parent.get().secondChild
    else:
      parent.get().firstChild
  let siblingData = model.frames.entity(sibling)
  if siblingData.isNone:
    return false
  let parentParent = parent.get().parent
  model.frames.mEntity(sibling).parent = parentParent
  if parentParent == NullFrameId:
    model.frameRootsByTag[tagId] = sibling
  else:
    if model.frames.mEntity(parentParent).firstChild == parentId:
      model.frames.mEntity(parentParent).firstChild = sibling
    else:
      model.frames.mEntity(parentParent).secondChild = sibling
  model.windowsByFrame.del(target)
  discard model.frames.delete(target)
  discard model.frames.delete(parentId)
  discard model.setFocusedFrame(tagId, sibling)
  true

proc adjustFocusedFrameSplit*(
    model: var Model, tagId: TagId, orientation: FrameSplitOrientation, delta: float32
): bool =
  let leaf = model.focusedFrameOrRoot(tagId)
  if leaf == NullFrameId:
    return false
  var current = leaf
  while current != NullFrameId:
    let currentOpt = model.frames.entity(current)
    if currentOpt.isNone:
      return false
    let parentId = currentOpt.get().parent
    if parentId == NullFrameId:
      return false
    let parentOpt = model.frames.entity(parentId)
    if parentOpt.isNone:
      return false
    let parent = parentOpt.get()
    if parent.kind == FrameNodeKind.Split and parent.orientation == orientation:
      let isFirst = parent.firstChild == current
      let newRatio =
        clamp(parent.ratio + (if isFirst: delta else: -delta), 0.05'f32, 0.95'f32)
      if newRatio == parent.ratio:
        return false
      model.frames.mEntity(parentId).ratio = newRatio
      return true
    current = parentId
  false

proc toggleFocusedFrameSplitOrientation*(model: var Model, tagId: TagId): bool =
  let leaf = model.focusedFrameOrRoot(tagId)
  if leaf == NullFrameId:
    return false
  let leafOpt = model.frames.entity(leaf)
  if leafOpt.isNone:
    return false
  let parentId = leafOpt.get().parent
  if parentId == NullFrameId:
    return false
  let parentOpt = model.frames.entity(parentId)
  if parentOpt.isNone or parentOpt.get().kind != FrameNodeKind.Split:
    return false
  let current = parentOpt.get().orientation
  model.frames.mEntity(parentId).orientation =
    if current == FrameSplitOrientation.Horizontal:
      FrameSplitOrientation.Vertical
    else:
      FrameSplitOrientation.Horizontal
  true

proc frameBelongsToSubtree*(model: Model, frameId, rootId: FrameId): bool =
  var current = frameId
  while current != NullFrameId:
    if current == rootId:
      return true
    let opt = model.frames.entity(current)
    if opt.isNone:
      break
    current = opt.get().parent
  false

proc firstLeafInSubtree(model: Model, frameId: FrameId): FrameId =
  let opt = model.frames.entity(frameId)
  if opt.isNone:
    return NullFrameId
  let f = opt.get()
  if f.kind == FrameNodeKind.Leaf:
    return frameId
  let first = model.firstLeafInSubtree(f.firstChild)
  if first != NullFrameId:
    return first
  model.firstLeafInSubtree(f.secondChild)

proc focusFrameParent*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let current = tagOpt.get().focusedParentFrame
  let startFrame =
    if current != NullFrameId and model.frames.entity(current).isSome:
      current
    else:
      model.focusedFrameOrRoot(tagId)
  if startFrame == NullFrameId:
    return false
  let startOpt = model.frames.entity(startFrame)
  if startOpt.isNone:
    return false
  let parentId = startOpt.get().parent
  if parentId == NullFrameId:
    return false
  model.tags.mEntity(tagId).focusedParentFrame = parentId
  true

proc focusFrameChild*(model: var Model): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  let current = tagOpt.get().focusedParentFrame
  if current == NullFrameId:
    return false
  let currentOpt = model.frames.entity(current)
  if currentOpt.isNone:
    return false
  let f = currentOpt.get()
  if f.kind == FrameNodeKind.Leaf:
    model.tags.mEntity(tagId).focusedParentFrame = NullFrameId
    let winId = f.activeWindow
    if winId != NullWindowId:
      return model.setTagFocus(tagId, winId)
    return false
  # Find the child that contains the current focused frame.
  let focusedLeaf = tagOpt.get().focusedFrame
  let child =
    if focusedLeaf != NullFrameId and
        model.frameBelongsToSubtree(focusedLeaf, f.firstChild):
      f.firstChild
    elif focusedLeaf != NullFrameId and
      model.frameBelongsToSubtree(focusedLeaf, f.secondChild):
      f.secondChild
    else:
      f.firstChild
  if child == NullFrameId:
    return false
  let childOpt = model.frames.entity(child)
  if childOpt.isNone:
    return false
  if childOpt.get().kind == FrameNodeKind.Leaf:
    model.tags.mEntity(tagId).focusedParentFrame = NullFrameId
    let winId = childOpt.get().activeWindow
    if winId != NullWindowId:
      return model.setTagFocus(tagId, winId)
    return false
  model.tags.mEntity(tagId).focusedParentFrame = child
  true

proc focusFrameTab*(model: var Model, delta: int): bool =
  let tagId = model.activeTag
  if tagId == NullTagId or delta == 0:
    return false
  let frameId = model.focusedFrameOrRoot(tagId)
  let windows = model.windowsByFrame.getOrDefault(frameId, @[])
  if windows.len <= 1:
    return false
  let active = model.frames.entity(frameId).get().activeWindow
  var idx = windows.find(active)
  if idx == -1:
    idx = 0
  else:
    idx = (idx + delta + windows.len) mod windows.len
  let next = windows[idx]
  model.frames.mEntity(frameId).activeWindow = next
  model.tags.mEntity(tagId).focusedWindow = next
  true

proc setFrameActiveWindow*(model: var Model, frameId: FrameId, winId: WindowId): bool =
  let frameOpt = model.frames.entity(frameId)
  if frameOpt.isNone or frameOpt.get().kind != FrameNodeKind.Leaf:
    return false
  if winId != NullWindowId and
      model.windowsByFrame.getOrDefault(frameId, @[]).find(winId) == -1:
    return false
  if frameOpt.get().activeWindow == winId:
    return false
  model.frames.mEntity(frameId).activeWindow = winId
  true

proc selectableFrameTabWindows(model: Model, frameId: FrameId): seq[WindowId] =
  for winId in model.windowsByFrame.getOrDefault(frameId, @[]):
    let winOpt = model.windows.entity(winId)
    if winOpt.isNone:
      continue
    let win = winOpt.get()
    if win.admissionState != WindowAdmissionState.Admitted or win.isFloating or
        win.isMinimized or win.isUnmanagedGlobal:
      continue
    let groupId = model.groupByWindow.getOrDefault(winId, NullGroupId)
    if groupId != NullGroupId:
      let groupOpt = model.groups.entity(groupId)
      if groupOpt.isSome and groupOpt.get().activeWindow != winId:
        continue
    result.add(winId)

proc focusFrameTabAt*(model: var Model, frameId: FrameId, tabIndex: int): bool =
  let tagId = model.activeTag
  if tagId == NullTagId or tabIndex < 0:
    return false
  let frameOpt = model.frames.entity(frameId)
  if frameOpt.isNone or frameOpt.get().kind != FrameNodeKind.Leaf or
      not model.frameUsesTag(frameId, tagId):
    return false
  discard model.repairFrameActiveWindow(frameId)
  let windows = model.selectableFrameTabWindows(frameId)
  if tabIndex >= windows.len:
    return false
  let next = windows[tabIndex]
  let activeChanged = model.frames.entity(frameId).get().activeWindow != next
  let focusChanged =
    model.tags.entity(tagId).isSome and
    model.tags.entity(tagId).get().focusedWindow != next
  let frameChanged = model.setFocusedFrame(tagId, frameId)
  if activeChanged:
    model.frames.mEntity(frameId).activeWindow = next
  if focusChanged:
    model.tags.mEntity(tagId).focusedWindow = next
  activeChanged or focusChanged or frameChanged

proc focusFrameOnly*(model: var Model, frameId: FrameId): bool =
  let tagId = model.activeTag
  if tagId == NullTagId:
    return false
  let frameOpt = model.frames.entity(frameId)
  if frameOpt.isNone or frameOpt.get().kind != FrameNodeKind.Leaf or
      not model.frameUsesTag(frameId, tagId):
    return false
  model.setFocusedFrame(tagId, frameId)

proc restoreTagFrames*(
    model: var Model, tagId: TagId, restored: RestoredTagData
): bool =
  if model.tags.entity(tagId).isNone or restored.frames.len == 0:
    return false
  if model.frameRootsByTag.getOrDefault(tagId, NullFrameId) != NullFrameId:
    return false

  var root = NullFrameId
  var firstLeaf = NullFrameId
  for frame in restored.frames:
    if frame.id == NullFrameId or model.frames.entity(frame.id).isSome:
      continue
    model.frames.insert(
      FrameData(
        id: frame.id,
        tagId: tagId,
        kind: frame.kind,
        parent: frame.parent,
        firstChild: frame.firstChild,
        secondChild: frame.secondChild,
        orientation: frame.orientation,
        ratio: clamp(frame.ratio, 0.05'f32, 0.95'f32),
        activeWindow: NullWindowId,
      )
    )
    if frame.kind == FrameNodeKind.Leaf:
      model.windowsByFrame[frame.id] = @[]
      if firstLeaf == NullFrameId:
        firstLeaf = frame.id
    if frame.parent == NullFrameId and root == NullFrameId:
      root = frame.id
    let rawId = uint32(frame.id)
    if rawId < high(uint32) and model.counters.nextFrameId <= rawId:
      model.counters.nextFrameId = rawId + 1

  if root == NullFrameId and restored.frames.len > 0:
    root = restored.frames[0].id
  if root == NullFrameId or model.frames.entity(root).isNone:
    return result

  model.frameRootsByTag[tagId] = root
  let restoredFocus = restored.focusedFrame
  if restoredFocus != NullFrameId and model.frames.entity(restoredFocus).isSome and
      model.frames.entity(restoredFocus).get().kind == FrameNodeKind.Leaf:
    model.tags.mEntity(tagId).focusedFrame = restoredFocus
  elif firstLeaf != NullFrameId:
    model.tags.mEntity(tagId).focusedFrame = firstLeaf
  for appId, frameId in restored.frameAppBindings:
    if frameId != NullFrameId and model.frames.entity(frameId).isSome and
        model.frameUsesTag(frameId, tagId):
      model.tags.mEntity(tagId).frameAppBindings[appId] = frameId
  result = true

proc restoreWindowFramePlacement*(
    model: var Model,
    tagId: TagId,
    restored: RestoredTagData,
    externalId: ExternalWindowId,
    winId: WindowId,
): bool =
  var frameId = NullFrameId
  var activeExternal = NullExternalWindowId
  for frame in restored.frames:
    if frame.windows.find(externalId) != -1:
      frameId = frame.id
      activeExternal = frame.activeWindow
      break
  if frameId == NullFrameId or model.frames.entity(frameId).isNone:
    return false
  result = model.addWindowToFrame(tagId, winId, frameId)
  if result and activeExternal == externalId:
    model.frames.mEntity(frameId).activeWindow = winId
