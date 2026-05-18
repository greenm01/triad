import std/[algorithm, json, options, os, strutils, tables, times]
import defaults
import layout_selection_codec
import native_layout_codec
from ../types/core import Rect
import ../types/live_restore
import ../types/runtime_values

export live_restore

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

proc float32FromJson(node: JsonNode, fallback = 0.0'f32): float32 =
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
    x:
      if node.hasKey("x"):
        int32FromJson(node["x"])
      else:
        0'i32,
    y:
      if node.hasKey("y"):
        int32FromJson(node["y"])
      else:
        0'i32,
    w:
      if node.hasKey("w"):
        int32FromJson(node["w"])
      else:
        0'i32,
    h:
      if node.hasKey("h"):
        int32FromJson(node["h"])
      else:
        0'i32,
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

proc frameKindFromJson(node: JsonNode): FrameNodeKind =
  try:
    if node.kind == JInt:
      let value = node.getInt()
      if value >= ord(low(FrameNodeKind)) and value <= ord(high(FrameNodeKind)):
        return FrameNodeKind(value)
    elif node.kind == JString:
      return parseEnum[FrameNodeKind](node.getStr())
  except CatchableError:
    discard
  FrameNodeKind.Leaf

proc frameOrientationFromJson(node: JsonNode): FrameSplitOrientation =
  try:
    if node.kind == JInt:
      let value = node.getInt()
      if value >= ord(low(FrameSplitOrientation)) and
          value <= ord(high(FrameSplitOrientation)):
        return FrameSplitOrientation(value)
    elif node.kind == JString:
      return parseEnum[FrameSplitOrientation](node.getStr())
  except CatchableError:
    discard
  FrameSplitOrientation.Horizontal

proc directionFromJson(node: JsonNode): Direction =
  try:
    if node.kind == JInt:
      let value = node.getInt()
      if value >= ord(low(Direction)) and value <= ord(high(Direction)):
        return Direction(value)
    elif node.kind == JString:
      case node.getStr().normalize()
      of "left", "dirleft":
        return Direction.DirLeft
      of "right", "dirright":
        return Direction.DirRight
      of "up", "dirup":
        return Direction.DirUp
      of "down", "dirdown":
        return Direction.DirDown
      else:
        return parseEnum[Direction](node.getStr())
  except CatchableError:
    discard
  Direction.DirRight

proc parseTagState(state: var LiveRestoreState, node: JsonNode) =
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
    masterSplitRatio: DefaultMasterRatio,
  )

  if node.hasKey("name"):
    tag.name = stringFromJson(node["name"])
  if node.hasKey("custom_layout"):
    let custom = stringFromJson(node["custom_layout"]).strip()
    if custom.len > 0:
      tag.customLayoutId = janetLayoutId(custom)
  if node.hasKey("native_layout"):
    let native = parseNativeLayoutId(stringFromJson(node["native_layout"]).strip())
    if native.isSome:
      tag.nativeLayoutId = native.get().id
  if node.hasKey("focused_window"):
    let focused = uint32FromJson(node["focused_window"])
    if focused.isSome:
      tag.focusedWindow = focused.get()
  if node.hasKey("focused_frame"):
    let focusedFrame = uint32FromJson(node["focused_frame"])
    if focusedFrame.isSome:
      tag.focusedFrame = focusedFrame.get()
  if node.hasKey("target_viewport_x_offset"):
    tag.targetViewportXOffset = float32FromJson(node["target_viewport_x_offset"])
  if node.hasKey("current_viewport_x_offset"):
    tag.currentViewportXOffset = float32FromJson(node["current_viewport_x_offset"])
  if node.hasKey("target_viewport_y_offset"):
    tag.targetViewportYOffset = float32FromJson(node["target_viewport_y_offset"])
  if node.hasKey("current_viewport_y_offset"):
    tag.currentViewportYOffset = float32FromJson(node["current_viewport_y_offset"])
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
      if colNode.hasKey("scroller_single_proportion"):
        col.scrollerSingleProportion =
          float32FromJson(colNode["scroller_single_proportion"], 0.0'f32)
      if colNode.hasKey("is_full_width"):
        col.isFullWidth = boolFromJson(colNode["is_full_width"])
      if colNode.hasKey("windows") and colNode["windows"].kind == JArray:
        for winNode in colNode["windows"]:
          let winId = uint32FromJson(winNode)
          if winId.isSome:
            col.windows.add(winId.get())
            state.tagByWindow[winId.get()] = tag.tagId
      tag.columns.add(col)

  if node.hasKey("frames") and node["frames"].kind == JArray:
    for frameNode in node["frames"]:
      if frameNode.kind != JObject or not frameNode.hasKey("id"):
        continue
      let frameId = uint32FromJson(frameNode["id"])
      if frameId.isNone:
        continue
      var frame = RestoredFrameState(
        id: frameId.get(),
        kind:
          if frameNode.hasKey("kind"):
            frameKindFromJson(frameNode["kind"])
          else:
            FrameNodeKind.Leaf,
        orientation:
          if frameNode.hasKey("orientation"):
            frameOrientationFromJson(frameNode["orientation"])
          else:
            FrameSplitOrientation.Horizontal,
        ratio: 0.5'f32,
      )
      if frameNode.hasKey("parent"):
        let parent = uint32FromJson(frameNode["parent"])
        if parent.isSome:
          frame.parent = parent.get()
      if frameNode.hasKey("first_child"):
        let child = uint32FromJson(frameNode["first_child"])
        if child.isSome:
          frame.firstChild = child.get()
      if frameNode.hasKey("second_child"):
        let child = uint32FromJson(frameNode["second_child"])
        if child.isSome:
          frame.secondChild = child.get()
      if frameNode.hasKey("ratio"):
        frame.ratio =
          clamp(float32FromJson(frameNode["ratio"], 0.5'f32), 0.05'f32, 0.95'f32)
      if frameNode.hasKey("active_window"):
        let active = uint32FromJson(frameNode["active_window"])
        if active.isSome:
          frame.activeWindow = active.get()
      if frameNode.hasKey("windows") and frameNode["windows"].kind == JArray:
        for winNode in frameNode["windows"]:
          let winId = uint32FromJson(winNode)
          if winId.isSome:
            frame.windows.add(winId.get())
            state.tagByWindow[winId.get()] = tag.tagId
      tag.frames.add(frame)

  if node.hasKey("bsp_nodes") and node["bsp_nodes"].kind == JArray:
    for nodeJson in node["bsp_nodes"]:
      if nodeJson.kind != JObject or not nodeJson.hasKey("id"):
        continue
      let nodeId = uint32FromJson(nodeJson["id"])
      if nodeId.isNone:
        continue
      var bspNode = RestoredBspNodeState(
        id: nodeId.get(),
        kind:
          if nodeJson.hasKey("kind"):
            frameKindFromJson(nodeJson["kind"])
          else:
            FrameNodeKind.Leaf,
        orientation:
          if nodeJson.hasKey("orientation"):
            frameOrientationFromJson(nodeJson["orientation"])
          else:
            FrameSplitOrientation.Horizontal,
        ratio: 0.5'f32,
      )
      if nodeJson.hasKey("parent"):
        let parent = uint32FromJson(nodeJson["parent"])
        if parent.isSome:
          bspNode.parent = parent.get()
      if nodeJson.hasKey("first_child"):
        let child = uint32FromJson(nodeJson["first_child"])
        if child.isSome:
          bspNode.firstChild = child.get()
      if nodeJson.hasKey("second_child"):
        let child = uint32FromJson(nodeJson["second_child"])
        if child.isSome:
          bspNode.secondChild = child.get()
      if nodeJson.hasKey("ratio"):
        bspNode.ratio =
          clamp(float32FromJson(nodeJson["ratio"], 0.5'f32), 0.05'f32, 0.95'f32)
      if nodeJson.hasKey("preselect_direction") and
          nodeJson["preselect_direction"].kind != JNull:
        bspNode.hasPreselection = true
        bspNode.preselectDirection = directionFromJson(nodeJson["preselect_direction"])
        bspNode.preselectRatio = 0.5'f32
      if nodeJson.hasKey("preselect_ratio") and nodeJson["preselect_ratio"].kind != JNull:
        bspNode.hasPreselection = true
        bspNode.preselectRatio = clamp(
          float32FromJson(nodeJson["preselect_ratio"], 0.5'f32), 0.05'f32, 0.95'f32
        )
      if nodeJson.hasKey("window"):
        let winId = uint32FromJson(nodeJson["window"])
        if winId.isSome:
          bspNode.window = winId.get()
          state.tagByWindow[winId.get()] = tag.tagId
      tag.bspNodes.add(bspNode)

  state.tags[tag.tagId] = tag

proc parseWindowState(state: var LiveRestoreState, node: JsonNode) =
  if node.kind != JObject or not node.hasKey("id"):
    return
  let winId = uint32FromJson(node["id"])
  if winId.isNone:
    return

  let externalId = winId.get()
  var win = RestoredWindowState(
    widthProportion: DefaultColumnWidth, heightProportion: DefaultWindowHeight
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
      win.parentId = parentId.get()
  if node.hasKey("swallowed_by"):
    let swallowedBy = uint32FromJson(node["swallowed_by"])
    if swallowedBy.isSome:
      win.swallowedBy = swallowedBy.get()
      state.swallowedBy[externalId] = win.swallowedBy
  if node.hasKey("swallowing"):
    let swallowing = uint32FromJson(node["swallowing"])
    if swallowing.isSome:
      win.swallowing = swallowing.get()
      state.swallowing[externalId] = win.swallowing
  if node.hasKey("pid"):
    win.pid = max(0'i32, int32FromJson(node["pid"]))
  if node.hasKey("app_id"):
    win.appId = stringFromJson(node["app_id"])
  if node.hasKey("title"):
    win.title = stringFromJson(node["title"])
  if node.hasKey("identifier"):
    win.identifier = stringFromJson(node["identifier"])
  if node.hasKey("width_proportion"):
    win.widthProportion = float32FromJson(node["width_proportion"], DefaultColumnWidth)
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
  if node.hasKey("is_sticky"):
    win.isSticky = boolFromJson(node["is_sticky"])
  if node.hasKey("is_unmanaged_global"):
    win.isUnmanagedGlobal = boolFromJson(node["is_unmanaged_global"])
  if node.hasKey("fullscreen_output"):
    let output = uint32FromJson(node["fullscreen_output"])
    if output.isSome:
      win.fullscreenOutput = output.get()
  if node.hasKey("floating_geom"):
    win.floatingGeom = rectFromJson(node["floating_geom"])
  if node.hasKey("manual_floating_position"):
    win.manualFloatingPosition = boolFromJson(node["manual_floating_position"])
  if node.hasKey("is_terminal"):
    win.isTerminal = boolFromJson(node["is_terminal"])
  if node.hasKey("allow_swallow"):
    win.allowSwallow = boolFromJson(node["allow_swallow"])
  else:
    win.allowSwallow = true
  if node.hasKey("actual_w"):
    win.actualW = max(0'i32, int32FromJson(node["actual_w"]))
  if node.hasKey("actual_h"):
    win.actualH = max(0'i32, int32FromJson(node["actual_h"]))

  state.windows[externalId] = win

proc parseScratchpadRestoreSlots(state: var LiveRestoreState, node: JsonNode) =
  if node.kind != JObject or not node.hasKey("window_id") or not node.hasKey("slots"):
    return
  let winId = uint32FromJson(node["window_id"])
  if winId.isNone or node["slots"].kind != JArray:
    return

  var slots: seq[uint32] = @[]
  for slotNode in node["slots"]:
    let slot = uint32FromJson(slotNode)
    if slot.isSome and slot.get() > 0 and slot.get() <= MaxWorkspaceCount and
        slots.find(slot.get()) == -1:
      slots.add(slot.get())
  if slots.len > 0:
    slots.sort()
    state.scratchpadRestoreSlots[winId.get()] = slots

proc parseNativeLiveRestore(root: JsonNode): Option[LiveRestoreState] =
  var state = LiveRestoreState()

  if root.hasKey("active_tag"):
    let activeTag = uint32FromJson(root["active_tag"])
    if activeTag.isSome:
      state.activeTag = activeTag.get()
  if root.hasKey("focused_window"):
    let focused = uint32FromJson(root["focused_window"])
    if focused.isSome:
      state.focusedWindow = focused.get()

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

  if root.hasKey("scratchpad_windows") and root["scratchpad_windows"].kind == JArray:
    for node in root["scratchpad_windows"]:
      let winId = uint32FromJson(node)
      if winId.isSome:
        state.scratchpadWindows.add(winId.get())

  if root.hasKey("named_scratchpads") and root["named_scratchpads"].kind == JArray:
    for node in root["named_scratchpads"]:
      if node.kind != JObject or not node.hasKey("name") or not node.hasKey("window_id"):
        continue
      let winId = uint32FromJson(node["window_id"])
      if winId.isSome:
        state.namedScratchpads[stringFromJson(node["name"])] = winId.get()

  if root.hasKey("scratchpad_restore_slots") and
      root["scratchpad_restore_slots"].kind == JArray:
    for node in root["scratchpad_restore_slots"]:
      state.parseScratchpadRestoreSlots(node)

  if root.hasKey("visible_scratchpad"):
    let winId = uint32FromJson(root["visible_scratchpad"])
    if winId.isSome:
      state.visibleScratchpad = winId.get()
  if root.hasKey("is_scratchpad_visible"):
    state.isScratchpadVisible = boolFromJson(root["is_scratchpad_visible"])

  if root.hasKey("focus_history") and root["focus_history"].kind == JArray:
    for node in root["focus_history"]:
      let winId = uint32FromJson(node)
      if winId.isSome:
        state.focusHistory.add(winId.get())

  if root.hasKey("workspace_history") and root["workspace_history"].kind == JArray:
    for node in root["workspace_history"]:
      let tagId = uint32FromJson(node)
      if tagId.isSome:
        state.workspaceHistory.add(tagId.get())

  if state.activeTag == 0 and state.tagByWindow.len == 0 and state.windows.len == 0 and
      state.tags.len == 0:
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

proc readLiveRestoreState*(path: string): Option[LiveRestoreState] =
  if path.len == 0 or not fileExists(path):
    return none(LiveRestoreState)
  try:
    readFile(path).parseLiveRestoreJson()
  except CatchableError:
    none(LiveRestoreState)

proc liveRestoreEnvFlagEnabled(value: string): bool =
  case value.normalize()
  of "1", "true", "yes", "on": true
  else: false

proc liveRestoreCollapseAllowed*(): bool =
  getEnv("TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE", "").liveRestoreEnvFlagEnabled()

proc sortedRestoreWindowIds(state: LiveRestoreState): seq[uint32] =
  for winId in state.windows.keys:
    result.add(uint32(winId))
  result.sort()

proc occupiedRestoreSlots(state: LiveRestoreState): seq[uint32] =
  for _, win in state.windows.pairs:
    if win.tagId != 0 and result.find(win.tagId) == -1:
      result.add(win.tagId)
  result.sort()

proc sameRestoreWindowSet(previous, candidate: LiveRestoreState): bool =
  previous.sortedRestoreWindowIds() == candidate.sortedRestoreWindowIds()

proc suspiciousLiveRestoreCollapse*(previous, candidate: LiveRestoreState): bool =
  let previousWindows = previous.sortedRestoreWindowIds()
  if previousWindows.len < 2:
    return false
  if not previous.sameRestoreWindowSet(candidate):
    return false
  previous.occupiedRestoreSlots().len > 1 and candidate.occupiedRestoreSlots().len == 1

proc liveRestoreStatus(root: JsonNode): string =
  if root.kind == JObject and root.hasKey("restore_status") and
      root["restore_status"].kind == JString:
    root["restore_status"].getStr()
  else:
    ""

proc liveRestorePayloadApplied*(payload: string): bool =
  try:
    let root = parseJson(payload)
    root.kind == JObject and root.hasKey("schema") and root["schema"].kind == JString and
      root["schema"].getStr() == LiveRestoreSchema and
      root.liveRestoreStatus() == LiveRestoreStatusApplied
  except CatchableError:
    false

proc liveRestoreStateApplied*(path: string): bool =
  if path.len == 0 or not fileExists(path):
    return false
  try:
    readFile(path).liveRestorePayloadApplied()
  except CatchableError:
    false

proc defaultLiveRestorePath*(): string =
  let configured = getEnv("TRIAD_LIVE_RESTORE_PATH", "")
  if configured.len > 0:
    return configured
  getEnv("XDG_RUNTIME_DIR", "/tmp") / "triad-live-restore.json"

proc loadLiveRestoreState*(path: string): Option[LiveRestoreState] =
  if path.len == 0 or not fileExists(path):
    return none(LiveRestoreState)

  try:
    let payload = readFile(path)
    if payload.liveRestorePayloadApplied():
      return none(LiveRestoreState)
    result = parseLiveRestoreJson(payload)
  except CatchableError:
    result = none(LiveRestoreState)

proc completeLiveRestoreState*(path: string): bool

proc consumeLiveRestoreState*(path: string): Option[LiveRestoreState] =
  result = loadLiveRestoreState(path)
  if result.isSome:
    discard completeLiveRestoreState(path)

proc completeLiveRestoreState*(path: string): bool =
  if path.len == 0:
    return false
  if not fileExists(path):
    return true

  let tmp = path & ".tmp." & $getCurrentProcessId()
  try:
    let root = parseJson(readFile(path))
    if root.kind != JObject:
      return false
    if not root.hasKey("schema") or root["schema"].kind != JString or
        root["schema"].getStr() != LiveRestoreSchema:
      return false
    root["restore_status"] = %LiveRestoreStatusApplied
    root["applied_at_unix_ms"] = %int64(epochTime() * 1000.0)
    root["applied_by_pid"] = %getCurrentProcessId()
    writeFile(tmp, $root & "\n")
    moveFile(tmp, path)
    true
  except CatchableError:
    try:
      if fileExists(tmp):
        removeFile(tmp)
    except CatchableError:
      discard
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
