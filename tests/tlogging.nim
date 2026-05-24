import std/[asyncdispatch, json, options, os, strutils, times, unittest]
import chronicles
import ../src/config/parser
import ../src/core/msg
import ../src/ipc/[niri_compat, socket]
import ../src/session/logs as session_logs
import ../src/systems/[runtime_facade, update]
import ../src/types/runtime_values
import ../src/utils/[behavior_log, runtime_log]

proc restoreEnv(name, value: string) =
  putEnv(name, value)

proc behaviorLogFiles(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.extractFilename().startsWith("triad-behavior-"):
      result.add(path)

suite "Runtime logging":
  test "session metadata renders live log paths":
    let dir = getTempDir() / ("triad-session-logs-" & $getCurrentProcessId())
    createDir(dir)
    defer:
      if dirExists(dir):
        removeDir(dir)

    let record = SessionLogRecord(
      claimId: "claim-1",
      sessionId: "session-1",
      sessionPid: 11,
      supervisorPid: 12,
      daemonPid: 13,
      stateDir: dir,
      sessionLog: dir / "triad-session-session-1.log",
      daemonLog: dir / "triad-session-1.log",
      startedAt: "2026-05-23T12:00:00-04:00",
      supervisorProtocol: SupervisorProtocolVersion,
    )
    let claim = claimSessionRecord(currentSessionPath(dir), record)

    let payload = session_logs.logsJson(dir)
    check payload["ok"].getBool()
    check payload["session"]["session_id"].getStr() == "session-1"
    check renderLogs(dir).contains("daemon log: " & record.daemonLog)

    restoreSessionRecord(claim)
    check not session_logs.logsJson(dir)["ok"].getBool()

  test "session symlink claims restore previous target":
    let dir = getTempDir() / ("triad-session-symlinks-" & $getCurrentProcessId())
    createDir(dir)
    defer:
      if dirExists(dir):
        removeDir(dir)

    let oldTarget = dir / "old.log"
    let newTarget = dir / "new.log"
    let linkPath = dir / "triad-latest.log"
    writeFile(oldTarget, "old")
    writeFile(newTarget, "new")

    check replaceSymlink(oldTarget, linkPath)
    let claim = claimSymlink(newTarget, linkPath)
    check symlinkTarget(linkPath) == newTarget

    restoreSymlink(claim)
    check symlinkTarget(linkPath) == oldTarget

  test "parses supported log levels":
    check parseLogLevel("trace").get() == TRACE
    check parseLogLevel("DEBUG").get() == DEBUG
    check parseLogLevel("info").get() == INFO
    check parseLogLevel("notice").get() == NOTICE
    check parseLogLevel("warning").get() == WARN
    check parseLogLevel("error").get() == ERROR
    check parseLogLevel("fatal").get() == FATAL

  test "rejects invalid log levels":
    check parseLogLevel("").isNone
    check parseLogLevel("verbose").isNone
    check parseLogLevel("everything").isNone

  test "behavior log stays quiet when disabled":
    let dir = getTempDir() / ("triad-behavior-disabled-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    writeBehaviorEvent("disabled_test", %*{"value": 1})

    check behaviorLogFiles(dir).len == 0

  test "behavior log writes valid jsonl when enabled":
    let dir = getTempDir() / ("triad-behavior-enabled-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    writeBehaviorEvent("enabled_test", %*{"value": 7})

    let path = behaviorLogPath()
    check fileExists(path)
    let lines = readFile(path).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "enabled_test"
    check event["value"].getInt() == 7
    check event.hasKey("ts_unix_ms")
    check event.hasKey("pid")

  test "runtime loop behavior sample is aggregated":
    let source = readFile("src/daemon/app.nim")
    let renderStart = source.find("if msg.kind == MsgKind.WlRenderStart:")
    let cmdTick = source.find("if msg.kind == MsgKind.CmdTick:")
    let sampleWrite = source.find("writeBehaviorEvent(\n    \"runtime_loop_sample\"")

    check source.contains("RuntimeLoopSampleIntervalMs = 1_000")
    check source.count("\"runtime_loop_sample\"") == 1
    check source.contains("\"frame_tick_reason_counts\"")
    check source.contains("incrementFrameTickReasonCounts")
    check source.contains("nowMs - lastMotion >= delay")
    check source.contains("reason != \"recent-focus\"")
    check source.contains("AnimationTickIntervalMs = int64(DefaultFrameIntervalMs)")
    check source.contains("manageReason == AnimationManageReason")
    check source.contains("\"recent_delta\"")
    check source.contains("\"ipc_counters\"")
    check source.contains("\"skipped_animation_manages\"")
    check source.contains("\"skipped_noop_manages\"")
    check source.contains("\"skipped_dimension_proposals\"")
    check renderStart >= 0
    check cmdTick > renderStart
    check sampleWrite >= 0
    check sampleWrite < renderStart

  test "high frequency tick updates avoid full snapshots and rule refresh":
    let updateSource = readFile("src/systems/update.nim")
    let appSource = readFile("src/daemon/app.nim")

    check updateSource.contains("cmdTickMayChangeFocus")
    check not updateSource.contains(
      "msg.kind.needsFullSnapshotAlways() or msg.kind == MsgKind.CmdTick"
    )
    check updateSource.contains(
      "dirty and msg.kind != MsgKind.CmdTick and model.windowRuleStateMatchersEnabled()"
    )
    check updateSource.contains("MsgKind.WlWindowTitle, MsgKind.CmdTick")
    check appSource.contains("AnimationManageReason")
    check appSource.contains("if msg.kind == MsgKind.CmdTick:")

  test "dev mode enables behavior logging unless explicitly overridden":
    let oldDevMode = getEnv("TRIAD_DEV_MODE", "")
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    defer:
      restoreEnv("TRIAD_DEV_MODE", oldDevMode)
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)

    putEnv("TRIAD_DEV_MODE", "")
    putEnv("TRIAD_BEHAVIOR_LOG", "")
    configureDevMode(@["--dev-mode"])

    check devModeEnabled()
    check behaviorLogEnabled()

    putEnv("TRIAD_DEV_MODE", "")
    putEnv("TRIAD_BEHAVIOR_LOG", "0")
    configureDevMode(@["--dev-mode"])

    check devModeEnabled()
    check not behaviorLogEnabled()

    putEnv("TRIAD_DEV_MODE", "1")
    putEnv("TRIAD_BEHAVIOR_LOG", "")
    configureDevMode(@[])

    check devModeEnabled()
    check behaviorLogEnabled()

  test "runtime dev mode toggles behavior logging live":
    let oldDevMode = getEnv("TRIAD_DEV_MODE", "")
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    defer:
      restoreEnv("TRIAD_DEV_MODE", oldDevMode)
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)

    setRuntimeDevMode(true)
    check devModeEnabled()
    check behaviorLogEnabled()

    setRuntimeDevMode(false)
    check not devModeEnabled()
    check not behaviorLogEnabled()

    toggleRuntimeDevMode()
    check devModeEnabled()
    check behaviorLogEnabled()

  test "live reload dev mode marker is one-shot":
    let path = getTempDir() / ("triad-live-dev-mode-" & $getCurrentProcessId())
    let oldDevMode = getEnv("TRIAD_DEV_MODE", "")
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    defer:
      restoreEnv("TRIAD_DEV_MODE", oldDevMode)
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      if fileExists(path):
        removeFile(path)

    putEnv("TRIAD_DEV_MODE", "")
    putEnv("TRIAD_BEHAVIOR_LOG", "")
    check markLiveReloadDevMode(path)
    check fileExists(path)
    check consumeLiveReloadDevMode(path)
    configureDevMode(@[])
    check devModeEnabled()
    check behaviorLogEnabled()
    check not fileExists(path)
    putEnv("TRIAD_DEV_MODE", "")
    check not consumeLiveReloadDevMode(path)

  test "runtime update behavior event records workspace transition":
    let dir = getTempDir() / ("triad-behavior-runtime-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    let model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 3))
    ).model
    discard model.update(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))

    var events: seq[JsonNode]
    for line in readFile(behaviorLogPath()).strip().splitLines():
      let event = parseJson(line)
      if event["event"].getStr() == "runtime_update":
        events.add(event)
    check events.len == 1
    let event = events[0]
    check event["event"].getStr() == "runtime_update"
    check event["kind"].getStr() == "CmdFocusWorkspaceIndex"
    check event["after"]["active_tag"].getInt() == 2
    check event["after"]["layout_mode"].getStr() == "scroller"
    check event["after"].hasKey("workspace_distribution")
    check not event.hasKey("window_states")
    check event["tracked_windows"]["after"].kind == JArray

  test "runtime update behavior event records window birth and app id":
    let dir = getTempDir() / ("triad-behavior-window-birth-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    var model = initRuntimeStateFromConfig(
      Config(workspaces: WorkspaceConfig(defaultCount: 1))
    ).model
    let created = Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 42,
      createdParentWindowId: 0,
      createdSwallowHostWindowId: 0,
      createdPid: 123'i32,
      appId: "",
      title: "Opening",
      createdIdentifier: "",
      deferAdmission: false,
    )
    let (afterCreated, _) = model.update(created)
    model = afterCreated
    discard model.update(
      Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: 42, updatedAppId: "gimp")
    )

    var events: seq[JsonNode]
    for line in readFile(behaviorLogPath()).strip().splitLines():
      let event = parseJson(line)
      if event["event"].getStr() == "runtime_update":
        events.add(event)
    check events.len == 2
    let birth = events[0]
    check birth["event"].getStr() == "runtime_update"
    check birth["kind"].getStr() == "WlWindowCreated"
    check birth["tracked_windows"]["after"][0]["id"].getInt() == 42
    let appId = events[1]
    check appId["event"].getStr() == "runtime_update"
    check appId["kind"].getStr() == "WlWindowAppId"
    check appId["tracked_windows"]["after"][0]["app_id"].getStr() == "gimp"

  test "runtime update behavior event records layout transition":
    let dir = getTempDir() / ("triad-behavior-layout-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    let model = initRuntimeStateFromConfig(
      Config(
        layout:
          LayoutConfig(layoutCycle: @[LayoutMode.Scroller, LayoutMode.MasterStack])
      )
    ).model
    discard model.update(Msg(kind: MsgKind.CmdSwitchLayout))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "runtime_update"
    check event["kind"].getStr() == "CmdSwitchLayout"
    check event["before"]["layout_mode"].getStr() == "scroller"
    check event["after"]["layout_mode"].getStr() == "tile"
    check event["layout_transition"]["before"].getStr() == "scroller"
    check event["layout_transition"]["after"].getStr() == "tile"
    check event["layout_transition"]["active_tag_before"].getInt() == 1
    check event["layout_transition"]["active_tag_after"].getInt() == 1

  test "layout projection behavior event records generated geometry":
    let dir = getTempDir() / ("triad-behavior-projection-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    var state = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 0), workspaces: WorkspaceConfig(defaultCount: 3)
      )
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "One")
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Two")
    )
    discard state.applyRuntimeLayoutProjection("test render", "CmdSwitchLayout")

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len >= 1
    let event = parseJson(lines[^1])
    check event["event"].getStr() == "layout_projection"
    check event["context"].getStr() == "test render"
    check event["msg_kind"].getStr() == "CmdSwitchLayout"
    check event["active_tag"].getInt() == 1
    check event["layout_mode"].getStr() == "scroller"
    check event["instruction_count"].getInt() == 2
    check event["instructions"].kind == JArray
    check event["instructions"][0].hasKey("window_id")
    check event["instructions"][0]["geom"]["w"].getInt() > 0
    check event["instructions"][0]["geom"]["h"].getInt() > 0
    check event["viewport_targets"].kind == JArray

  test "overview projection behavior event suppresses instruction payload":
    let dir =
      getTempDir() / ("triad-behavior-overview-projection-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    let oldFull = getEnv("TRIAD_BEHAVIOR_LOG_FULL_PROJECTIONS", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      restoreEnv("TRIAD_BEHAVIOR_LOG_FULL_PROJECTIONS", oldFull)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    putEnv("TRIAD_BEHAVIOR_LOG_FULL_PROJECTIONS", "")
    var state = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 0), workspaces: WorkspaceConfig(defaultCount: 2)
      )
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "One")
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Two")
    )
    discard state.applyRuntimeUpdate(Msg(kind: MsgKind.CmdOpenOverview))
    discard state.applyRuntimeLayoutProjection("overview render", "CmdOpenOverview")

    var projectionEvents: seq[JsonNode] = @[]
    for line in readFile(behaviorLogPath()).strip().splitLines():
      let event = parseJson(line)
      if event["event"].getStr() == "layout_projection":
        projectionEvents.add(event)

    check projectionEvents.len == 1
    let event = projectionEvents[0]
    check event["overview_active"].getBool()
    check event["instruction_count"].getInt() > 0
    check event["instructions_suppressed"].getBool()
    check not event.hasKey("instructions")
    check event["viewport_targets"].kind == JArray

  test "layout projection behavior event suppresses identical repeats":
    let dir =
      getTempDir() / ("triad-behavior-projection-dedupe-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    var state = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(gaps: 0), workspaces: WorkspaceConfig(defaultCount: 1)
      )
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 11, appId: "app", title: "One")
    )

    discard state.applyRuntimeLayoutProjection("render layout", "WlRenderStart")
    discard state.applyRuntimeLayoutProjection("render layout", "WlRenderStart")
    discard state.applyRuntimeLayoutProjection("manage layout", "WlManageStart")
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 12, appId: "app", title: "Two")
    )
    discard state.applyRuntimeLayoutProjection("manage layout", "WlManageStart")

    var projectionEvents: seq[JsonNode] = @[]
    for line in readFile(behaviorLogPath()).strip().splitLines():
      let event = parseJson(line)
      if event["event"].getStr() == "layout_projection":
        projectionEvents.add(event)

    check projectionEvents.len == 2
    check not projectionEvents[0].hasKey("suppressed_count")
    check projectionEvents[1]["suppressed_count"].getInt() == 2

  test "runtime update behavior event records window state effects":
    let dir = getTempDir() / ("triad-behavior-effects-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    var model = initRuntimeStateFromConfig(Config()).model
    (model, _) = model.update(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: 9,
        appId: "sublime_text",
        title: "Sublime Text",
      )
    )
    discard
      model.update(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: 9))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len >= 1
    let event = parseJson(lines[^1])
    check event["event"].getStr() == "runtime_update"
    check event["kind"].getStr() == "WlWindowMaximizeRequested"
    check event["tracked_windows"]["after"][0]["id"].getInt() == 9
    check event["tracked_windows"]["after"][0]["maximized"].getBool()
    var maxEffect = newJNull()
    for effect in event["effects"]:
      if effect["kind"].getStr() == "EffSetMaximized":
        maxEffect = effect
    check maxEffect.kind != JNull
    check maxEffect["window_id"].getInt() == 9
    check maxEffect["maximized"].getBool()

  test "runtime update behavior event records session lock transition":
    let dir = getTempDir() / ("triad-behavior-session-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    var model = initRuntimeStateFromConfig(Config()).model
    (model, _) = model.update(Msg(kind: MsgKind.WlSessionLocked))
    discard model.update(Msg(kind: MsgKind.WlSessionUnlocked))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 2
    let locked = parseJson(lines[0])
    let unlocked = parseJson(lines[1])
    check locked["event"].getStr() == "runtime_update"
    check locked["kind"].getStr() == "WlSessionLocked"
    check not locked["before"]["session_locked"].getBool()
    check locked["after"]["session_locked"].getBool()
    check unlocked["kind"].getStr() == "WlSessionUnlocked"
    check unlocked["before"]["session_locked"].getBool()
    check not unlocked["after"]["session_locked"].getBool()

  test "niri broadcast behavior event records compact shell events":
    let dir = getTempDir() / ("triad-behavior-broadcast-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    waitFor broadcastJson(
      $(
        %*{
          "WorkspacesChanged": {
            "workspaces": [
              {"id": 2, "idx": 2, "is_active": false, "is_focused": true},
              {"id": 3, "idx": 3, "is_active": true, "is_focused": false},
            ]
          }
        }
      )
    )
    waitFor broadcastJson($(%*{"WorkspaceActivated": {"id": 2, "focused": true}}))
    waitFor broadcastJson(
      $(%*{"WorkspaceActiveWindowChanged": {"workspace_id": 2, "active_window_id": 20}})
    )
    waitFor broadcastJson($(%*{"WindowFocusChanged": {"id": 20}}))
    waitFor broadcastJson($(%*{"WindowFocusChanged": {"id": 20}}))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 4
    let workspacesEvent = parseJson(lines[0])
    check workspacesEvent["event"].getStr() == "niri_compat_broadcast"
    check workspacesEvent["niri_event"].getStr() == "WorkspacesChanged"
    check workspacesEvent["active_tag"].getInt() == 2
    check workspacesEvent.hasKey("workspace_distribution")
    check workspacesEvent.hasKey("workspace_signature")

    let activatedEvent = parseJson(lines[1])
    check activatedEvent["niri_event"].getStr() == "WorkspaceActivated"
    check activatedEvent["id"].getInt() == 2
    check activatedEvent["focused"].getBool()

    let activeWindowEvent = parseJson(lines[2])
    check activeWindowEvent["niri_event"].getStr() == "WorkspaceActiveWindowChanged"
    check activeWindowEvent["workspace_id"].getInt() == 2
    check activeWindowEvent["active_window_id"].getInt() == 20

    let focusEvent = parseJson(lines[3])
    check focusEvent["niri_event"].getStr() == "WindowFocusChanged"
    check focusEvent["window_id"].getInt() == 20

  test "native Triad broadcast dedupes per event stream":
    let marker = "triad-broadcast-dedupe-" & $getCurrentProcessId()
    let layoutPayload =
      $(%*{"triad": {"event": "layout-state-changed", "marker": marker}})
    let statePayload = $(%*{"triad": {"event": "state-changed", "marker": marker}})
    let before = ipcPerfCounters

    waitFor broadcastTriadJson(layoutPayload, "layout")
    waitFor broadcastTriadJson(statePayload, "state")
    waitFor broadcastTriadJson(layoutPayload, "layout")
    waitFor broadcastTriadJson(statePayload, "state")

    check ipcPerfCounters.triadBroadcasts - before.triadBroadcasts == 2
    check ipcPerfCounters.triadBroadcastSkippedDuplicate -
      before.triadBroadcastSkippedDuplicate == 2
    check ipcPerfCounters.triadBroadcastSkippedDuplicateByEvent -
      before.triadBroadcastSkippedDuplicateByEvent == 2

  test "niri broadcast send filter allows incremental live window events":
    check shouldSendNiriBroadcast(
      $(%*{"WindowOpenedOrChanged": {"window": {"id": 20, "title": "loading"}}})
    )
    check shouldSendNiriBroadcast($(%*{"WindowFocusChanged": {"id": 20}}))
    check shouldSendNiriBroadcast(
      $(%*{"WorkspaceActiveWindowChanged": {"workspace_id": 2, "active_window_id": 20}})
    )
    check not shouldSendNiriBroadcast($(%*{"WindowsChanged": {"windows": []}}))
    check not shouldSendNiriBroadcast($(%*{"WindowLayoutsChanged": {"changes": []}}))

  test "niri request behavior payload records sanitized action details":
    let payload = niriRequestLogPayload(
      "/run/user/1000/triad-niri.sock",
      NiriIpcResult(
        handled: true,
        requestKind: "action",
        actionName: "FocusWorkspace",
        workspaceIndex: 3,
        reply: """{"Ok":"Handled"}""",
        messages: @[Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3)],
      ),
    )

    check payload["request_kind"].getStr() == "action"
    check payload["action"].getStr() == "FocusWorkspace"
    check payload["workspace_idx"].getInt() == 3
    check payload["reply_kind"].getStr() == "Handled"
    check payload["message_kinds"][0].getStr() == "CmdFocusWorkspaceIndex"
    check not payload.hasKey("raw")

  test "behavior log rotates oversized day file and cleans old logs":
    let dir = getTempDir() / ("triad-behavior-rotate-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    let oldMax = getEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", "")
    let oldKeep = getEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      restoreEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", oldMax)
      restoreEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", oldKeep)
      if dirExists(dir):
        removeDir(dir)

    createDir(dir)
    let stale = dir / "triad-behavior-2000-01-01.jsonl"
    writeFile(stale, "{}\n")
    setLastModificationTime(stale, fromUnix(0))
    let today = now().format("yyyy-MM-dd")
    let oldToday1 = dir / ("triad-behavior-" & today & "-000001.jsonl")
    let oldToday2 = dir / ("triad-behavior-" & today & "-000002.jsonl")
    writeFile(oldToday1, repeat("a", 80))
    writeFile(oldToday2, repeat("b", 80))
    setLastModificationTime(oldToday1, fromUnix(epochTime().int64 - 10))
    setLastModificationTime(oldToday2, fromUnix(epochTime().int64 - 5))

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    putEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", "100")
    putEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", "1")
    writeBehaviorEvent("rotate_test", %*{"payload": repeat("x", 80)})
    writeBehaviorEvent("rotate_test", %*{"payload": repeat("y", 80)})

    check not fileExists(stale)
    check not fileExists(oldToday1)
    check not fileExists(oldToday2)
    check behaviorLogFiles(dir).len >= 2
