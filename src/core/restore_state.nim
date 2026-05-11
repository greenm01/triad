import json, options, os, strutils, tables
import defaults
import ../types/runtime_values

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
    if node.kind == JInt and node.getInt() > 0 and
        node.getInt() <= int(high(uint32)):
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
  LayoutMode.Scroller

proc parseTagState(
    state: var LiveRestoreState; node: JsonNode) =
  if node.kind != JObject or not node.hasKey("id"):
    return
  let tagId = uint32FromJson(node["id"])
  if tagId.isNone:
    return

  var tag = RestoredTagState(
    tagId: tagId.get(),
    layoutMode:
    if node.hasKey("layout_mode"):
        layoutModeFromJson(node["layout_mode"])
      else:
        LayoutMode.Scroller,
    masterCount: DefaultMasterCount,
    masterSplitRatio: DefaultMasterRatio
  )

  if node.hasKey("name"):
    tag.name = stringFromJson(node["name"])
  if node.hasKey("focused_window"):
    let focused = uint32FromJson(node["focused_window"])
    if focused.isSome:
      tag.focusedWindow = WindowId(focused.get())
  if node.hasKey("target_viewport_x_offset"):
    tag.targetViewportXOffset =
      float32FromJson(node["target_viewport_x_offset"])
  if node.hasKey("current_viewport_x_offset"):
    tag.currentViewportXOffset =
      float32FromJson(node["current_viewport_x_offset"])
  if node.hasKey("target_viewport_y_offset"):
    tag.targetViewportYOffset =
      float32FromJson(node["target_viewport_y_offset"])
  if node.hasKey("current_viewport_y_offset"):
    tag.currentViewportYOffset =
      float32FromJson(node["current_viewport_y_offset"])
  if node.hasKey("master_count") and node["master_count"].kind == JInt:
    tag.masterCount = max(1, node["master_count"].getInt())
  if node.hasKey("master_split_ratio"):
    tag.masterSplitRatio =
      float32FromJson(node["master_split_ratio"], DefaultMasterRatio)

  if node.hasKey("columns") and node["columns"].kind == JArray:
    for colNode in node["columns"]:
      if colNode.kind != JObject:
        continue
      var col = RestoredColumnState(widthProportion: DefaultColumnWidth)
      if colNode.hasKey("width_proportion"):
        col.widthProportion =
          float32FromJson(colNode["width_proportion"], DefaultColumnWidth)
      if colNode.hasKey("windows") and colNode["windows"].kind == JArray:
        for winNode in colNode["windows"]:
          let winId = uint32FromJson(winNode)
          if winId.isSome:
            col.windows.add(WindowId(winId.get()))
            state.tagByWindow[WindowId(winId.get())] = tag.tagId
      tag.columns.add(col)

  state.tags[tag.tagId] = tag

