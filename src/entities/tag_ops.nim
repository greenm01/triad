import std/[options, sets, tables]
import active_workspace_ops, history_ops
import ../core/layout_descriptor_codec
import ../core/native_layout_codec
import ../core/layout_mode_codec
import ../state/[entity_manager, id_gen, iterators]
import ../types/[core, model]
from ../types/runtime_values import
  JanetLayoutId, LayoutMode, LayoutSelection, LayoutSelectionKind, LayoutSource,
  NativeLayoutId

proc addTag*(
    model: var Model,
    slot: uint32,
    name = "",
    layoutMode = LayoutMode.Scroller,
    focusedWindow = NullWindowId,
    targetViewportXOffset = 0.0'f32,
    currentViewportXOffset = 0.0'f32,
    targetViewportYOffset = 0.0'f32,
    currentViewportYOffset = 0.0'f32,
    masterCount = 1,
    masterSplitRatio = 0.55'f32,
): TagId =
  if model.tagBySlot.hasKey(slot):
    return model.tagBySlot[slot]

  let id = model.counters.generateTagId()
  let tag = TagData(
    id: id,
    slot: slot,
    bit: tagBit(slot),
    name: name,
    layoutMode: layoutMode,
    focusedWindow: focusedWindow,
    targetViewportXOffset: targetViewportXOffset,
    currentViewportXOffset: currentViewportXOffset,
    targetViewportYOffset: targetViewportYOffset,
    currentViewportYOffset: currentViewportYOffset,
    masterCount: max(1, masterCount),
    masterSplitRatio: max(0.05'f32, min(0.95'f32, masterSplitRatio)),
  )
  model.tags.insert(tag)
  model.tagBySlot[slot] = id
  model.columnsByTag[id] = @[]
  model.windowsByTag[id] = @[]
  id

proc setTagFocus*(model: var Model, tagId: TagId, winId: WindowId): bool =
  if model.tags.entity(tagId).isNone:
    return false
  if winId != NullWindowId and model.windows.entity(winId).isNone:
    return false
  model.tags.mEntity(tagId).focusedWindow = winId
  if winId != NullWindowId:
    let winOpt = model.windows.entity(winId)
    let key = (tagId, winId)
    let frameId = model.frameByTagWindow.getOrDefault(key, NullFrameId)
    if frameId != NullFrameId and model.frames.entity(frameId).isSome:
      model.tags.mEntity(tagId).focusedFrame = frameId
      model.frames.mEntity(frameId).activeWindow = winId
    if winOpt.isSome and not winOpt.get().isFloating and
        model.placementByTagWindow.hasKey(key):
      let columnId = model.placementByTagWindow[key].columnId
      if model.columns.entity(columnId).isSome:
        model.columns.mEntity(columnId).focusedWindow = winId
  true

proc setTagLayout*(model: var Model, tagId: TagId, mode: LayoutMode): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).layoutMode = mode
  model.tags.mEntity(tagId).customLayoutId = JanetLayoutId("")
  model.tags.mEntity(tagId).nativeLayoutId = NativeLayoutId("")
  true

proc setTagCustomLayout*(
    model: var Model, tagId: TagId, id: JanetLayoutId, fallback: LayoutSelection
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).layoutMode = fallback.builtin
  model.tags.mEntity(tagId).customLayoutId = id
  model.tags.mEntity(tagId).nativeLayoutId =
    if fallback.kind == LayoutSelectionKind.Native:
      fallback.nativeId
    else:
      NativeLayoutId("")
  true

proc setTagCustomLayout*(
    model: var Model, tagId: TagId, id: JanetLayoutId, fallback: LayoutMode
): bool =
  model.setTagCustomLayout(
    tagId, id, LayoutSelection(kind: LayoutSelectionKind.Builtin, builtin: fallback)
  )

proc setTagNativeLayout*(
    model: var Model, tagId: TagId, id: NativeLayoutId, fallback: LayoutMode
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).layoutMode = fallback
  model.tags.mEntity(tagId).customLayoutId = JanetLayoutId("")
  model.tags.mEntity(tagId).nativeLayoutId = id
  true

proc setTagName*(model: var Model, tagId: TagId, name: string): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).name = name
  true

proc setTagMasterCount*(model: var Model, tagId: TagId, count: int): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).masterCount = max(1, count)
  true

proc setTagMasterRatio*(model: var Model, tagId: TagId, ratio: float32): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).masterSplitRatio = clamp(ratio, 0.05'f32, 0.95'f32)
  true

proc setTagViewportTarget*(
    model: var Model, tagId: TagId, xOffset, yOffset: float32
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).targetViewportXOffset = xOffset
  model.tags.mEntity(tagId).targetViewportYOffset = yOffset
  true

