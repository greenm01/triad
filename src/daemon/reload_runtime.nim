import std/[asyncdispatch, json, os]
import chronicles
import ../config/[defaults, parser]
import ../core/niri_state
import ../ipc/[quickshell_compat, socket]
import ../systems/runtime_facade
import ../types/[model, shell_snapshot]
import ../utils/behavior_log
import bindings_runtime, live_restore_runtime, manage_requests, process_runner,
  quickshell_runner, state

proc setupConfig*(daemon: var TriadDaemon) =
  daemon.configPath = defaultConfigPath()
  let configDir = daemon.configPath.splitFile().dir
  if not dirExists(configDir):
    createDir(configDir)

  if not fileExists(daemon.configPath):
    writeFile(daemon.configPath, FallbackConfigContent)
    info "Created default config", path = daemon.configPath

proc scheduleStartupCommands*(daemon: var TriadDaemon; model: Model) =
  daemon.startupCommandsPending = model.startupCommands.len > 0

proc spawnPendingStartupCommands*(
    daemon: var TriadDaemon; model: Model; reason: string) =
  if not daemon.startupCommandsPending:
    return
  daemon.startupCommandsPending = false
  info "Spawning startup commands", reason = reason
  spawnStartupCommands(model)

proc broadcastNiriSnapshot*(snapshot: ShellSnapshot) =
  for event in initialNiriEvents(snapshot):
    asyncCheck broadcastJson(event)

proc applyConfigReload*(
    daemon: var TriadDaemon; configPath, niriSocketPath: string): bool =
  let loaded = loadConfigStrict(configPath)
  if not loaded.ok:
    warn "Config reload rejected; keeping current config", path = configPath,
        error = loaded.error
    return false

  let previousModel = daemon.runtimeState.model
  discard daemon.runtimeState.applyRuntimeConfig(loaded.config)
  daemon.quickshellState.spawnPending = false

  let quickshellAction = quickshellConfigReloadAction(
    previousModel.quickshell,
    daemon.runtimeState.model.quickshell)
  writeBehaviorEvent("quickshell_config_reload_decision", %*{
    "reason": "config reload",
    "action": $quickshellAction,
    "changed": quickshellAction != QuickshellReloadAction.Noop,
    "previous": quickshellBehaviorPayload(
      previousModel.quickshell,
      "config reload"),
    "current": quickshellBehaviorPayload(
      daemon.runtimeState.model.quickshell,
      "config reload")
  })

  case quickshellAction
  of QuickshellReloadAction.Noop, QuickshellReloadAction.SpawnOnly:
    discard
  of QuickshellReloadAction.AuthoritativeStop:
    daemon.quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true)
  of QuickshellReloadAction.AuthoritativeRestart:
    daemon.quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true)
    discard daemon.quickshellState.spawnQuickshell(
      daemon.runtimeState.model, niriSocketPath, "config reload")

  daemon.destroyBindings()
  info "Config reloaded", path = configPath
  daemon.requestManage("config reload")
  broadcastNiriSnapshot(daemon.readModelSnapshot())
  true