proc parseWindowState(
    state: var LiveRestoreState; node: JsonNode) =
  if node.kind != JObject or not node.hasKey("id"):
    return
  let winId = uint32FromJson(node["id"])
  if winId.isNone:
    return

  let externalId = WindowId(winId.get())
  var win = RestoredWindowState(
    widthProportion: DefaultColumnWidth,
    heightProportion: DefaultWindowHeight
  )
  if node.hasKey("tag_id"):
    let tagId = uint32FromJson(node["tag_id"])
    if tagId.isSome:
      win.tagId = tagId.get()
      state.tagByWindow[externalId] = win.tagId
  elif state.tagByWindow.hasKey(externalId):
    win.tagId = state.tagByWindow[externalId]

  if node.hasKey("parent_id"):
    let parentId = uint32FromJson(node["parent_id"])
    if parentId.isSome:
      win.parentId = WindowId(parentId.get())
  if node.hasKey("app_id"):
    win.appId = stringFromJson(node["app_id"])
  if node.hasKey("title"):
    win.title = stringFromJson(node["title"])
  if node.hasKey("identifier"):
    win.identifier = stringFromJson(node["identifier"])
  if node.hasKey("width_proportion"):
    win.widthProportion =
      float32FromJson(node["width_proportion"], DefaultColumnWidth)
  if node.hasKey("height_proportion"):
    win.heightProportion =
      float32FromJson(node["height_proportion"], DefaultWindowHeight)
  if node.hasKey("is_floating"):
    win.isFloating = boolFromJson(node["is_floating"])
  if node.hasKey("is_fullscreen"):
    win.isFullscreen = boolFromJson(node["is_fullscreen"])
  if node.hasKey("is_maximized"):
    win.isMaximized = boolFromJson(node["is_maximized"])
  if node.hasKey("is_minimized"):
    win.isMinimized = boolFromJson(node["is_minimized"])
  if node.hasKey("fullscreen_output"):
    let output = uint32FromJson(node["fullscreen_output"])
    if output.isSome:
      win.fullscreenOutput = output.get()
  if node.hasKey("floating_geom"):
    win.floatingGeom = rectFromJson(node["floating_geom"])
  if node.hasKey("actual_w"):
    win.actualW = max(0'i32, int32FromJson(node["actual_w"]))
  if node.hasKey("actual_h"):
    win.actualH = max(0'i32, int32FromJson(node["actual_h"]))

  state.windows[externalId] = win

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
      state.parseTagState(node)

  if state.focusedWindow == 0 and state.activeTag != 0 and
      state.tags.hasKey(state.activeTag):
    state.focusedWindow = state.tags[state.activeTag].focusedWindow

  if root.hasKey("windows") and root["windows"].kind == JArray:
    for node in root["windows"]:
      state.parseWindowState(node)

  if root.hasKey("output_tags") and root["output_tags"].kind == JArray:
    for node in root["output_tags"]:
      if node.kind != JObject or not node.hasKey("output_id") or
          not node.hasKey("tag_id"):
        continue
      let outputId = uint32FromJson(node["output_id"])
      let tagId = uint32FromJson(node["tag_id"])
      if outputId.isSome and tagId.isSome:
        state.outputTags[outputId.get()] = tagId.get()

  if root.hasKey("scratchpad_windows") and
      root["scratchpad_windows"].kind == JArray:
    for node in root["scratchpad_windows"]:
      let winId = uint32FromJson(node)
      if winId.isSome:
        state.scratchpadWindows.add(WindowId(winId.get()))

  if root.hasKey("named_scratchpads") and
      root["named_scratchpads"].kind == JArray:
    for node in root["named_scratchpads"]:
      if node.kind != JObject or not node.hasKey("name") or
          not node.hasKey("window_id"):
        continue
      let winId = uint32FromJson(node["window_id"])
      if winId.isSome:
        state.namedScratchpads[stringFromJson(node["name"])] =
          WindowId(winId.get())

  if root.hasKey("visible_scratchpad"):
    let winId = uint32FromJson(root["visible_scratchpad"])
    if winId.isSome:
      state.visibleScratchpad = WindowId(winId.get())
  if root.hasKey("is_scratchpad_visible"):
    state.isScratchpadVisible = boolFromJson(root["is_scratchpad_visible"])

  if root.hasKey("focus_history") and root["focus_history"].kind == JArray:
    for node in root["focus_history"]:
      let winId = uint32FromJson(node)
      if winId.isSome:
        state.focusHistory.add(WindowId(winId.get()))

  if root.hasKey("workspace_history") and
      root["workspace_history"].kind == JArray:
    for node in root["workspace_history"]:
      let tagId = uint32FromJson(node)
      if tagId.isSome:
        state.workspaceHistory.add(tagId.get())

  if state.activeTag == 0 and state.tagByWindow.len == 0 and
      state.windows.len == 0 and state.tags.len == 0:
    return none(LiveRestoreState)
  some(state)

proc parseLiveRestoreJson*(payload: string): Option[LiveRestoreState] =
  var root: JsonNode
  try:
    root = parseJson(payload)
  except CatchableError:
    return none(LiveRestoreState)

  if root.kind != JObject:
    return none(LiveRestoreState)
  if not root.hasKey("schema") or root["schema"].kind != JString or
      root["schema"].getStr() != LiveRestoreSchema:
    return none(LiveRestoreState)
  parseNativeLiveRestore(root)

proc defaultLiveRestorePath*(): string =
  let configured = getEnv("TRIAD_LIVE_RESTORE_PATH", "")
  if configured.len > 0:
    return configured
  getEnv("XDG_RUNTIME_DIR", "/tmp") / "triad-live-restore.json"

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
