import algorithm, json, os, strutils, tables, times
import ../core/restore_state
import ../types/runtime_values

const
  DefaultMaxBytes* = 5 * 1024 * 1024
  DefaultKeepDays* = 7
  BehaviorLogPrefix = "triad-behavior-"
  BehaviorLogSuffix = ".jsonl"

proc envFlagEnabled(value: string): bool =
  case value.normalize()
  of "1", "true", "yes", "on":
    true
  else:
    false

proc parsePositiveInt(value: string; fallback: int): int =
  try:
    let parsed = parseInt(value)
    if parsed > 0:
      parsed
    else:
      fallback
  except ValueError:
    fallback

proc behaviorLogEnabled*(): bool =
  getEnv("TRIAD_BEHAVIOR_LOG", "").envFlagEnabled()

proc defaultBehaviorLogDir*(): string =
  let configured = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
  if configured.len > 0:
    return configured

  let stateHome = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  stateHome / "triad" / "behavior"

proc behaviorLogMaxBytes*(): int =
  parsePositiveInt(getEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", ""),
    DefaultMaxBytes)

proc behaviorLogKeepDays*(): int =
  parsePositiveInt(getEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", ""),
    DefaultKeepDays)

proc behaviorLogPath*(day = now().format("yyyy-MM-dd")): string =
  defaultBehaviorLogDir() / (BehaviorLogPrefix & day & BehaviorLogSuffix)

proc cleanupBehaviorLogs(dir: string; keepDays: int) =
  if keepDays <= 0 or not dirExists(dir):
    return

  let cutoff = epochTime() - float(keepDays * 24 * 60 * 60)
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    let name = path.extractFilename()
    if not name.startsWith(BehaviorLogPrefix) or
        not name.endsWith(BehaviorLogSuffix):
      continue
    try:
      if getLastModificationTime(path).toUnix().float < cutoff:
        removeFile(path)
    except CatchableError:
      discard

proc rotateOversizeLog(path: string; maxBytes: int) =
  if maxBytes <= 0 or not fileExists(path):
    return

  try:
    if getFileSize(path) < BiggestInt(maxBytes):
      return

    let split = path.splitFile()
    var rotated = split.dir / (split.name & "-" & now().format("HHmmss") &
      split.ext)
    if fileExists(rotated):
      rotated = split.dir / (split.name & "-" & now().format("HHmmss") &
        "-" & $getCurrentProcessId() & split.ext)
    moveFile(path, rotated)
  except CatchableError:
    discard

proc appendJsonLine(path: string; node: JsonNode) =
  var file: File
  if file.open(path, fmAppend):
    try:
      file.writeLine($node)
    finally:
      file.close()

proc behaviorEventRoot(eventName: string): JsonNode =
  result = newJObject()
  result["ts_unix_ms"] = %int64(epochTime() * 1000.0)
  result["event"] = %eventName
  result["pid"] = %getCurrentProcessId()

proc writeBehaviorEvent*(eventName: string; payload: JsonNode = nil) =
  if not behaviorLogEnabled():
    return

  let dir = defaultBehaviorLogDir()
  try:
    createDir(dir)
    cleanupBehaviorLogs(dir, behaviorLogKeepDays())
    let path = behaviorLogPath()
    rotateOversizeLog(path, behaviorLogMaxBytes())

    let event = behaviorEventRoot(eventName)
    if payload != nil and payload.kind == JObject:
      for key, value in payload.pairs:
        event[key] = value
    appendJsonLine(path, event)
  except CatchableError:
    discard

proc compactFocusHistory(state: LiveRestoreState): JsonNode =
  result = newJArray()
  for winId in state.focusHistory:
    result.add(%uint32(winId))

proc compactLiveRestoreWindows(state: LiveRestoreState): JsonNode =
  result = newJArray()
  var winIds: seq[WindowId]
  for winId in state.windows.keys:
    winIds.add(winId)
  winIds.sort()

  for winId in winIds:
    let win = state.windows[winId]
    result.add(%*{
      "id": uint32(winId),
      "tag_id": win.tagId,
      "app_id": win.appId,
      "title": win.title,
      "is_floating": win.isFloating,
      "is_fullscreen": win.isFullscreen,
      "is_maximized": win.isMaximized
    })

proc compactLiveRestoreTags(state: LiveRestoreState): JsonNode =
  result = newJArray()
  var tagIds: seq[uint32]
  for tagId in state.tags.keys:
    tagIds.add(tagId)
  tagIds.sort()

  for tagId in tagIds:
    let tag = state.tags[tagId]
    result.add(%*{
      "id": tag.tagId,
      "layout_mode": $tag.layoutMode,
      "focused_window": uint32(tag.focusedWindow),
      "columns": tag.columns.len
    })

proc liveRestoreSummary*(state: LiveRestoreState): JsonNode =
  %*{
    "active_tag": state.activeTag,
    "focused_window": uint32(state.focusedWindow),
    "windows": compactLiveRestoreWindows(state),
    "tags": compactLiveRestoreTags(state),
    "focus_history": compactFocusHistory(state)
  }

proc writeLiveRestoreBehaviorEvent*(
    eventName, path, context: string; state: LiveRestoreState) =
  let payload = liveRestoreSummary(state)
  payload["path"] = %path
  if context.len > 0:
    payload["context"] = %context
  writeBehaviorEvent(eventName, payload)
