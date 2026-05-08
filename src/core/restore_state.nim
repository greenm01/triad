import algorithm, json, options, os, strutils, tables
import defaults
import model
import model_utils

const LiveRestoreSchema* = "triad-live-restore-v2"

type
  LiveRestoreState* = object
    activeTag*: uint32
    focusedWindow*: WindowId
    tagByWindow*: Table[WindowId, uint32]
    windows*: Table[WindowId, RestoredWindowState]
    tags*: Table[uint32, RestoredTagState]
    outputTags*: Table[uint32, uint32]
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool
    focusHistory*: seq[WindowId]
    workspaceHistory*: seq[uint32]

  LiveRestoreWriteResult* = object
    ok*: bool
    path*: string
    error*: string

proc uint32FromJson(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() > 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc int32FromJson(node: JsonNode): int32 =
  try:
    if node.kind == JInt:
      return int32(node.getInt())
  except CatchableError:
    discard
  0'i32

proc float32FromJson(node: JsonNode; fallback = 0.0'f32): float32 =
  try:
    if node.kind in {JFloat, JInt}:
      return float32(node.getFloat())
  except CatchableError:
    discard
  fallback

proc boolFromJson(node: JsonNode): bool =
  node.kind == JBool and node.getBool()

proc stringFromJson(node: JsonNode): string =
  if node.kind == JString:
    node.getStr()
  else:
    ""

proc rectJson(rect: Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc rectFromJson(node: JsonNode): Rect =
  if node.kind != JObject:
    return Rect()
  Rect(
    x: if node.hasKey("x"): int32FromJson(node["x"]) else: 0'i32,
    y: if node.hasKey("y"): int32FromJson(node["y"]) else: 0'i32,
    w: if node.hasKey("w"): int32FromJson(node["w"]) else: 0'i32,
    h: if node.hasKey("h"): int32FromJson(node["h"]) else: 0'i32
  )

proc layoutModeFromJson(node: JsonNode): LayoutMode =
  try:
    if node.kind == JInt:
      let value = node.getInt()
      if value >= ord(low(LayoutMode)) and value <= ord(high(LayoutMode)):
        return LayoutMode(value)
    elif node.kind == JString:
      return parseEnum[LayoutMode](node.getStr())
  except CatchableError:
    discard
  Scroller

proc windowStateJson(win: WindowData; tagId: uint32): JsonNode =
  %*{
    "id": win.id,
    "tag_id": tagId,
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

proc tagStateJson(tag: TagState): JsonNode =
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

proc liveRestoreJson*(model: Model): string =
  let tags = newJArray()
  var tagIds: seq[uint32] = @[]
  for tagId in model.tags.keys:
    tagIds.add(tagId)
  tagIds.sort()
  for tagId in tagIds:
    tags.add(tagStateJson(model.tags[tagId]))

  let windows = newJArray()
  var winIds: seq[WindowId] = @[]
  for winId in model.windows.keys:
    winIds.add(winId)
  winIds.sort()
  for winId in winIds:
    var tagId = 0'u32
    for candidateTagId, tag in model.tags.pairs:
      for col in tag.columns:
        if col.windows.find(winId) != -1:
          tagId = candidateTagId
          break
      if tagId != 0:
        break
    windows.add(windowStateJson(model.windows[winId], tagId))

  let outputTags = newJArray()
  var outputIds: seq[uint32] = @[]
  for outputId in model.outputTags.keys:
    outputIds.add(outputId)
  outputIds.sort()
  for outputId in outputIds:
    outputTags.add(%*{"output_id": outputId, "tag_id": model.outputTags[outputId]})

  let scratchpads = newJArray()
  for winId in model.scratchpadWindows:
    scratchpads.add(%winId)

  let namedScratchpads = newJArray()
  var names: seq[string] = @[]
  for name in model.namedScratchpads.keys:
    names.add(name)
  names.sort()
  for name in names:
    namedScratchpads.add(%*{"name": name, "window_id": model.namedScratchpads[name]})

  let focusHistory = newJArray()
  for winId in model.focusHistory:
    if model.windows.hasKey(winId):
      focusHistory.add(%winId)

  let workspaceHistory = newJArray()
  for tagId in model.workspaceHistory:
    if tagId != 0 and model.tags.hasKey(tagId):
      workspaceHistory.add(%tagId)

  $(%*{
    "schema": LiveRestoreSchema,
    "active_tag": model.activeTag,
    "focused_window": model.focusedOnActiveTag(),
    "tags": tags,
    "windows": windows,
    "output_tags": outputTags,
    "scratchpad_windows": scratchpads,
    "named_scratchpads": namedScratchpads,
    "visible_scratchpad": model.visibleScratchpad,
    "is_scratchpad_visible": model.isScratchpadVisible,
    "focus_history": focusHistory,
    "workspace_history": workspaceHistory
  })

proc parseNativeLiveRestore(root: JsonNode): Option[LiveRestoreState] =
  var state = LiveRestoreState()

  if root.hasKey("active_tag"):
    let activeTag = uint32FromJson(root["active_tag"])
    if activeTag.isSome:
      state.activeTag = activeTag.get()
  if root.hasKey("focused_window"):
    let focused = uint32FromJson(root["focused_window"])
    if focused.isSome:
      state.focusedWindow = WindowId(focused.get())

  if root.hasKey("tags") and root["tags"].kind == JArray:
    for node in root["tags"]:
      if node.kind != JObject or not node.hasKey("id"):
        continue
      let tagId = uint32FromJson(node["id"])
      if tagId.isNone:
        continue
      var tag = RestoredTagState(
        tagId: tagId.get(),
        layoutMode: if node.hasKey("layout_mode"): layoutModeFromJson(node["layout_mode"]) else: Scroller,
        masterCount: DefaultMasterCount,
        masterSplitRatio: DefaultMasterRatio
      )
      if node.hasKey("name"): tag.name = stringFromJson(node["name"])
      if node.hasKey("focused_window"):
        let focused = uint32FromJson(node["focused_window"])
        if focused.isSome: tag.focusedWindow = WindowId(focused.get())
      if node.hasKey("target_viewport_x_offset"): tag.targetViewportXOffset = float32FromJson(node["target_viewport_x_offset"])
      if node.hasKey("current_viewport_x_offset"): tag.currentViewportXOffset = float32FromJson(node["current_viewport_x_offset"])
      if node.hasKey("target_viewport_y_offset"): tag.targetViewportYOffset = float32FromJson(node["target_viewport_y_offset"])
      if node.hasKey("current_viewport_y_offset"): tag.currentViewportYOffset = float32FromJson(node["current_viewport_y_offset"])
      if node.hasKey("master_count") and node["master_count"].kind == JInt: tag.masterCount = max(1, node["master_count"].getInt())
      if node.hasKey("master_split_ratio"): tag.masterSplitRatio = float32FromJson(node["master_split_ratio"], DefaultMasterRatio)
      if node.hasKey("columns") and node["columns"].kind == JArray:
        for colNode in node["columns"]:
          if colNode.kind != JObject:
            continue
          var col = RestoredColumnState(widthProportion: DefaultColumnWidth)
          if colNode.hasKey("width_proportion"):
            col.widthProportion = float32FromJson(colNode["width_proportion"], DefaultColumnWidth)
          if colNode.hasKey("windows") and colNode["windows"].kind == JArray:
            for winNode in colNode["windows"]:
              let winId = uint32FromJson(winNode)
              if winId.isSome:
                col.windows.add(WindowId(winId.get()))
                state.tagByWindow[WindowId(winId.get())] = tag.tagId
          tag.columns.add(col)
      state.tags[tag.tagId] = tag

  if state.focusedWindow == 0 and state.activeTag != 0 and state.tags.hasKey(state.activeTag):
    state.focusedWindow = state.tags[state.activeTag].focusedWindow

  if root.hasKey("windows") and root["windows"].kind == JArray:
    for node in root["windows"]:
      if node.kind != JObject or not node.hasKey("id"):
        continue
      let winId = uint32FromJson(node["id"])
      if winId.isNone:
        continue
      var win = RestoredWindowState(widthProportion: DefaultColumnWidth, heightProportion: DefaultWindowHeight)
      if node.hasKey("tag_id"):
        let tagId = uint32FromJson(node["tag_id"])
        if tagId.isSome:
          win.tagId = tagId.get()
          state.tagByWindow[WindowId(winId.get())] = win.tagId
      elif state.tagByWindow.hasKey(WindowId(winId.get())):
        win.tagId = state.tagByWindow[WindowId(winId.get())]
      if node.hasKey("app_id"): win.appId = stringFromJson(node["app_id"])
      if node.hasKey("title"): win.title = stringFromJson(node["title"])
      if node.hasKey("identifier"): win.identifier = stringFromJson(node["identifier"])
      if node.hasKey("width_proportion"): win.widthProportion = float32FromJson(node["width_proportion"], DefaultColumnWidth)
      if node.hasKey("height_proportion"): win.heightProportion = float32FromJson(node["height_proportion"], DefaultWindowHeight)
      if node.hasKey("is_floating"): win.isFloating = boolFromJson(node["is_floating"])
      if node.hasKey("is_fullscreen"): win.isFullscreen = boolFromJson(node["is_fullscreen"])
      if node.hasKey("is_maximized"): win.isMaximized = boolFromJson(node["is_maximized"])
      if node.hasKey("is_minimized"): win.isMinimized = boolFromJson(node["is_minimized"])
      if node.hasKey("fullscreen_output"):
        let output = uint32FromJson(node["fullscreen_output"])
        if output.isSome: win.fullscreenOutput = output.get()
      if node.hasKey("floating_geom"): win.floatingGeom = rectFromJson(node["floating_geom"])
      if node.hasKey("actual_w"): win.actualW = max(0'i32, int32FromJson(node["actual_w"]))
      if node.hasKey("actual_h"): win.actualH = max(0'i32, int32FromJson(node["actual_h"]))
      state.windows[WindowId(winId.get())] = win

  if root.hasKey("output_tags") and root["output_tags"].kind == JArray:
    for node in root["output_tags"]:
      if node.kind != JObject or not node.hasKey("output_id") or not node.hasKey("tag_id"):
        continue
      let outputId = uint32FromJson(node["output_id"])
      let tagId = uint32FromJson(node["tag_id"])
      if outputId.isSome and tagId.isSome:
        state.outputTags[outputId.get()] = tagId.get()

  if root.hasKey("scratchpad_windows") and root["scratchpad_windows"].kind == JArray:
    for node in root["scratchpad_windows"]:
      let winId = uint32FromJson(node)
      if winId.isSome: state.scratchpadWindows.add(WindowId(winId.get()))

  if root.hasKey("named_scratchpads") and root["named_scratchpads"].kind == JArray:
    for node in root["named_scratchpads"]:
      if node.kind != JObject or not node.hasKey("name") or not node.hasKey("window_id"):
        continue
      let winId = uint32FromJson(node["window_id"])
      if winId.isSome:
        state.namedScratchpads[stringFromJson(node["name"])] = WindowId(winId.get())

  if root.hasKey("visible_scratchpad"):
    let winId = uint32FromJson(root["visible_scratchpad"])
    if winId.isSome: state.visibleScratchpad = WindowId(winId.get())
  if root.hasKey("is_scratchpad_visible"):
    state.isScratchpadVisible = boolFromJson(root["is_scratchpad_visible"])

  if root.hasKey("focus_history") and root["focus_history"].kind == JArray:
    for node in root["focus_history"]:
      let winId = uint32FromJson(node)
      if winId.isSome:
        state.focusHistory.add(WindowId(winId.get()))

  if root.hasKey("workspace_history") and root["workspace_history"].kind == JArray:
    for node in root["workspace_history"]:
      let tagId = uint32FromJson(node)
      if tagId.isSome:
        state.workspaceHistory.add(tagId.get())

  if state.activeTag == 0 and state.tagByWindow.len == 0 and state.windows.len == 0 and state.tags.len == 0:
    return none(LiveRestoreState)
  return some(state)

proc parseLegacyLiveRestore(root: JsonNode): Option[LiveRestoreState] =
  result = some(LiveRestoreState())
  var state = result.get()
  var windowsByTag = initTable[uint32, seq[tuple[pos: int, winId: WindowId, width: float32]]]()

  if root.hasKey("workspaces") and root["workspaces"].kind == JArray:
    for workspace in root["workspaces"]:
      if workspace.kind != JObject or not workspace.hasKey("id"):
        continue
      let tagId = uint32FromJson(workspace["id"])
      if tagId.isSome:
        var tag = RestoredTagState(
          tagId: tagId.get(),
          layoutMode: Scroller,
          masterCount: DefaultMasterCount,
          masterSplitRatio: DefaultMasterRatio
        )
        if workspace.hasKey("name"):
          tag.name = stringFromJson(workspace["name"])
        state.tags[tag.tagId] = tag
        if workspace.hasKey("is_active") and workspace["is_active"].kind == JBool and workspace["is_active"].getBool():
          state.activeTag = tagId.get()

  if root.hasKey("windows") and root["windows"].kind == JArray:
    for win in root["windows"]:
      if win.kind != JObject or not win.hasKey("id") or not win.hasKey("workspace_id"):
        continue
      if win["workspace_id"].kind == JNull:
        continue
      let winId = uint32FromJson(win["id"])
      let tagId = uint32FromJson(win["workspace_id"])
      if winId.isSome and tagId.isSome:
        let id = WindowId(winId.get())
        state.tagByWindow[id] = tagId.get()
        var restored = RestoredWindowState(tagId: tagId.get(), widthProportion: DefaultColumnWidth, heightProportion: DefaultWindowHeight)
        if win.hasKey("raw_app_id"):
          restored.appId = stringFromJson(win["raw_app_id"])
        elif win.hasKey("app_id"):
          restored.appId = stringFromJson(win["app_id"])
        if win.hasKey("title"):
          restored.title = stringFromJson(win["title"])
        if win.hasKey("is_floating"): restored.isFloating = boolFromJson(win["is_floating"])
        if win.hasKey("is_fullscreen"): restored.isFullscreen = boolFromJson(win["is_fullscreen"])
        if win.hasKey("is_maximized"): restored.isMaximized = boolFromJson(win["is_maximized"])
        if win.hasKey("is_minimized"): restored.isMinimized = boolFromJson(win["is_minimized"])
        var pos = int(high(int32))
        if win.hasKey("layout") and win["layout"].kind == JObject:
          let layout = win["layout"]
          if layout.hasKey("window_size") and layout["window_size"].kind == JArray and layout["window_size"].len >= 2:
            restored.actualW = int32FromJson(layout["window_size"][0])
            restored.actualH = int32FromJson(layout["window_size"][1])
          if layout.hasKey("tile_size") and layout["tile_size"].kind == JArray and layout["tile_size"].len >= 2:
            let tileW = float32FromJson(layout["tile_size"][0])
            let tileH = float32FromJson(layout["tile_size"][1])
            if tileW > 0 and restored.actualW > 0:
              restored.widthProportion = min(1.0'f32, max(0.05'f32, float32(restored.actualW) / tileW))
            if tileH > 0 and restored.actualH > 0:
              restored.heightProportion = min(1.0'f32, max(0.05'f32, float32(restored.actualH) / tileH))
          if layout.hasKey("pos_in_scrolling_layout") and layout["pos_in_scrolling_layout"].kind == JArray and layout["pos_in_scrolling_layout"].len > 0:
            try:
              if layout["pos_in_scrolling_layout"][0].kind in {JInt, JFloat}:
                pos = int(layout["pos_in_scrolling_layout"][0].getFloat())
            except CatchableError:
              discard
        state.windows[id] = restored
        if not state.tags.hasKey(tagId.get()):
          state.tags[tagId.get()] = RestoredTagState(tagId: tagId.get(), layoutMode: Scroller, masterCount: DefaultMasterCount, masterSplitRatio: DefaultMasterRatio)
        if win.hasKey("is_focused") and boolFromJson(win["is_focused"]):
          var tag = state.tags[tagId.get()]
          tag.focusedWindow = id
          state.tags[tagId.get()] = tag
          state.focusedWindow = id
        var tagWindows = windowsByTag.getOrDefault(tagId.get())
        tagWindows.add((pos: pos, winId: id, width: restored.widthProportion))
        windowsByTag[tagId.get()] = tagWindows

  for tagId, entries in windowsByTag.mpairs:
    entries.sort(proc(a, b: tuple[pos: int, winId: WindowId, width: float32]): int =
      result = cmp(a.pos, b.pos)
      if result == 0:
        result = cmp(a.winId, b.winId)
    )
    var tag = state.tags.getOrDefault(tagId, RestoredTagState(tagId: tagId, layoutMode: Scroller, masterCount: DefaultMasterCount, masterSplitRatio: DefaultMasterRatio))
    tag.columns = @[]
    for entry in entries:
      tag.columns.add(RestoredColumnState(windows: @[entry.winId], widthProportion: entry.width))
    state.tags[tagId] = tag

  if state.activeTag == 0 and state.tagByWindow.len == 0:
    return none(LiveRestoreState)
  return some(state)

proc parseLiveRestoreJson*(payload: string): Option[LiveRestoreState] =
  var root: JsonNode
  try:
    root = parseJson(payload)
  except CatchableError:
    return none(LiveRestoreState)

  if root.kind != JObject:
    return none(LiveRestoreState)

  if root.hasKey("schema") and root["schema"].kind == JString and root["schema"].getStr() == LiveRestoreSchema:
    return parseNativeLiveRestore(root)
  else:
    return parseLegacyLiveRestore(root)

proc defaultLiveRestorePath*(): string =
  let configured = getEnv("TRIAD_LIVE_RESTORE_PATH", "")
  if configured.len > 0:
    return configured
  getEnv("XDG_RUNTIME_DIR", "/tmp") / "triad-live-restore.json"

proc writeLiveRestoreState*(model: Model; path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  if path.len == 0:
    return LiveRestoreWriteResult(ok: false, error: "empty live restore path")

  let dir = path.splitFile().dir
  let tmp = path & ".tmp." & $getCurrentProcessId()
  try:
    if dir.len > 0:
      createDir(dir)
    writeFile(tmp, liveRestoreJson(model) & "\n")
    moveFile(tmp, path)
    LiveRestoreWriteResult(ok: true, path: path)
  except CatchableError as e:
    try:
      if fileExists(tmp):
        removeFile(tmp)
    except CatchableError:
      discard
    LiveRestoreWriteResult(ok: false, path: path, error: e.msg)

proc loadLiveRestoreState*(path: string): Option[LiveRestoreState] =
  if path.len == 0 or not fileExists(path):
    return none(LiveRestoreState)

  try:
    result = parseLiveRestoreJson(readFile(path))
  except CatchableError:
    result = none(LiveRestoreState)

proc consumeLiveRestoreState*(path: string): Option[LiveRestoreState] =
  result = loadLiveRestoreState(path)
  if path.len > 0 and fileExists(path):
    try:
      removeFile(path)
    except CatchableError:
      discard

proc completeLiveRestoreState*(path: string): bool =
  if path.len == 0:
    return false
  if not fileExists(path):
    return true

  try:
    removeFile(path)
    true
  except CatchableError:
    false

proc quarantineLiveRestoreState*(path: string): bool =
  if path.len == 0 or not fileExists(path):
    return true

  let quarantinePath = path & ".bad." & $getCurrentProcessId()
  try:
    moveFile(path, quarantinePath)
    true
  except CatchableError:
    try:
      removeFile(path)
      true
    except CatchableError:
      false

proc applyLiveRestore*(model: var Model; state: LiveRestoreState) =
  model.restoreActiveTag = state.activeTag
  model.restoreFocusedWindow = state.focusedWindow
  model.restoreTagByWindow = state.tagByWindow
  model.restoreWindows = state.windows
  model.restoreTags = state.tags
  model.outputTags = state.outputTags
  model.scratchpadWindows = state.scratchpadWindows
  model.namedScratchpads = state.namedScratchpads
  model.visibleScratchpad = state.visibleScratchpad
  model.isScratchpadVisible = state.isScratchpadVisible
  model.focusHistory = state.focusHistory
  model.workspaceHistory = state.workspaceHistory
  if state.activeTag != 0:
    model.activeTag = state.activeTag
    var activeHasRestoredWindow = false
    for _, tagId in state.tagByWindow.pairs:
      if tagId == state.activeTag:
        activeHasRestoredWindow = true
        break
    if not activeHasRestoredWindow and state.activeTag > model.defaultWorkspaceCount():
      let fallback = model.lowerWorkspaceFallback(state.activeTag)
      if fallback != 0 and fallback != state.activeTag:
        model.activeTag = fallback
        if model.primaryOutput != 0:
          model.outputTags[model.primaryOutput] = fallback
  discard model.pruneDynamicWorkspaces()
