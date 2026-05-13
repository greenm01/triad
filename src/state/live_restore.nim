import std/[algorithm, json, options, os, tables]
import iterators, queries
import ../core/[defaults, restore_state]
import ../types/core as core_types
import ../types/model
import ../types/runtime_values as rv

proc runtimeWindowId(win: model.WindowData): rv.WindowId =
  rv.WindowId(uint32(win.externalId))

proc externalWindowId(model: Model, winId: core_types.WindowId): rv.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return 0'u32
  winOpt.get().runtimeWindowId()

proc focusedOnActiveTag(model: Model): rv.WindowId =
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

proc restoredWindowData*(source: rv.RestoredWindowState): RestoredWindowData =
  RestoredWindowData(
    slot: source.tagId,
    parentExternalId: ExternalWindowId(uint32(source.parentId)),
    appId: source.appId,
    title: source.title,
    identifier: source.identifier,
    widthProportion: source.widthProportion,
    heightProportion: source.heightProportion,
    isFloating: source.isFloating,
    isFullscreen: source.isFullscreen,
    isMaximized: source.isMaximized,
    isMinimized: source.isMinimized,
    fullscreenOutput: ExternalOutputId(source.fullscreenOutput),
    floatingGeom: source.floatingGeom,
    manualFloatingPosition: source.manualFloatingPosition,
    actualW: source.actualW,
    actualH: source.actualH,
  )

proc restoredTagData*(source: rv.RestoredTagState): RestoredTagData =
  result = RestoredTagData(
    slot: source.tagId,
    name: source.name,
    layoutMode: source.layoutMode,
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
      widthProportion: col.widthProportion, isFullWidth: col.isFullWidth
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
  result.visibleScratchpad = ExternalWindowId(uint32(source.visibleScratchpad))
  result.isScratchpadVisible = source.isScratchpadVisible
  for winId in source.focusHistory:
    result.focusHistory.add(ExternalWindowId(uint32(winId)))
  for slot in source.workspaceHistory:
    result.workspaceHistory.add(slot)

proc hasOutputTag(model: Model, tagId: TagId): bool =
  for _, outputTagId in model.outputTags.pairs:
    if outputTagId == tagId:
      return true
  false

proc shouldPersistTag(model: Model, tag: TagData): bool =
  if tag.slot <= model.defaultWorkspaceCount:
    return true
  if tag.id == model.activeTag or model.tagHasLiveWindows(tag.id) or
      model.hasOutputTag(tag.id):
    return true
  if tag.name.len > 0 or tag.layoutMode != LayoutMode.Scroller:
    return true
  if tag.focusedWindow != NullWindowId or model.columnsForTag(tag.id).len > 0:
    return true
  if tag.targetViewportXOffset != 0 or tag.currentViewportXOffset != 0 or
      tag.targetViewportYOffset != 0 or tag.currentViewportYOffset != 0:
    return true
  tag.masterCount != DefaultMasterCount or tag.masterSplitRatio != DefaultMasterRatio

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
    var restoredTag = rv.RestoredTagState(
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

    for colId in model.columnsForTag(tagId):
      let colOpt = model.columnData(colId)
      if colOpt.isNone:
        continue
      var restoredCol = rv.RestoredColumnState(
        widthProportion: colOpt.get().widthProportion,
        isFullWidth: colOpt.get().isFullWidth,
      )
      for winId in model.windowsForColumn(colId):
        if not model.windowAdmitted(winId):
          continue
        let external = model.externalWindowId(winId)
        if external == 0:
          continue
        restoredCol.windows.add(external)
        result.tagByWindow[external] = tag.slot
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

    result.windows[external] = rv.RestoredWindowState(
      tagId: slot,
      parentId: rv.WindowId(uint32(win.parentExternalId)),
      appId: win.appId,
      title: win.title,
      identifier: win.identifier,
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      fullscreenOutput: uint32(win.fullscreenOutput),
      floatingGeom: win.floatingGeom,
      manualFloatingPosition: win.manualFloatingPosition,
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

proc rectJson(rect: rv.Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc windowStateJson(winId: rv.WindowId, win: rv.RestoredWindowState): JsonNode =
  %*{
    "id": winId,
    "tag_id": win.tagId,
    "parent_id": win.parentId,
    "app_id": win.appId,
    "title": win.title,
    "identifier": win.identifier,
    "width_proportion": win.widthProportion,
    "height_proportion": win.heightProportion,
    "is_floating": win.isFloating,
    "is_fullscreen": win.isFullscreen,
    "is_maximized": win.isMaximized,
    "is_minimized": win.isMinimized,
    "fullscreen_output": win.fullscreenOutput,
    "floating_geom": rectJson(win.floatingGeom),
    "manual_floating_position": win.manualFloatingPosition,
    "actual_w": win.actualW,
    "actual_h": win.actualH,
  }

proc tagStateJson(tag: rv.RestoredTagState): JsonNode =
  let columns = newJArray()
  for col in tag.columns:
    let windows = newJArray()
    for winId in col.windows:
      windows.add(%winId)
    columns.add(
      %*{
        "windows": windows,
        "width_proportion": col.widthProportion,
        "is_full_width": col.isFullWidth,
      }
    )

  %*{
    "id": tag.tagId,
    "name": tag.name,
    "layout_mode": ord(tag.layoutMode),
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
  var winIds: seq[rv.WindowId]
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
