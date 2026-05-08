import json, options, os, tables
import model

type
  LiveRestoreState* = object
    activeTag*: uint32
    tagByWindow*: Table[WindowId, uint32]

proc uint32FromJson(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() > 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc parseLiveRestoreJson*(payload: string): Option[LiveRestoreState] =
  var root: JsonNode
  try:
    root = parseJson(payload)
  except CatchableError:
    return none(LiveRestoreState)

  if root.kind != JObject:
    return none(LiveRestoreState)

  result = some(LiveRestoreState())
  var state = result.get()

  if root.hasKey("workspaces") and root["workspaces"].kind == JArray:
    for workspace in root["workspaces"]:
      if workspace.kind == JObject and workspace.hasKey("is_active") and
          workspace["is_active"].kind == JBool and workspace["is_active"].getBool() and
          workspace.hasKey("id"):
        let tagId = uint32FromJson(workspace["id"])
        if tagId.isSome:
          state.activeTag = tagId.get()
          break

  if root.hasKey("windows") and root["windows"].kind == JArray:
    for win in root["windows"]:
      if win.kind != JObject or not win.hasKey("id") or not win.hasKey("workspace_id"):
        continue
      if win["workspace_id"].kind == JNull:
        continue
      let winId = uint32FromJson(win["id"])
      let tagId = uint32FromJson(win["workspace_id"])
      if winId.isSome and tagId.isSome:
        state.tagByWindow[WindowId(winId.get())] = tagId.get()

  if state.activeTag == 0 and state.tagByWindow.len == 0:
    return none(LiveRestoreState)

  result = some(state)

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

proc applyLiveRestore*(model: var Model; state: LiveRestoreState) =
  model.restoreActiveTag = state.activeTag
  model.restoreTagByWindow = state.tagByWindow
  if state.activeTag != 0:
    model.activeTag = state.activeTag
