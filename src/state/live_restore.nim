import std/[algorithm, json, options, os, tables]
import iterators, queries
import ../core/layout_selection_codec
import ../core/[defaults, restore_state]
import ../types/core as core_types
import ../types/live_restore as lr
import ../types/model
from ../types/runtime_values import LayoutMode

proc runtimeWindowId(win: model.WindowData): uint32 =
  uint32(win.externalId)

proc externalWindowId(model: Model, winId: core_types.WindowId): uint32 =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return 0'u32
  winOpt.get().runtimeWindowId()

proc focusedOnActiveTag(model: Model): uint32 =
  if model.activeTag == NullTagId:
    return 0'u32
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return 0'u32
  let winId = tagOpt.get().focusedWindow
  if winId == NullWindowId:
    return 0'u32
  if model.placementForWindowOnTag(model.activeTag, winId).isNone:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isNone or winOpt.get().isMinimized or not winOpt.get().windowAdmitted():
    return 0'u32
  winOpt.get().runtimeWindowId()

proc restoredWindowData*(source: lr.RestoredWindowState): RestoredWindowData =
  RestoredWindowData(
    slot: source.tagId,
    parentExternalId: ExternalWindowId(uint32(source.parentId)),
    swallowedByExternalId: ExternalWindowId(uint32(source.swallowedBy)),
    swallowingExternalId: ExternalWindowId(uint32(source.swallowing)),
    pid: source.pid,
    appId: source.appId,
    title: source.title,
    identifier: source.identifier,
    widthProportion: source.widthProportion,
    heightProportion: source.heightProportion,
    isFloating: source.isFloating,
    isFullscreen: source.isFullscreen,
    isMaximized: source.isMaximized,
    isMinimized: source.isMinimized,
    isSticky: source.isSticky,
    isUnmanagedGlobal: source.isUnmanagedGlobal,
    fullscreenOutput: ExternalOutputId(source.fullscreenOutput),
    floatingGeom: source.floatingGeom,
    manualFloatingPosition: source.manualFloatingPosition,
    isTerminal: source.isTerminal,
    allowSwallow: source.allowSwallow,
    actualW: source.actualW,
    actualH: source.actualH,
  )

proc restoredTagData*(source: lr.RestoredTagState): RestoredTagData =
  result = RestoredTagData(
    slot: source.tagId,
    name: source.name,
    layoutMode: source.layoutMode,
    customLayoutId: source.customLayoutId,
    focusedWindow: ExternalWindowId(uint32(source.focusedWindow)),
    targetViewportXOffset: source.targetViewportXOffset,
    currentViewportXOffset: source.currentViewportXOffset,
    targetViewportYOffset: source.targetViewportYOffset,
    currentViewportYOffset: source.currentViewportYOffset,
    masterCount: source.masterCount,
    masterSplitRatio: source.masterSplitRatio,
  )
  for col in source.columns:
    var restoredCol = RestoredColumnData(
      widthProportion: col.widthProportion,
      scrollerSingleProportion: col.scrollerSingleProportion,
      isFullWidth: col.isFullWidth,
    )
    for winId in col.windows:
      restoredCol.windows.add(ExternalWindowId(uint32(winId)))
    result.columns.add(restoredCol)

proc pendingRestoreState*(source: LiveRestoreState): PendingRestoreState =
  result.activeSlot = source.activeTag
  result.focusedWindow = ExternalWindowId(uint32(source.focusedWindow))
  for winId, slot in source.tagByWindow.pairs:
    result.tagByWindow[ExternalWindowId(uint32(winId))] = slot
  for winId, win in source.windows.pairs:
    result.windows[ExternalWindowId(uint32(winId))] = win.restoredWindowData()
  for slot, tag in source.tags.pairs:
    result.tags[slot] = tag.restoredTagData()
  for outputId, slot in source.outputTags.pairs:
    result.outputTags[ExternalOutputId(outputId)] = slot
  for winId in source.scratchpadWindows:
    result.scratchpadWindows.add(ExternalWindowId(uint32(winId)))
  for name, winId in source.namedScratchpads.pairs:
    result.namedScratchpads[name] = ExternalWindowId(uint32(winId))
  for winId, slots in source.scratchpadRestoreSlots.pairs:
    result.scratchpadRestoreSlots[ExternalWindowId(uint32(winId))] = slots
  result.visibleScratchpad = ExternalWindowId(uint32(source.visibleScratchpad))
  result.isScratchpadVisible = source.isScratchpadVisible
  for winId in source.focusHistory:
    result.focusHistory.add(ExternalWindowId(uint32(winId)))
  for slot in source.workspaceHistory:
    result.workspaceHistory.add(slot)
  for winId, hostId in source.swallowedBy.pairs:
    result.swallowedBy[ExternalWindowId(uint32(winId))] =
      ExternalWindowId(uint32(hostId))
  for winId, childId in source.swallowing.pairs:
    result.swallowing[ExternalWindowId(uint32(winId))] =
      ExternalWindowId(uint32(childId))

