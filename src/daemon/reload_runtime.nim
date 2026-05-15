import std/[asyncdispatch, json, options, os, strutils, tables]
import chronicles
import ../config/[defaults, parser]
import ../core/[niri_state, shell_focus]
import ../ipc/[quickshell_compat, socket]
import ../systems/runtime_facade
import ../types/[model, shell_snapshot]
from ../types/runtime_values import ConfigNotificationEvent
import ../utils/behavior_log
import
  bindings_runtime, idle_inhibit_runtime, live_restore_runtime, process_runner,
  quickshell_runner, state

proc setupConfig*(daemon: var TriadDaemon, configPath = "") =
  daemon.configPath =
    if configPath.len > 0:
      configPath.absoluteConfigPath()
    else:
      defaultConfigPath().absoluteConfigPath()
  let configDir = daemon.configPath.splitFile().dir
  if not dirExists(configDir):
    createDir(configDir)

  if not fileExists(daemon.configPath):
    writeFile(daemon.configPath, FallbackConfigContent)
    info "Created default config", path = daemon.configPath

proc scheduleStartupCommands*(daemon: var TriadDaemon, model: Model) =
  daemon.startupCommandsPending = model.startupCommands.len > 0

proc spawnPendingStartupCommands*(
    daemon: var TriadDaemon, model: Model, reason: string
) =
  if not daemon.startupCommandsPending:
    return
  daemon.startupCommandsPending = false
  info "Spawning startup commands", reason = reason
  spawnStartupCommands(model)

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
    spawnConfigNotification(model, event, command)

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

  daemon.quickshellState.spawnPending = false
  if daemon.inputConfigReloadHook != nil:
    daemon.inputConfigReloadHook(addr daemon, "config reload")
  daemon.syncIdleInhibitFromRuntime()
  writeBehaviorEvent(
    "config_reload_applied",
    %*{
      "path": configPath,
      "before": beforeSnapshot.snapshotBehaviorPayload(),
      "after": appliedSnapshot.snapshotBehaviorPayload(),
    },
  )

  let quickshellAction = quickshellConfigReloadAction(
    previousModel.quickshell, daemon.runtimeState.model.quickshell
  )
  writeBehaviorEvent(
    "quickshell_config_reload_decision",
    %*{
      "reason": "config reload",
      "action": $quickshellAction,
      "changed": quickshellAction != QuickshellReloadAction.Noop,
      "previous": quickshellBehaviorPayload(previousModel.quickshell, "config reload"),
      "current":
        quickshellBehaviorPayload(daemon.runtimeState.model.quickshell, "config reload"),
    },
  )

  case quickshellAction
  of QuickshellReloadAction.Noop:
    if daemon.quickshellState.needsQuickshellRecovery(daemon.runtimeState.model):
      writeQuickshellBehaviorEvent(
        "quickshell_config_reload_recovery", daemon.runtimeState.model.quickshell,
        "config reload",
      )
      let status = daemon.quickshellState.spawnQuickshell(
        daemon.runtimeState.model, niriSocketPath, "config reload recovery"
      )
      if not status.succeeded():
        daemon.quickshellState.scheduleQuickshellRecovery(
          daemon.runtimeState.model, "config reload recovery", status
        )
  of QuickshellReloadAction.SpawnOnly:
    discard
  of QuickshellReloadAction.AuthoritativeStop:
    daemon.quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true
    )
  of QuickshellReloadAction.AuthoritativeRestart:
    daemon.quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true
    )
    let status = daemon.quickshellState.spawnQuickshell(
      daemon.runtimeState.model, niriSocketPath, "config reload"
    )
    if not status.succeeded():
      daemon.quickshellState.scheduleQuickshellRecovery(
        daemon.runtimeState.model, "config reload", status
      )

  daemon.requestBindingReconfigure("config reload")
  daemon.configWatchPaths = loaded.configPaths
  info "Config reloaded", path = configPath
  daemon.dispatchConfigNotification(
    daemon.runtimeState.model, ConfigNotificationEvent.ConfigReloadSucceeded
  )
  daemon.postManageBroadcastPending = true
  daemon.postManageBroadcastReason = "config reload"
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
