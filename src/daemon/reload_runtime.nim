import std/[asyncdispatch, json, options, os, strutils, tables]
import chronicles
import ../config/[defaults, parser]
import ../core/[niri_state, shell_focus, shell_profiles]
import ../ipc/socket
import ../systems/runtime_facade
import ../types/[model, shell_snapshot]
from ../types/runtime_values import ConfigNotificationEvent
import ../utils/behavior_log
import
  bindings_runtime, child_process_runtime, idle_inhibit_runtime, live_restore_runtime,
  process_runner, output_management_runtime, shell_runner, render_invalidation, state

type StartupConfigLoadResult* = object
  config*: Config
  configPaths*: seq[string]
  usedFallback*: bool
  error*: string

proc setupConfig*(daemon: var TriadDaemon, configPath = "") =
  daemon.configPath =
    if configPath.len > 0:
      configPath.absoluteConfigPath()
    else:
      defaultConfigPath().absoluteConfigPath()
  let configDir = daemon.configPath.splitFile().dir
  if not dirExists(configDir):
    createDir(configDir)

  if not fileExists(daemon.configPath) and not symlinkExists(daemon.configPath):
    writeFile(daemon.configPath, FallbackConfigContent)
    info "Created default config", path = daemon.configPath

proc loadStartupConfig*(daemon: var TriadDaemon): StartupConfigLoadResult =
  let loaded = loadConfigStrict(daemon.configPath)
  if loaded.ok:
    daemon.configWatchPaths = loaded.configPaths
    return
      StartupConfigLoadResult(config: loaded.config, configPaths: loaded.configPaths)

  warn "Initial config strict validation failed; using built-in fallback",
    path = daemon.configPath, error = loaded.error
  writeBehaviorEvent(
    "config_startup_fallback",
    %*{"path": daemon.configPath, "reason": "load failed", "error": loaded.error},
  )
  daemon.configWatchPaths = @[daemon.configPath]
  StartupConfigLoadResult(
    config: loadFallbackConfig(),
    configPaths: daemon.configWatchPaths,
    usedFallback: true,
    error: loaded.error,
  )

proc scheduleStartupCommands*(daemon: var TriadDaemon, model: Model) =
  daemon.startupCommandsPending = model.startupCommands.len > 0

proc spawnPendingStartupCommands*(
    daemon: var TriadDaemon, model: Model, reason: string
) =
  if not daemon.startupCommandsPending:
    return
  daemon.startupCommandsPending = false
  info "Spawning startup commands", reason = reason
  daemon.trackChildProcesses(spawnStartupCommands(model))

proc broadcastNiriSnapshot*(snapshot: ShellSnapshot) =
  for event in initialNiriEvents(snapshot):
    asyncCheck broadcastJson(event)

proc windowPreservationState(win: ShellWindow): string =
  let tagId =
    if win.tagId.isSome:
      $win.tagId.get()
    else:
      "null"

  [
    $win.workspaceIdx,
    tagId,
    $win.isFloating,
    $win.isFullscreen,
    $win.isMaximized,
    $win.isMinimized,
    $win.fullscreenOutput,
    $win.widthProportion,
    $win.heightProportion,
    $win.actualW,
    $win.actualH,
    $win.floatingGeom.x,
    $win.floatingGeom.y,
    $win.floatingGeom.w,
    $win.floatingGeom.h,
  ].join("|")

proc windowPreservationMap(snapshot: ShellSnapshot): Table[uint32, string] =
  for win in snapshot.windows:
    result[uint32(win.id)] = win.windowPreservationState()

proc configReloadPreservationProblem(before, after: ShellSnapshot): string =
  if before.activeTag != after.activeTag:
    return "active workspace changed"
  if before.activeWorkspaceIdx != after.activeWorkspaceIdx:
    return "active workspace index changed"
  if before.focusedWindowId() != after.focusedWindowId():
    return "focused window changed"
  if before.windows.len != after.windows.len:
    return "window count changed"

  let beforeWindows = before.windowPreservationMap()
  let afterWindows = after.windowPreservationMap()
  for winId, state in beforeWindows.pairs:
    if not afterWindows.hasKey(winId):
      return "window disappeared during config reload"
    if afterWindows[winId] != state:
      return "window placement or attributes changed"
  for winId in afterWindows.keys:
    if not beforeWindows.hasKey(winId):
      return "window appeared during config reload"
  ""

proc configNotificationCommand(
    model: Model, event: ConfigNotificationEvent
): seq[string] =
  case event
  of ConfigNotificationEvent.ConfigReloadSucceeded:
    model.configNotification.reloadSucceeded
  of ConfigNotificationEvent.ConfigReloadFailed:
    model.configNotification.reloadFailed
  of ConfigNotificationEvent.ConfigReloadRolledBack:
    model.configNotification.reloadRolledBack
  of ConfigNotificationEvent.ConfigNotifyNone:
    @[]