proc hasOutputTag(model: Model, tagId: TagId): bool =
  for _, outputTagId in model.outputTags.pairs:
    if outputTagId == tagId:
      return true
  false

proc restoreDefaultMasterCount(model: Model): int =
  if model.defaultMasterCount > 0:
    max(1, model.defaultMasterCount)
  else:
    DefaultMasterCount

proc restoreDefaultMasterRatio(model: Model): float32 =
  if model.defaultMasterRatio > 0:
    clamp(model.defaultMasterRatio, 0.05'f32, 0.95'f32)
  else:
    DefaultMasterRatio

proc hasDurableTagState*(model: Model, tag: TagData): bool =
  if tag.name.len > 0 or tag.layoutMode != LayoutMode.Scroller or
      tag.customLayoutId.layoutIdString().len > 0:
    return true
  if tag.focusedWindow != NullWindowId and model.tagHasNonStickyLiveWindows(tag.id):
    return true
  if tag.targetViewportXOffset != 0 or tag.currentViewportXOffset != 0 or
      tag.targetViewportYOffset != 0 or tag.currentViewportYOffset != 0:
    return true
  tag.masterCount != model.restoreDefaultMasterCount() or
    tag.masterSplitRatio != model.restoreDefaultMasterRatio()

proc shouldPersistTag*(model: Model, tag: TagData): bool =
  if tag.slot <= model.defaultWorkspaceCount:
    return true
  if tag.id == model.activeTag or model.tagHasNonStickyLiveWindows(tag.id) or
      model.hasOutputTag(tag.id):
    return true
  model.hasDurableTagState(tag)

