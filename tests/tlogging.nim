import std/[asyncdispatch, json, options, os, strutils, times, unittest]
import chronicles
import ../src/config/parser
import ../src/core/msg
import ../src/ipc/socket
import ../src/systems/[runtime_facade, update]
import ../src/types/runtime_values
import ../src/utils/[behavior_log, runtime_log]

proc restoreEnv(name, value: string) =
  putEnv(name, value)

proc behaviorLogFiles(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.extractFilename().startsWith(
        "triad-behavior-"):
      result.add(path)

suite "Runtime logging":
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
    let dir = getTempDir() / ("triad-behavior-disabled-" &
      $getCurrentProcessId())
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
    let dir = getTempDir() / ("triad-behavior-enabled-" &
      $getCurrentProcessId())
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

  test "runtime update behavior event records workspace transition":
    let dir = getTempDir() / ("triad-behavior-runtime-" &
      $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    let model = initRuntimeStateFromConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 3))).model
    discard model.update(Msg(kind: MsgKind.CmdFocusWorkspaceIndex,
      workspaceIndex: 2))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "runtime_update"
    check event["kind"].getStr() == "CmdFocusWorkspaceIndex"
    check event["after"]["active_tag"].getInt() == 2

  test "runtime update behavior event records window state effects":
    let dir = getTempDir() / ("triad-behavior-effects-" &
      $getCurrentProcessId())
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
    (model, _) = model.update(Msg(kind: MsgKind.WlWindowCreated,
      windowId: 9,
      appId: "sublime_text",
      title: "Sublime Text"))
    discard model.update(Msg(kind: MsgKind.WlWindowMaximizeRequested,
      maximizeRequestId: 9))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "runtime_update"
    check event["kind"].getStr() == "WlWindowMaximizeRequested"
    check event["tracked_windows"]["after"][0]["id"].getInt() == 9
    check event["tracked_windows"]["after"][0]["maximized"].getBool()
    check event["effects"][0]["kind"].getStr() == "EffSetMaximized"
    check event["effects"][0]["window_id"].getInt() == 9
    check event["effects"][0]["maximized"].getBool()

  test "niri broadcast behavior event records active workspace":
    let dir = getTempDir() / ("triad-behavior-broadcast-" &
      $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    defer:
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    waitFor broadcastJson($(%*{
      "WorkspacesChanged": {
        "workspaces": [
          {"id": 1, "idx": 1, "is_active": false},
          {"id": 2, "idx": 2, "is_active": true}
        ]
      }
    }))

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "niri_compat_broadcast"
    check event["niri_event"].getStr() == "WorkspacesChanged"
    check event["active_tag"].getInt() == 2

  test "behavior log rotates oversized day file and cleans old logs":
    let dir = getTempDir() / ("triad-behavior-rotate-" &
      $getCurrentProcessId())
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

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    putEnv("TRIAD_BEHAVIOR_LOG_MAX_BYTES", "40")
    putEnv("TRIAD_BEHAVIOR_LOG_KEEP_DAYS", "1")
    writeBehaviorEvent("rotate_test", %*{"payload": repeat("x", 80)})
    writeBehaviorEvent("rotate_test", %*{"payload": repeat("y", 80)})

    check not fileExists(stale)
    check behaviorLogFiles(dir).len >= 2
