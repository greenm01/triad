import algorithm, json, options, os, tables
import engine
import ../core/restore_state
import ../types/core as dod_core
import ../types/dod_model as dod_model
import ../types/legacy_model as legacy

proc legacyWindowId(win: dod_model.WindowData): legacy.WindowId =
  legacy.WindowId(uint32(win.externalId))

proc externalWindowId(
    model: DodModel; winId: dod_core.WindowId): legacy.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return 0'u32
  winOpt.get().legacyWindowId()

proc focusedOnActiveTag(model: DodModel): legacy.WindowId =
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
  if winOpt.isNone or winOpt.get().isMinimized:
    return 0'u32
  winOpt.get().legacyWindowId()

proc hasOutputTag(model: DodModel; tagId: TagId): bool =
  for _, outputTagId in model.outputTags.pairs:
    if outputTagId == tagId:
      return true
  false

proc shouldPersistTag(model: DodModel; tag: TagData): bool =
  if tag.slot <= model.defaultWorkspaceCount:
    return true
  if tag.id == model.activeTag or model.tagHasLiveWindows(tag.id) or
      model.hasOutputTag(tag.id):
    return true
  if tag.name.len > 0 or tag.layoutMode != Scroller:
    return true
  if tag.focusedWindow != NullWindowId or model.columnsForTag(tag.id).len > 0:
    return true
  if tag.targetViewportXOffset != 0 or tag.currentViewportXOffset != 0 or
      tag.targetViewportYOffset != 0 or tag.currentViewportYOffset != 0:
    return true
  tag.masterCount != DefaultMasterCount or
    tag.masterSplitRatio != DefaultMasterRatio

proc dodLiveRestoreState*(model: DodModel): LiveRestoreState =
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
    var restoredTag = legacy.RestoredTagState(
      tagId: tag.slot,
      name: tag.name,
      layoutMode: tag.layoutMode,
      focusedWindow: model.externalWindowId(tag.focusedWindow),
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset,
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio
    )

    for colId in model.columnsForTag(tagId):
      let colOpt = model.columnData(colId)
      if colOpt.isNone:
        continue
      var restoredCol = legacy.RestoredColumnState(
        widthProportion: colOpt.get().widthProportion)
      for winId in model.windowsForColumn(colId):
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
    let external = win.legacyWindowId()
    if external == 0:
      continue
    var slot = result.tagByWindow.getOrDefault(external, 0'u32)
    if slot == 0:
      let position = model.firstWindowPosition(winId)
      if position.found:
        slot = position.slot

    result.windows[external] = legacy.RestoredWindowState(
      tagId: slot,
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
      actualW: win.actualW,
      actualH: win.actualH
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

  for winId in model.scratchpadWindows:
    let external = model.externalWindowId(winId)
    if external != 0:
      result.scratchpadWindows.add(external)

  for name, winId in model.namedScratchpads.pairs:
    let external = model.externalWindowId(winId)
    if external != 0:
      result.namedScratchpads[name] = external

  result.visibleScratchpad = model.externalWindowId(model.visibleScratchpad)
  result.isScratchpadVisible = model.isScratchpadVisible

  for winId in model.focusHistory:
    let external = model.externalWindowId(winId)
    if external != 0:
      result.focusHistory.add(external)

  for tagId in model.workspaceHistory:
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome and tagOpt.get().slot != 0:
      result.workspaceHistory.add(tagOpt.get().slot)

proc rectJson(rect: legacy.Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc windowStateJson(
    winId: legacy.WindowId; win: legacy.RestoredWindowState): JsonNode =
  %*{
    "id": winId,
    "tag_id": win.tagId,
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
    "actual_w": win.actualW,
    "actual_h": win.actualH
  }

proc tagStateJson(tag: legacy.RestoredTagState): JsonNode =
  let columns = newJArray()
  for col in tag.columns:
    let windows = newJArray()
    for winId in col.windows:
      windows.add(%winId)
    columns.add(%*{
      "windows": windows,
      "width_proportion": col.widthProportion
    })

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
    "master_split_ratio": tag.masterSplitRatio
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
  var winIds: seq[legacy.WindowId]
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
    outputTags.add(%*{
      "output_id": outputId,
      "tag_id": state.outputTags[outputId]
    })

  let scratchpads = newJArray()
  for winId in state.scratchpadWindows:
    scratchpads.add(%winId)

  let namedScratchpads = newJArray()
  var names: seq[string]
  for name in state.namedScratchpads.keys:
    names.add(name)
  names.sort()
  for name in names:
    namedScratchpads.add(%*{
      "name": name,
      "window_id": state.namedScratchpads[name]
    })

  let focusHistory = newJArray()
  for winId in state.focusHistory:
    focusHistory.add(%winId)

  let workspaceHistory = newJArray()
  for tagId in state.workspaceHistory:
    workspaceHistory.add(%tagId)

  $(%*{
    "schema": LiveRestoreSchema,
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
    "workspace_history": workspaceHistory
  })

proc dodLiveRestoreJson*(model: DodModel): string =
  model.dodLiveRestoreState().liveRestoreStateJson()

proc writeDodLiveRestoreState*(
    model: DodModel; path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  if path.len == 0:
    return LiveRestoreWriteResult(ok: false, error: "empty live restore path")

  let dir = path.splitFile().dir
  let tmp = path & ".tmp." & $getCurrentProcessId()
  try:
    if dir.len > 0:
      createDir(dir)
    writeFile(tmp, model.dodLiveRestoreJson() & "\n")
    moveFile(tmp, path)
    LiveRestoreWriteResult(ok: true, path: path)
  except CatchableError as e:
    try:
      if fileExists(tmp):
        removeFile(tmp)
    except CatchableError:
      discard
    LiveRestoreWriteResult(ok: false, path: path, error: e.msg)