proc liveRestoreState*(model: Model): LiveRestoreState =
  result.activeTag = model.activeSlot
  result.focusedWindow = model.focusedOnActiveTag()

  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    let tagOpt = model.tagData(tagId)
    if tagOpt.isNone:
      continue
    let tag = tagOpt.get()
    if not model.shouldPersistTag(tag):
      continue
    var restoredTag = lr.RestoredTagState(
      tagId: tag.slot,
      name: tag.name,
      layoutMode: tag.layoutMode,
      customLayoutId: tag.customLayoutId,
      focusedWindow: model.externalWindowId(tag.focusedWindow),
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset,
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio,
    )

    for colId in model.columnsForTag(tagId):
      let colOpt = model.columnData(colId)
      if colOpt.isNone:
        continue
      var restoredCol = lr.RestoredColumnState(
        widthProportion: colOpt.get().widthProportion,
        scrollerSingleProportion: colOpt.get().scrollerSingleProportion,
        isFullWidth: colOpt.get().isFullWidth,
      )
      for winId in model.windowsForColumn(colId):
        let winOpt = model.windowData(winId)
        if winOpt.isNone or not winOpt.get().windowAdmitted() or winOpt.get().isFloating or
            winOpt.get().isSticky or winOpt.get().isUnmanagedGlobal:
          continue
        let external = model.externalWindowId(winId)
        if external == 0:
          continue
        restoredCol.windows.add(external)
        result.tagByWindow[external] = tag.slot
      if restoredCol.windows.len == 0:
        continue
      restoredTag.columns.add(restoredCol)

    result.tags[tag.slot] = restoredTag

  for winId in model.sortedWindowIdsByExternal():
    let winOpt = model.windowData(winId)
    if winOpt.isNone:
      continue
    let win = winOpt.get()
    if not win.windowAdmitted():
      continue
    let external = win.runtimeWindowId()
    if external == 0:
      continue
    var slot = result.tagByWindow.getOrDefault(external, 0'u32)
    if slot == 0:
      let position = model.firstWindowPosition(winId)
      if position.found:
        slot = position.slot

    result.windows[external] = lr.RestoredWindowState(
      tagId: slot,
      parentId: uint32(win.parentExternalId),
      swallowedBy: model.externalWindowId(model.swallowedByWindow(winId)),
      swallowing: model.externalWindowId(model.swallowingWindow(winId)),
      pid: win.pid,
      appId: win.appId,
      title: win.title,
      identifier: win.identifier,
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      isSticky: win.isSticky,
      isUnmanagedGlobal: win.isUnmanagedGlobal,
      fullscreenOutput: uint32(win.fullscreenOutput),
      floatingGeom: win.floatingGeom,
      manualFloatingPosition: win.manualFloatingPosition,
      isTerminal: win.isTerminal,
      allowSwallow: win.allowSwallow,
      actualW: win.actualW,
      actualH: win.actualH,
    )

  for outputId, tagId in model.outputTags.pairs:
    let outputOpt = model.outputData(outputId)
    let tagOpt = model.tagData(tagId)
    if outputOpt.isNone or tagOpt.isNone:
      continue
    let outputExternal = uint32(outputOpt.get().externalId)
    let slot = tagOpt.get().slot
    if outputExternal != 0 and slot != 0:
      result.outputTags[outputExternal] = slot

  for winId in model.scratchpadWindowIds():
    let external = model.externalWindowId(winId)
    if external != 0:
      result.scratchpadWindows.add(external)

  for name, winId in model.namedScratchpadsWithId():
    let external = model.externalWindowId(winId)
    if external != 0:
      result.namedScratchpads[name] = external

  for winId, _ in model.scratchpadRestoreTagsWithId():
    let external = model.externalWindowId(winId)
    let slots = model.scratchpadRestoreSlots(winId)
    if external != 0 and slots.len > 0:
      result.scratchpadRestoreSlots[external] = slots

  result.visibleScratchpad = model.externalWindowId(model.visibleScratchpadWindow())
  result.isScratchpadVisible = model.scratchpadVisible()

  for winId in model.focusHistoryIds():
    let external = model.externalWindowId(winId)
    if external != 0:
      result.focusHistory.add(external)

  for tagId in model.workspaceHistoryIds():
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome and tagOpt.get().slot != 0:
      result.workspaceHistory.add(tagOpt.get().slot)

proc rectJson(rect: core_types.Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc windowStateJson(winId: uint32, win: lr.RestoredWindowState): JsonNode =
  %*{
    "id": winId,
    "tag_id": win.tagId,
    "parent_id": win.parentId,
    "swallowed_by": win.swallowedBy,
    "swallowing": win.swallowing,
    "pid": win.pid,
    "app_id": win.appId,
    "title": win.title,
    "identifier": win.identifier,
    "width_proportion": win.widthProportion,
    "height_proportion": win.heightProportion,
    "is_floating": win.isFloating,
    "is_fullscreen": win.isFullscreen,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "is_sticky": win.isSticky,
    "is_unmanaged_global": win.isUnmanagedGlobal,
    "fullscreen_output": win.fullscreenOutput,
    "floating_geom": rectJson(win.floatingGeom),
    "manual_floating_position": win.manualFloatingPosition,
    "is_terminal": win.isTerminal,
    "allow_swallow": win.allowSwallow,
    "actual_w": win.actualW,
    "actual_h": win.actualH,
  }

proc tagStateJson(tag: lr.RestoredTagState): JsonNode =
  let columns = newJArray()
  for col in tag.columns:
    let windows = newJArray()
    for winId in col.windows:
      windows.add(%winId)
    columns.add(
      %*{
        "windows": windows,
        "width_proportion": col.widthProportion,
        "scroller_single_proportion": col.scrollerSingleProportion,
        "is_full_width": col.isFullWidth,
      }
    )

  %*{
    "id": tag.tagId,
    "name": tag.name,
    "layout_mode": ord(tag.layoutMode),
    "layout_kind":
      if tag.customLayoutId.layoutIdString().len > 0: "custom" else: "builtin",
    "custom_layout": tag.customLayoutId.layoutIdString(),
    "columns": columns,
    "focused_window": tag.focusedWindow,
    "target_viewport_x_offset": tag.targetViewportXOffset,
    "current_viewport_x_offset": tag.currentViewportXOffset,
    "target_viewport_y_offset": tag.targetViewportYOffset,
    "current_viewport_y_offset": tag.currentViewportYOffset,
    "master_count": tag.masterCount,
    "master_split_ratio": tag.masterSplitRatio,
  }

proc liveRestoreStateJson(state: LiveRestoreState): string =
  let tags = newJArray()
  var tagIds: seq[uint32]
  for tagId in state.tags.keys:
    tagIds.add(tagId)
  tagIds.sort()
  for tagId in tagIds:
    tags.add(tagStateJson(state.tags[tagId]))

  let windows = newJArray()
  var winIds: seq[uint32]
  for winId in state.windows.keys:
    winIds.add(winId)
  winIds.sort()
  for winId in winIds:
    windows.add(windowStateJson(winId, state.windows[winId]))

  let outputTags = newJArray()
  var outputIds: seq[uint32]
  for outputId in state.outputTags.keys:
    outputIds.add(outputId)
  outputIds.sort()
  for outputId in outputIds:
    outputTags.add(%*{"output_id": outputId, "tag_id": state.outputTags[outputId]})

  let scratchpads = newJArray()
  for winId in state.scratchpadWindows:
    scratchpads.add(%winId)

  let namedScratchpads = newJArray()
  var names: seq[string]
  for name in state.namedScratchpads.keys:
    names.add(name)
  names.sort()
  for name in names:
    namedScratchpads.add(%*{"name": name, "window_id": state.namedScratchpads[name]})

  let scratchpadRestoreSlots = newJArray()
  var restoreWinIds: seq[uint32]
  for winId in state.scratchpadRestoreSlots.keys:
    restoreWinIds.add(winId)
  restoreWinIds.sort()
  for winId in restoreWinIds:
    let slots = newJArray()
    for slot in state.scratchpadRestoreSlots[winId]:
      slots.add(%slot)
    scratchpadRestoreSlots.add(%*{"window_id": winId, "slots": slots})

  let focusHistory = newJArray()
  for winId in state.focusHistory:
    focusHistory.add(%winId)

  let workspaceHistory = newJArray()
  for tagId in state.workspaceHistory:
    workspaceHistory.add(%tagId)

  $(
    %*{
      "schema": LiveRestoreSchema,
      "restore_status": LiveRestoreStatusPending,
      "active_tag": state.activeTag,
      "focused_window": state.focusedWindow,
      "tags": tags,
      "windows": windows,
      "output_tags": outputTags,
      "scratchpad_windows": scratchpads,
      "named_scratchpads": namedScratchpads,
      "scratchpad_restore_slots": scratchpadRestoreSlots,
      "visible_scratchpad": state.visibleScratchpad,
      "is_scratchpad_visible": state.isScratchpadVisible,
      "focus_history": focusHistory,
      "workspace_history": workspaceHistory,
    }
  )

proc liveRestoreJson*(model: Model): string =
  model.liveRestoreState().liveRestoreStateJson()

proc writeLiveRestoreState*(
    model: Model, path = defaultLiveRestorePath()
): LiveRestoreWriteResult =
  if path.len == 0:
    return LiveRestoreWriteResult(ok: false, error: "empty live restore path")

  let dir = path.splitFile().dir
  let tmp = path & ".tmp." & $getCurrentProcessId()
  try:
    if dir.len > 0:
      createDir(dir)
    writeFile(tmp, model.liveRestoreJson() & "\n")
    moveFile(tmp, path)
    LiveRestoreWriteResult(ok: true, path: path)
  except CatchableError as e:
    try:
      if fileExists(tmp):
        removeFile(tmp)
    except CatchableError:
      discard
    LiveRestoreWriteResult(ok: false, path: path, error: e.msg)
