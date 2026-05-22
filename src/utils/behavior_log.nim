import std/[algorithm, hashes, json, options, os, strutils, tables, times]
import ../core/layout_mode_codec
import ../core/restore_state
from ../types/core import Rect
import ../types/layout_projection
from ../types/projection_values import RenderInstruction
import ../types/shell_snapshot
import ../types/runtime_values

const
  DefaultMaxBytes* = 5 * 1024 * 1024
  DefaultKeepDays* = 7
  LogMaintenanceIntervalMs = 60_000'i64
  LogRotationCheckIntervalMs = 1_000'i64
  DevModeEnv* = "TRIAD_DEV_MODE"
  BehaviorLogEnv* = "TRIAD_BEHAVIOR_LOG"
  FullProjectionLogEnv* = "TRIAD_BEHAVIOR_LOG_FULL_PROJECTIONS"
  LiveReloadDevModeMarker* = "triad-live-dev-mode"
  BehaviorLogPrefix = "triad-behavior-"
  BehaviorLogSuffix = ".jsonl"

var
  lastCleanupMs = 0'i64
  lastCleanupDir = ""
  lastRotationCheckMs = 0'i64
  lastRotationPath = ""
  bytesSinceRotationCheck = 0
  lastLayoutProjectionLogPath = ""
  lastLayoutProjectionSignature = 0.Hash
  lastLayoutProjectionSignatureSet = false
  suppressedLayoutProjectionCount = 0

type BehaviorLogFile = object
  path: string
  day: string
  modified: Time
  size: BiggestInt
  active: bool

proc envFlagEnabled*(value: string): bool =
  case value.normalize()
  of "1", "true", "yes", "on": true
  else: false

proc parsePositiveInt(value: string, fallback: int): int =
  try:
    let parsed = parseInt(value)
    if parsed > 0: parsed else: fallback
  except ValueError:
    fallback

proc behaviorLogEnabled*(): bool =
  getEnv(BehaviorLogEnv, "").envFlagEnabled()

proc fullProjectionLogEnabled*(): bool =
  getEnv(FullProjectionLogEnv, "").envFlagEnabled()

proc devModeEnabled*(): bool =
  getEnv(DevModeEnv, "").envFlagEnabled()

proc argsEnableDevMode*(args: openArray[string]): bool =
  for arg in args:
    if arg == "--dev-mode":
      return true
  false

proc configureDevMode*(args: openArray[string]) =
  if args.argsEnableDevMode() or devModeEnabled():
    putEnv(DevModeEnv, "1")
    if getEnv(BehaviorLogEnv, "").len == 0:
      putEnv(BehaviorLogEnv, "1")

proc defaultLiveReloadDevModePath*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp") / LiveReloadDevModeMarker

proc markLiveReloadDevMode*(path = defaultLiveReloadDevModePath()): bool =
  if path.len == 0:
    return false
  try:
    createDir(path.parentDir())
    writeFile(path, "1\n")
    true
  except CatchableError:
    false

proc consumeLiveReloadDevMode*(path = defaultLiveReloadDevModePath()): bool =
  if not fileExists(path):
    return false
  try:
    removeFile(path)
  except CatchableError:
    discard
  putEnv(DevModeEnv, "1")
  true

proc setRuntimeDevMode*(enabled: bool) =
  if enabled:
    putEnv(DevModeEnv, "1")
    putEnv(BehaviorLogEnv, "1")
  else:
    putEnv(DevModeEnv, "0")
    putEnv(BehaviorLogEnv, "0")

proc toggleRuntimeDevMode*() =
  setRuntimeDevMode(not devModeEnabled())

proc defaultBehaviorLogDir*(): string =
  let configured = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
  if configured.len > 0:
    return configured

  let stateHome = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  stateHome / "triad" / "behavior"