proc dispatchConfigNotification(
    daemon: var TriadDaemon, model: Model, event: ConfigNotificationEvent
) =
  let command = model.configNotificationCommand(event)
  if command.len == 0:
    return
  writeBehaviorEvent(
    "config_notification_requested", %*{"event": $event, "command": command}
  )
  if daemon.configNotificationHook != nil:
    daemon.configNotificationHook(addr daemon, event, command)
  else:
    daemon.trackChildProcess(spawnConfigNotification(model, event, command), command[0])

proc applyConfigReload*(
    daemon: var TriadDaemon, configPath, niriSocketPath: string
): bool =
  let beforeSnapshot = daemon.readModelSnapshot()
  writeBehaviorEvent(
    "config_reload_started",
    %*{"path": configPath, "before": beforeSnapshot.snapshotBehaviorPayload()},
  )

  let loaded = loadConfigStrict(configPath)
  if not loaded.ok:
    warn "Config reload rejected; keeping current config",
      path = configPath, error = loaded.error
    writeBehaviorEvent(
      "config_reload_rejected",
      %*{
        "path": configPath,
        "reason": "parse error",
        "error": loaded.error,
        "before": beforeSnapshot.snapshotBehaviorPayload(),
      },
    )
    daemon.dispatchConfigNotification(
      daemon.runtimeState.model, ConfigNotificationEvent.ConfigReloadFailed
    )
    return false
  let restore = daemon.writeCurrentLiveRestoreState()
  if not restore.ok:
    warn "Config reload rejected; live restore snapshot could not be written",
      path = restore.path, error = restore.error
    writeBehaviorEvent(
      "config_reload_rejected",
      %*{
        "path": configPath,
        "reason": "live restore snapshot rejected",
        "error": restore.error,
        "before": beforeSnapshot.snapshotBehaviorPayload(),
      },
    )
    daemon.dispatchConfigNotification(
      daemon.runtimeState.model, ConfigNotificationEvent.ConfigReloadFailed
    )
    return false
  daemon.liveRestoreCommitPending = true

  let previousModel = daemon.runtimeState.model
  discard daemon.runtimeState.applyRuntimeConfig(loaded.config)
  let appliedSnapshot = daemon.readModelSnapshot()
  let preservationProblem =
    beforeSnapshot.configReloadPreservationProblem(appliedSnapshot)
  if preservationProblem.len > 0:
    daemon.runtimeState.model = previousModel
    daemon.commitPendingLiveRestore()
    warn "Config reload rolled back; live state changed",
      path = configPath, reason = preservationProblem
    writeBehaviorEvent(
      "config_reload_rolled_back",
      %*{
        "path": configPath,
        "reason": preservationProblem,
        "before": beforeSnapshot.snapshotBehaviorPayload(),
        "candidate": appliedSnapshot.snapshotBehaviorPayload(),
        "restored": daemon.readModelSnapshot().snapshotBehaviorPayload(),
      },
    )
    daemon.dispatchConfigNotification(
      previousModel, ConfigNotificationEvent.ConfigReloadRolledBack
    )
    return false

  daemon.shellRunner.spawnPending = false
  if daemon.inputConfigReloadHook != nil:
    daemon.inputConfigReloadHook(addr daemon, "config reload")
  daemon.syncIdleInhibitFromRuntime()
  daemon.resetOutputManagementRetry()
  daemon.applyOutputManagementConfig("config reload")
  writeBehaviorEvent(
    "config_reload_applied",
    %*{
      "path": configPath,
      "before": beforeSnapshot.snapshotBehaviorPayload(),
      "after": appliedSnapshot.snapshotBehaviorPayload(),
    },
  )

  let shellChanged =
    not sameShellsConfig(previousModel.shells, daemon.runtimeState.model.shells)
  writeBehaviorEvent(
    "shell_config_reload_decision",
    %*{
      "reason": "config reload",
      "changed": shellChanged,
      "previous_active": previousModel.shells.active,
      "current_active": daemon.runtimeState.model.shells.active,
    },
  )

  if not shellChanged:
    if daemon.shellRunner.needsShellRecovery(daemon.runtimeState.model):
      writeBehaviorEvent(
        "shell_config_reload_recovery",
        %*{"reason": "config reload", "active": daemon.runtimeState.model.shells.active},
      )
      daemon.shellRunner.switchShell(
        previousModel, daemon.runtimeState.model, niriSocketPath,
        "config reload recovery",
      )
  else:
    daemon.shellRunner.switchShell(
      previousModel, daemon.runtimeState.model, niriSocketPath, "config reload"
    )

  daemon.requestBindingReconfigure("config reload")
  daemon.configWatchPaths = loaded.configPaths
  info "Config reloaded", path = configPath
  daemon.dispatchConfigNotification(
    daemon.runtimeState.model, ConfigNotificationEvent.ConfigReloadSucceeded
  )
  daemon.postManageBroadcastPending = true
  daemon.postManageBroadcastReason = "config reload"
  daemon.markRenderDirty("config reload")
  broadcastNiriSnapshot(daemon.readModelSnapshot())
  writeBehaviorEvent(
    "config_reload_broadcast",
    %*{
      "path": configPath,
      "phase": "pre-manage",
      "snapshot": daemon.readModelSnapshot().snapshotBehaviorPayload(),
    },
  )
  true
