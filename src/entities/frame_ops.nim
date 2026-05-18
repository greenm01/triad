import std/[options, tables]
import ../state/[entity_manager, id_gen]
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
  if focused != NullFrameId and model.frameUsesTag(focused, tagId) and
      model.frames.entity(focused).get().kind == FrameNodeKind.Leaf:
    return focused
  result = model.ensureFrameRoot(tagId)
  discard model.setFocusedFrame(tagId, result)

proc addWindowToFrame*(
    model: var Model, tagId: TagId, winId: WindowId, frameId = NullFrameId
): bool =
  if model.tags.entity(tagId).isNone or model.windows.entity(winId).isNone:
    return false
  let target =
    if frameId != NullFrameId:
      frameId
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

proc syncTagFramesFromPlacement*(model: var Model, tagId: TagId): bool =
  let root = model.ensureFrameRoot(tagId)
  if root == NullFrameId:
    return false
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    if model.frameWindowVisible(tagId, winId) and
        model.frameByTagWindow.getOrDefault((tagId, winId), NullFrameId) == NullFrameId:
      result = model.addWindowToFrame(tagId, winId, root) or result

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
  let first = model.addFrame(tagId, parent = target)
  let second = model.addFrame(tagId, parent = target)
  if first == NullFrameId or second == NullFrameId:
    return false
  let oldWindows = model.windowsByFrame.getOrDefault(target, @[])
  model.windowsByFrame.del(target)
  model.windowsByFrame[first] = oldWindows
  for winId in oldWindows:
    model.frameByTagWindow[(tagId, winId)] = first
  model.frames.mEntity(first).activeWindow =
    model.frames.entity(target).get().activeWindow
  model.frames.mEntity(target).kind = FrameNodeKind.Split
  model.frames.mEntity(target).orientation = orientation
  model.frames.mEntity(target).ratio = 0.5'f32
  model.frames.mEntity(target).firstChild = first
  model.frames.mEntity(target).secondChild = second
  model.frames.mEntity(target).activeWindow = NullWindowId
  discard model.setFocusedFrame(tagId, second)
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