proc behaviorLogMaxBytes*(): int =
  parsePositiveInt(getEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", ""), DefaultMaxBytes)

proc behaviorLogKeepDays*(): int =
  parsePositiveInt(getEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", ""), DefaultKeepDays)

proc behaviorLogPath*(day = now().format("yyyy-MM-dd")): string =
  defaultBehaviorLogDir() / (BehaviorLogPrefix & day & BehaviorLogSuffix)

proc behaviorLogDay(name: string): string =
  if not name.startsWith(BehaviorLogPrefix) or not name.endsWith(BehaviorLogSuffix):
    return ""

  let stem = name[BehaviorLogPrefix.len ..< name.len - BehaviorLogSuffix.len]
  if stem.len < 10:
    return ""
  stem[0 .. 9]

proc isActiveBehaviorLog(name, day: string): bool =
  name == BehaviorLogPrefix & day & BehaviorLogSuffix

proc cleanupBehaviorLogs(dir: string, keepDays, maxBytes: int) =
  if keepDays <= 0 or not dirExists(dir):
    return

  let cutoff = epochTime() - float(keepDays * 24 * 60 * 60)
  var filesByDay = initTable[string, seq[BehaviorLogFile]]()
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    let name = path.extractFilename()
    let day = behaviorLogDay(name)
    if day.len == 0:
      continue
    try:
      let modified = getLastModificationTime(path)
      if modified.toUnix().float < cutoff:
        removeFile(path)
        continue
      if not filesByDay.hasKey(day):
        filesByDay[day] = @[]
      filesByDay[day].add(
        BehaviorLogFile(
          path: path,
          day: day,
          modified: modified,
          size: getFileSize(path),
          active: name.isActiveBehaviorLog(day),
        )
      )
    except CatchableError:
      discard

  if maxBytes <= 0:
    return

  for day, files in filesByDay.mpairs:
    files.sort(
      proc(a, b: BehaviorLogFile): int =
        if a.active != b.active:
          if a.active:
            return -1
          return 1
        cmp(b.modified.toUnix(), a.modified.toUnix())
    )

    var keptBytes: BiggestInt = 0
    for file in files:
      let keep =
        file.active or keptBytes == 0 or keptBytes + file.size <= BiggestInt(maxBytes)
      if keep:
        keptBytes += file.size
      else:
        try:
          removeFile(file.path)
        except CatchableError:
          discard

proc rotateOversizeLog(path: string, maxBytes: int) =
  if maxBytes <= 0 or not fileExists(path):
    return

  try:
    if getFileSize(path) < BiggestInt(maxBytes):
      return

    let split = path.splitFile()
    var rotated = split.dir / (split.name & "-" & now().format("HHmmss") & split.ext)
    if fileExists(rotated):
      rotated =
        split.dir / (
          split.name & "-" & now().format("HHmmss") & "-" & $getCurrentProcessId() &
          split.ext
        )
    moveFile(path, rotated)
  except CatchableError:
    discard

proc currentUnixMs(): int64 =
  int64(epochTime() * 1000.0)

proc appendJsonLine(path: string, line: string) =
  var file: File
  if file.open(path, fmAppend):
    try:
      file.writeLine(line)
    finally:
      file.close()

proc behaviorEventRoot(eventName: string): JsonNode =
  result = newJObject()
  result["ts_unix_ms"] = %int64(epochTime() * 1000.0)
  result["event"] = %eventName
  result["pid"] = %getCurrentProcessId()

proc writeBehaviorEvent*(eventName: string, payload: JsonNode = nil) =
  if not behaviorLogEnabled():
    return

  let dir = defaultBehaviorLogDir()
  try:
    createDir(dir)
    let nowMs = currentUnixMs()
    let maxBytes = behaviorLogMaxBytes()
    if dir != lastCleanupDir or nowMs - lastCleanupMs >= LogMaintenanceIntervalMs:
      cleanupBehaviorLogs(dir, behaviorLogKeepDays(), maxBytes)
      lastCleanupDir = dir
      lastCleanupMs = nowMs
    let path = behaviorLogPath()

    let event = behaviorEventRoot(eventName)
    if payload != nil and payload.kind == JObject:
      for key, value in payload.pairs:
        event[key] = value

    let line = $event
    if path != lastRotationPath:
      bytesSinceRotationCheck = 0
      lastRotationPath = path
      lastRotationCheckMs = 0
    bytesSinceRotationCheck += line.len + 1
    if bytesSinceRotationCheck >= maxBytes or
        nowMs - lastRotationCheckMs >= LogRotationCheckIntervalMs:
      rotateOversizeLog(path, maxBytes)
      cleanupBehaviorLogs(dir, behaviorLogKeepDays(), maxBytes)
      lastRotationCheckMs = nowMs
      bytesSinceRotationCheck = 0

    appendJsonLine(path, line)
  except CatchableError:
    discard

proc behaviorLayoutId*(mode: LayoutMode): string =
  mode.layoutModeId()

proc activeWorkspaceLayoutId*(snapshot: ShellSnapshot): string =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return workspace.layoutId
  ""

proc rectBehaviorPayload*(rect: Rect): JsonNode =
  %*{"x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h}

proc compactRenderInstructions*(instructions: openArray[RenderInstruction]): JsonNode =
  result = newJArray()
  for instr in instructions:
    let node =
      %*{"window_id": uint32(instr.windowId), "geom": instr.geom.rectBehaviorPayload()}
    if instr.clipSet:
      node["clip"] = instr.clip.rectBehaviorPayload()
    result.add(node)

proc compactViewportTargets*(targets: openArray[LayoutViewportTarget]): JsonNode =
  result = newJArray()
  for target in targets:
    result.add(
      %*{"tag": target.tagSlot, "target_x": target.targetX, "target_y": target.targetY}
    )

proc compactWorkspaceDistribution*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for workspace in snapshot.workspaces:
    var maximized = 0
    var fullscreen = 0
    var floating = 0
    for win in snapshot.windows:
      if win.tagId.isNone or win.tagId.get() != workspace.tagId:
        continue
      if win.isMaximized:
        inc maximized
      if win.isFullscreen:
        inc fullscreen
      if win.isFloating:
        inc floating
    result.add(
      %*{
        "tag_id": workspace.tagId,
        "workspace_idx": workspace.workspaceIdx,
        "name": workspace.name,
        "layout_mode": workspace.layoutMode.behaviorLayoutId(),
        "active": workspace.isActive,
        "occupied": workspace.occupied,
        "focused_window": uint32(workspace.focusedWindow),
        "columns": workspace.columns.len,
        "maximized_windows": maximized,
        "fullscreen_windows": fullscreen,
        "floating_windows": floating,
      }
    )

proc compactSnapshotWindows*(snapshot: ShellSnapshot): JsonNode =
  result = newJArray()
  for win in snapshot.windows:
    let node =
      %*{
        "id": uint32(win.id),
        "workspace_idx": win.workspaceIdx,
        "focused": win.isFocused,
        "floating": win.isFloating,
        "fullscreen": win.isFullscreen,
        "maximized": win.isMaximized,
        "minimized": win.isMinimized,
        "overlay": win.isOverlay,
        "app_id": win.appId,
        "title": win.title,
      }
    node["tag_id"] =
      if win.tagId.isSome:
        %win.tagId.get()
      else:
        newJNull()
    result.add(node)

proc snapshotFocusedWindowId(snapshot: ShellSnapshot): uint32 =
  for win in snapshot.windows:
    if win.isFocused:
      return win.id
  0

proc snapshotSummary*(snapshot: ShellSnapshot): JsonNode =
  %*{
    "active_tag": snapshot.activeTag,
    "active_workspace_idx": snapshot.activeWorkspaceIdx,
    "layout_mode": snapshot.activeWorkspaceLayoutId(),
    "focused_window": uint32(snapshot.snapshotFocusedWindowId()),
    "workspaces": snapshot.workspaces.len,
    "windows": snapshot.windows.len,
    "workspace_distribution": snapshot.compactWorkspaceDistribution(),
  }

proc snapshotBehaviorPayload*(snapshot: ShellSnapshot): JsonNode =
  let payload = snapshot.snapshotSummary()
  payload["window_states"] = snapshot.compactSnapshotWindows()
  payload

proc layoutProjectionBehaviorPayload*(
    snapshot: ShellSnapshot, projection: LayoutProjection, context = "", msgKind = ""
): JsonNode =
  result = newJObject()
  result["active_tag"] = %snapshot.activeTag
  result["active_workspace_idx"] = %snapshot.activeWorkspaceIdx
  result["layout_mode"] = %snapshot.activeWorkspaceLayoutId()
  result["focused_window"] = %uint32(snapshot.snapshotFocusedWindowId())
  result["overview_active"] = %snapshot.overviewActive
  result["active_scratchpad_window"] = %uint32(snapshot.activeScratchpadWindow)
  result["instruction_count"] = %projection.instructions.len
  if snapshot.overviewActive and not fullProjectionLogEnabled():
    result["instructions_suppressed"] = %true
  else:
    result["instructions"] = projection.instructions.compactRenderInstructions()
  result["viewport_targets"] = projection.viewportTargets.compactViewportTargets()
  if context.len > 0:
    result["context"] = %context
  if msgKind.len > 0:
    result["msg_kind"] = %msgKind

proc mixProjectionHash(hashValue: var Hash, value: Hash) {.inline.} =
  hashValue = hashValue !& value

proc layoutProjectionSignature(
    snapshot: ShellSnapshot, projection: LayoutProjection
): Hash =
  result.mixProjectionHash(hash(snapshot.activeTag))
  result.mixProjectionHash(hash(snapshot.activeWorkspaceIdx))
  result.mixProjectionHash(hash(snapshot.activeWorkspaceLayoutId()))
  result.mixProjectionHash(hash(snapshot.overviewActive))
  result.mixProjectionHash(hash(uint32(snapshot.snapshotFocusedWindowId())))
  result.mixProjectionHash(hash(projection.instructions.len))
  for instr in projection.instructions:
    result.mixProjectionHash(hash(uint32(instr.windowId)))
    result.mixProjectionHash(hash(instr.geom.x))
    result.mixProjectionHash(hash(instr.geom.y))
    result.mixProjectionHash(hash(instr.geom.w))
    result.mixProjectionHash(hash(instr.geom.h))
    result.mixProjectionHash(hash(instr.clipSet))
    if instr.clipSet:
      result.mixProjectionHash(hash(instr.clip.x))
      result.mixProjectionHash(hash(instr.clip.y))
      result.mixProjectionHash(hash(instr.clip.w))
      result.mixProjectionHash(hash(instr.clip.h))
  result.mixProjectionHash(hash(projection.viewportTargets.len))
  for target in projection.viewportTargets:
    result.mixProjectionHash(hash(target.tagSlot))
    result.mixProjectionHash(hash(target.targetX))
    result.mixProjectionHash(hash(target.targetY))
  result = !$result

proc writeLayoutProjectionBehaviorEvent*(
    snapshot: ShellSnapshot, projection: LayoutProjection, context = "", msgKind = ""
) =
  if not behaviorLogEnabled():
    return
  let path = behaviorLogPath()
  if path != lastLayoutProjectionLogPath:
    lastLayoutProjectionLogPath = path
    lastLayoutProjectionSignature = 0.Hash
    lastLayoutProjectionSignatureSet = false
    suppressedLayoutProjectionCount = 0

  let signature = snapshot.layoutProjectionSignature(projection)
  if lastLayoutProjectionSignatureSet and signature == lastLayoutProjectionSignature:
    inc suppressedLayoutProjectionCount
    return

  let payload = snapshot.layoutProjectionBehaviorPayload(projection, context, msgKind)
  if suppressedLayoutProjectionCount > 0:
    payload["suppressed_count"] = %suppressedLayoutProjectionCount
    suppressedLayoutProjectionCount = 0
  lastLayoutProjectionSignature = signature
  lastLayoutProjectionSignatureSet = true
  writeBehaviorEvent("layout_projection", payload)

proc compactFocusHistory(state: LiveRestoreState): JsonNode =
  result = newJArray()
  for winId in state.focusHistory:
    result.add(%uint32(winId))

proc compactLiveRestoreWindows(state: LiveRestoreState): JsonNode =
  result = newJArray()
  var winIds: seq[uint32]
  for winId in state.windows.keys:
    winIds.add(winId)
  winIds.sort()

  for winId in winIds:
    let win = state.windows[winId]
    result.add(
      %*{
        "id": uint32(winId),
        "tag_id": win.tagId,
        "app_id": win.appId,
        "title": win.title,
        "is_floating": win.isFloating,
        "is_fullscreen": win.isFullscreen,
        "is_maximized": win.isMaximized,
        "is_sticky": win.isSticky,
      }
    )

proc compactLiveRestoreTags(state: LiveRestoreState): JsonNode =
  result = newJArray()
  var tagIds: seq[uint32]
  for tagId in state.tags.keys:
    tagIds.add(tagId)
  tagIds.sort()

  for tagId in tagIds:
    let tag = state.tags[tagId]
    var fullWidthColumns = 0
    for col in tag.columns:
      if col.isFullWidth:
        inc fullWidthColumns
    result.add(
      %*{
        "id": tag.tagId,
        "layout_mode": $tag.layoutMode,
        "focused_window": uint32(tag.focusedWindow),
        "columns": tag.columns.len,
        "full_width_columns": fullWidthColumns,
      }
    )

proc liveRestoreSummary*(state: LiveRestoreState): JsonNode =
  %*{
    "active_tag": state.activeTag,
    "focused_window": uint32(state.focusedWindow),
    "windows": compactLiveRestoreWindows(state),
    "tags": compactLiveRestoreTags(state),
    "focus_history": compactFocusHistory(state),
  }

proc writeLiveRestoreBehaviorEvent*(
    eventName, path, context: string, state: LiveRestoreState
) =
  let payload = liveRestoreSummary(state)
  payload["path"] = %path
  if context.len > 0:
    payload["context"] = %context
  writeBehaviorEvent(eventName, payload)