proc setTagViewportCurrent*(
    model: var Model, tagId: TagId, xOffset, yOffset: float32
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  model.tags.mEntity(tagId).currentViewportXOffset = xOffset
  model.tags.mEntity(tagId).currentViewportYOffset = yOffset
  true

proc requestTagViewportRetarget*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId or model.tags.entity(tagId).isNone:
    return false
  if model.viewportRetargetTags.contains(tagId):
    return false
  model.viewportRetargetTags.incl(tagId)
  true

proc requestTagViewportSnap*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId or model.tags.entity(tagId).isNone:
    return false
  if model.viewportSnapTags.contains(tagId):
    return false
  model.viewportSnapTags.incl(tagId)
  true

proc clearTagViewportRetarget*(model: var Model, tagId: TagId): bool =
  if not model.viewportRetargetTags.contains(tagId):
    return false
  model.viewportRetargetTags.excl(tagId)
  true

proc clearTagViewportSnap*(model: var Model, tagId: TagId): bool =
  if not model.viewportSnapTags.contains(tagId):
    return false
  model.viewportSnapTags.excl(tagId)
  true

proc setTagRestoredState*(
    model: var Model,
    tagId: TagId,
    name: string,
    layoutMode: LayoutMode,
    customLayoutId: JanetLayoutId,
    nativeLayoutId: NativeLayoutId,
    targetViewportXOffset, currentViewportXOffset, targetViewportYOffset,
      currentViewportYOffset: float32,
    masterCount: int,
    masterSplitRatio: float32,
): bool =
  if model.tags.entity(tagId).isNone:
    return false
  if name.len > 0 and model.tags.mEntity(tagId).name.len == 0:
    model.tags.mEntity(tagId).name = name
  model.tags.mEntity(tagId).layoutMode = layoutMode
  var customFallback: Option[LayoutSelection] = none(LayoutSelection)
  var restoredCustomLayoutId = customLayoutId
  if string(restoredCustomLayoutId).len == 0 and
      layoutMode.layoutSource() == LayoutSource.BundledJanet:
    restoredCustomLayoutId = JanetLayoutId(layoutMode.layoutModeId())
    model.tags.mEntity(tagId).layoutMode = LayoutMode.Scroller
  for layout in model.customLayouts:
    if string(layout.id) == string(restoredCustomLayoutId):
      customFallback = some(layout.fallback)
      break
  model.tags.mEntity(tagId).customLayoutId =
    if string(restoredCustomLayoutId).len > 0 and customFallback.isSome:
      restoredCustomLayoutId
    else:
      JanetLayoutId("")
  model.tags.mEntity(tagId).nativeLayoutId =
    if customFallback.isSome and customFallback.get().kind == LayoutSelectionKind.Native:
      customFallback.get().nativeId
    elif parseNativeLayoutId(nativeLayoutId.nativeLayoutIdString()).isSome:
      nativeLayoutId
    else:
      NativeLayoutId("")
  model.tags.mEntity(tagId).targetViewportXOffset = targetViewportXOffset
  model.tags.mEntity(tagId).currentViewportXOffset = currentViewportXOffset
  model.tags.mEntity(tagId).targetViewportYOffset = targetViewportYOffset
  model.tags.mEntity(tagId).currentViewportYOffset = currentViewportYOffset
  model.tags.mEntity(tagId).masterCount = max(1, masterCount)
  model.tags.mEntity(tagId).masterSplitRatio =
    clamp(masterSplitRatio, 0.05'f32, 0.95'f32)
  true

proc destroyTag*(model: var Model, tagId: TagId): bool =
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false

  let tag = tagOpt.get()
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    if model.windowTags.hasKey(winId):
      var mask = model.windowTags[winId]
      mask.excl(tag.bit)
      model.windowTags[winId] = mask
    model.placementByTagWindow.del((tagId, winId))

  for columnId in model.columnsByTag.getOrDefault(tagId, @[]):
    model.windowsByColumn.del(columnId)
    discard model.columns.delete(columnId)

  model.columnsByTag.del(tagId)
  model.windowsByTag.del(tagId)
  var frameIds: seq[FrameId] = @[]
  for frameId, _ in model.framesOnTagWithId(tagId):
    frameIds.add(frameId)
  for frameId in frameIds:
    model.windowsByFrame.del(frameId)
    discard model.frames.delete(frameId)
  var frameKeys: seq[(TagId, WindowId)] = @[]
  for key in model.frameByTagWindow.keys:
    if key[0] == tagId:
      frameKeys.add(key)
  for key in frameKeys:
    model.frameByTagWindow.del(key)
  model.frameRootsByTag.del(tagId)
  model.tagBySlot.del(tag.slot)
  discard model.clearTagViewportRetarget(tagId)
  model.overviewViewportSnapshot.del(tagId)

  var outputIds: seq[OutputId] = @[]
  for outputId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      outputIds.add(outputId)
  for outputId in outputIds:
    model.outputTags.del(outputId)
  model.tagOutputs.del(tagId)
  model.tagHomeOutputTargets.del(tagId)
  model.tagHomeOutputPinned.excl(tagId)

  discard model.removeWorkspaceHistoryRef(tagId)
  discard model.clearActiveWorkspaceIfTag(tagId)
  model.tags.delete(tagId)
