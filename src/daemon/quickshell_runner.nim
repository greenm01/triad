import std/[json, options, os, osproc, sequtils, strutils, times]
import chronicles
import process_runner
import ../core/[defaults, shell_profiles]
import ../ipc/quickshell_compat
import ../types/model
from ../types/runtime_values import
  QuickshellConfig, ShellProfileConfig, ShellWatchdogConfig, ShellsConfig
import ../utils/behavior_log

type
  QuickshellRecoveryDelay* = array[3, int64]

  QuickshellSpawnStatus* {.pure.} = enum
    Skipped
    Running
    Handoff
    Failed

  ShellTrackedExit* = object
    shellName*: string
    pid*: int
    exitCode*: int

  QuickshellRunner* = object
    trackedProcess*: Process
    trackedShellName*: string
    spawnPending*: bool
    recoveryPending*: bool
    recoveryAttempts*: int
    nextRecoveryMs*: int64
    recoveryReason*: string
    exclusiveFocusSinceMs*: int64

const
  MaxQuickshellRecoveryAttempts* = 3
  QuickshellRecoveryDelaysMs*: QuickshellRecoveryDelay = [500'i64, 1000, 2000]

proc succeeded*(status: QuickshellSpawnStatus): bool =
  status == QuickshellSpawnStatus.Running

proc currentUnixMs(): int64 =
  int64(epochTime() * 1000.0)

proc commandArgs(command: seq[string]): seq[string] =
  if command.len > 1:
    command[1 ..^ 1]
  else:
    @[]

proc commandAvailable(command: string): bool =
  if command.len == 0:
    return false
  if command.contains($DirSep) or (AltSep != '\0' and command.contains($AltSep)):
    return fileExists(command)
  findExe(command).len > 0

proc recoveryDelayMs(attempts: int): int64 =
  QuickshellRecoveryDelaysMs[min(attempts, QuickshellRecoveryDelaysMs.high)]

proc clearQuickshellRecovery*(runner: var QuickshellRunner) =
  runner.recoveryPending = false
  runner.recoveryAttempts = 0
  runner.nextRecoveryMs = 0
  runner.recoveryReason = ""

proc pollTrackedShellExit(runner: var QuickshellRunner): Option[ShellTrackedExit] =
  if runner.trackedProcess == nil:
    return none(ShellTrackedExit)
  let code = runner.trackedProcess.pollProcessExitCode(0)
  if code == -1:
    return none(ShellTrackedExit)
  result = some(
    ShellTrackedExit(
      shellName: runner.trackedShellName,
      pid: runner.trackedProcess.processID,
      exitCode: code,
    )
  )
  writeBehaviorEvent(
    "quickshell_tracked_process_exited",
    %*{
      "tracked_pid": result.get().pid,
      "profile": result.get().shellName,
      "exit_code": result.get().exitCode,
    },
  )
  try:
    runner.trackedProcess.close()
  except CatchableError:
    discard
  runner.trackedProcess = nil
  runner.trackedShellName = ""

proc trackedQuickshellRunning*(runner: var QuickshellRunner): bool =
  if runner.trackedProcess == nil:
    return false
  if runner.pollTrackedShellExit().isSome:
    return false
  true

proc activeShellProfile(
  model: Model
): tuple[shells: ShellsConfig, profile: Option[ShellProfileConfig]]

proc needsQuickshellRecovery*(runner: var QuickshellRunner, model: Model): bool =
  let active = model.activeShellProfile()
  active.profile.isSome and not runner.trackedQuickshellRunning()

proc quickshellBehaviorPayload*(
    config: QuickshellConfig, reason: string, extra: JsonNode = nil
): JsonNode =
  result =
    %*{
      "reason": reason,
      "enabled": config.enabled,
      "command": config.command,
      "theme": config.theme,
      "args": config.args,
    }
  if extra != nil and extra.kind == JObject:
    for key, value in extra.pairs:
      result[key] = value

proc legacyShellsFromQuickshell(config: QuickshellConfig): ShellsConfig =
  var command = config.command.strip()
  if command.len == 0:
    command = DefaultQuickshellCommand
  if not config.enabled or config.theme.strip().len == 0:
    return ShellsConfig(enabled: false)

  var launch = @[command, "-c", config.theme]
  for arg in config.args:
    launch.add(arg)

  ShellsConfig(
    enabled: true,
    active: "quickshell",
    cycle: @["quickshell"],
    watchdog: ShellWatchdogConfig(
      enabled: true,
      fallback: "quickshell",
      exclusiveFocusTimeoutMs: DefaultShellWatchdogExclusiveFocusTimeoutMs,
    ),
    profiles:
      @[
        ShellProfileConfig(
          name: "quickshell",
          launch: launch,
          stop: @[command, "kill", "-c", config.theme, "--any-display"],
          niriCompat: true,
        )
      ],
  )

proc effectiveShells(model: Model): ShellsConfig =
  if model.shells.configured or model.shells.profiles.len > 0:
    result = model.shells
  else:
    result = model.quickshell.legacyShellsFromQuickshell()
  result.normalizeShells()

proc shellBehaviorPayload(
    shells: ShellsConfig,
    profile: ShellProfileConfig,
    reason: string,
    extra: JsonNode = nil,
): JsonNode =
  result =
    %*{
      "reason": reason,
      "enabled": shells.enabled,
      "active": shells.active,
      "profile": profile.name,
      "launch": profile.launch,
      "stop": profile.stop,
      "niri_compat": profile.niriCompat,
    }
  if extra != nil and extra.kind == JObject:
    for key, value in extra.pairs:
      result[key] = value

proc writeShellBehaviorEvent(
    eventName: string,
    shells: ShellsConfig,
    profile: ShellProfileConfig,
    reason: string,
    extra: JsonNode = nil,
) =
  writeBehaviorEvent(eventName, shellBehaviorPayload(shells, profile, reason, extra))

proc writeQuickshellBehaviorEvent*(
    eventName: string, config: QuickshellConfig, reason: string, extra: JsonNode = nil
) =
  writeBehaviorEvent(eventName, quickshellBehaviorPayload(config, reason, extra))

proc scheduleQuickshellRecovery*(
    runner: var QuickshellRunner,
    model: Model,
    reason: string,
    status: QuickshellSpawnStatus,
    nowMs = currentUnixMs(),
) =
  let active = model.activeShellProfile()
  if active.profile.isNone:
    runner.clearQuickshellRecovery()
    return

  runner.recoveryPending = true
  runner.recoveryAttempts = 0
  runner.nextRecoveryMs = nowMs + runner.recoveryAttempts.recoveryDelayMs()
  runner.recoveryReason = reason
  writeShellBehaviorEvent(
    "shell_recovery_scheduled",
    active.shells,
    active.profile.get(),
    reason,
    %*{
      "status": $status,
      "attempt": runner.recoveryAttempts,
      "next_recovery_ms": runner.nextRecoveryMs,
      "delay_ms": runner.recoveryAttempts.recoveryDelayMs(),
    },
  )

proc stopTrackedQuickshell*(runner: var QuickshellRunner, reason: string) =
  runner.exclusiveFocusSinceMs = 0
  if runner.trackedProcess == nil:
    writeBehaviorEvent(
      "quickshell_tracked_stop_skipped", %*{"reason": reason, "tracked": false}
    )
    return

  let pid = runner.trackedProcess.processID
  writeBehaviorEvent(
    "quickshell_tracked_stop_requested", %*{"reason": reason, "tracked_pid": pid}
  )
  try:
    runner.trackedProcess.terminate()
    var code = runner.trackedProcess.pollProcessExitCode(1000)
    var killed = false
    if code == -1:
      runner.trackedProcess.kill()
      code = runner.trackedProcess.waitForExit()
      killed = true
    info "Stopped Quickshell", pid = pid, reason = reason
    writeBehaviorEvent(
      "quickshell_tracked_stop_completed",
      %*{"reason": reason, "tracked_pid": pid, "exit_code": code, "killed": killed},
    )
  except CatchableError as e:
    warn "Failed to stop Quickshell", pid = pid, reason = reason, error = e.msg
    writeBehaviorEvent(
      "quickshell_tracked_stop_failed",
      %*{"reason": reason, "tracked_pid": pid, "error": e.msg},
    )

  try:
    runner.trackedProcess.close()
  except CatchableError:
    discard
  runner.trackedProcess = nil

proc releaseTrackedQuickshell*(runner: var QuickshellRunner, reason: string) =
  runner.exclusiveFocusSinceMs = 0
  if runner.trackedProcess == nil:
    writeBehaviorEvent(
      "quickshell_release_skipped", %*{"reason": reason, "tracked": false}
    )
    return

  let pid = runner.trackedProcess.processID
  try:
    runner.trackedProcess.close()
    info "Released Quickshell for manager handoff", pid = pid, reason = reason
    writeBehaviorEvent("quickshell_released", %*{"reason": reason, "tracked_pid": pid})
  except CatchableError as e:
    warn "Failed to release Quickshell for manager handoff",
      pid = pid, reason = reason, error = e.msg
    writeBehaviorEvent(
      "quickshell_release_failed",
      %*{"reason": reason, "tracked_pid": pid, "error": e.msg},
    )
  runner.trackedProcess = nil
  runner.trackedShellName = ""

proc stopConfiguredQuickshell*(model: Model, reason: string) =
  let args = quickshellKillArgs(model.quickshell)
  if args.len == 0 or model.quickshell.command.strip().len == 0:
    writeQuickshellBehaviorEvent(
      "quickshell_configured_stop_skipped", model.quickshell, reason
    )
    return

  writeQuickshellBehaviorEvent(
    "quickshell_configured_stop_requested",
    model.quickshell,
    reason,
    %*{"kill_args": args},
  )
  try:
    let p = startProcess(
      model.quickshell.command,
      args = args,
      env = model.configuredProcessEnv(),
      options = {poUsePath},
    )
    let code = p.pollProcessExitCode(1000)
    if code == -1:
      p.kill()
      discard p.waitForExit()
      warn "Timed out stopping configured Quickshell instance",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason
      writeQuickshellBehaviorEvent(
        "quickshell_configured_stop_timed_out",
        model.quickshell,
        reason,
        %*{"kill_args": args},
      )
    elif code == 0:
      info "Stopped configured Quickshell instance",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason
      writeQuickshellBehaviorEvent(
        "quickshell_configured_stop_completed",
        model.quickshell,
        reason,
        %*{"kill_args": args, "exit_code": code},
      )
    else:
      debug "Configured Quickshell instance was not running",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason,
        exitCode = code
      writeQuickshellBehaviorEvent(
        "quickshell_configured_stop_not_running",
        model.quickshell,
        reason,
        %*{"kill_args": args, "exit_code": code},
      )
    p.close()
  except CatchableError as e:
    warn "Failed to stop configured Quickshell instance",
      command = model.quickshell.command,
      theme = model.quickshell.theme,
      reason = reason,
      error = e.msg
    writeQuickshellBehaviorEvent(
      "quickshell_configured_stop_failed",
      model.quickshell,
      reason,
      %*{"kill_args": args, "error": e.msg},
    )

proc stopQuickshell*(
    runner: var QuickshellRunner, model: Model, reason: string, authoritative = false
) =
  writeQuickshellBehaviorEvent(
    "quickshell_stop_requested",
    model.quickshell,
    reason,
    %*{"authoritative": authoritative},
  )
  runner.stopTrackedQuickshell(reason)
  if authoritative:
    runner.clearQuickshellRecovery()
    model.stopConfiguredQuickshell(reason)

proc stopShellProfile(
    runner: var QuickshellRunner,
    model: Model,
    shells: ShellsConfig,
    profile: ShellProfileConfig,
    reason: string,
    stopTracked = true,
) =
  writeShellBehaviorEvent(
    "shell_stop_requested",
    shells,
    profile,
    reason,
    %*{"tracked_profile": runner.trackedShellName},
  )

  if profile.stop.len > 0:
    if not profile.stop[0].commandAvailable():
      warn "Shell stop command is not available",
        profile = profile.name, command = profile.stop[0], reason = reason
      writeShellBehaviorEvent(
        "shell_stop_missing_command",
        shells,
        profile,
        reason,
        %*{"command": profile.stop[0]},
      )
    else:
      try:
        let p = startProcess(
          profile.stop[0],
          args = profile.stop.commandArgs(),
          env = model.configuredProcessEnv(),
          options = {poUsePath},
        )
        let code = p.pollProcessExitCode(1000)
        if code == -1:
          p.kill()
          discard p.waitForExit()
          writeShellBehaviorEvent(
            "shell_stop_timed_out", shells, profile, reason, %*{"command": profile.stop}
          )
        else:
          writeShellBehaviorEvent(
            "shell_stop_completed",
            shells,
            profile,
            reason,
            %*{"command": profile.stop, "exit_code": code},
          )
        p.close()
      except CatchableError as e:
        warn "Shell stop command failed",
          profile = profile.name,
          command = profile.stop[0],
          reason = reason,
          error = e.msg
        writeShellBehaviorEvent(
          "shell_stop_failed",
          shells,
          profile,
          reason,
          %*{"command": profile.stop, "error": e.msg},
        )

  if stopTracked and
      (runner.trackedShellName.len == 0 or runner.trackedShellName == profile.name):
    runner.stopTrackedQuickshell(reason)

proc spawnShellProfile(
    runner: var QuickshellRunner,
    model: Model,
    shells: ShellsConfig,
    profile: ShellProfileConfig,
    niriSocketPath: string,
    reason: string,
): QuickshellSpawnStatus =
  if not shells.enabled or profile.launch.len == 0:
    writeShellBehaviorEvent("shell_spawn_skipped", shells, profile, reason)
    return QuickshellSpawnStatus.Skipped

  result = QuickshellSpawnStatus.Failed
  if not profile.launch[0].commandAvailable():
    warn "Shell launch command is not available",
      profile = profile.name, command = profile.launch[0], reason = reason
    writeShellBehaviorEvent(
      "shell_spawn_missing_command",
      shells,
      profile,
      reason,
      %*{"command": profile.launch[0]},
    )
    return

  writeShellBehaviorEvent(
    "shell_spawn_requested",
    shells,
    profile,
    reason,
    %*{"launch": profile.launch, "niri_socket": niriSocketPath},
  )

  try:
    let baseEnv = model.configuredProcessEnv()
    let env =
      if profile.niriCompat:
        prepareQuickshellCompatEnv(niriSocketPath, baseEnv = baseEnv).env
      else:
        baseEnv
    let p = startProcess(
      profile.launch[0],
      args = profile.launch.commandArgs(),
      env = env,
      options = {poUsePath},
    )
    let childPid = p.processID
    let earlyExitCode = p.pollProcessExitCode(250)
    if earlyExitCode == -1:
      runner.trackedProcess = p
      runner.trackedShellName = profile.name
      writeShellBehaviorEvent(
        "shell_spawned",
        shells,
        profile,
        reason,
        %*{"child_pid": childPid, "launch": profile.launch},
      )
      result = QuickshellSpawnStatus.Running
    elif earlyExitCode == 0:
      p.close()
      writeShellBehaviorEvent(
        "shell_spawn_handoff",
        shells,
        profile,
        reason,
        %*{"child_pid": childPid, "launch": profile.launch, "exit_code": earlyExitCode},
      )
      result = QuickshellSpawnStatus.Handoff
    else:
      p.close()
      writeShellBehaviorEvent(
        "shell_spawn_exited",
        shells,
        profile,
        reason,
        %*{"child_pid": childPid, "launch": profile.launch, "exit_code": earlyExitCode},
      )
  except CatchableError as e:
    warn "Failed to spawn shell",
      profile = profile.name,
      command = profile.launch[0],
      reason = reason,
      error = e.msg
    writeShellBehaviorEvent(
      "shell_spawn_failed",
      shells,
      profile,
      reason,
      %*{"launch": profile.launch, "error": e.msg},
    )

proc activeShellProfile(
    model: Model
): tuple[shells: ShellsConfig, profile: Option[ShellProfileConfig]] =
  result.shells = model.effectiveShells()
  result.profile = result.shells.activeShellProfile()

proc stopStaleShellProfiles*(
    runner: var QuickshellRunner, model: Model, reason: string
) =
  let active = model.activeShellProfile()
  if active.profile.isNone:
    return

  writeBehaviorEvent(
    "shell_startup_stale_cleanup_requested",
    %*{
      "reason": reason,
      "active": active.shells.active,
      "profiles": active.shells.profiles.mapIt(it.name),
    },
  )
  for profile in active.shells.profiles:
    runner.stopShellProfile(
      model, active.shells, profile, reason & " stale cleanup", stopTracked = false
    )

proc pollShellWatchdog*(
    runner: var QuickshellRunner, model: Model, nowMs = currentUnixMs()
): Option[string] =
  let active = model.activeShellProfile()
  if active.profile.isNone or not active.shells.shouldWatchShells():
    runner.exclusiveFocusSinceMs = 0
    return none(string)

  let profile = active.profile.get()
  let fallback = active.shells.fallbackShellName()
  let trackedExit = runner.pollTrackedShellExit()
  if trackedExit.isSome:
    let exited = trackedExit.get()
    writeShellBehaviorEvent(
      "shell_watchdog_process_exit",
      active.shells,
      profile,
      "tracked process exited",
      %*{
        "tracked_profile": exited.shellName,
        "tracked_pid": exited.pid,
        "exit_code": exited.exitCode,
        "fallback": fallback,
      },
    )
    if exited.shellName == profile.name:
      runner.exclusiveFocusSinceMs = 0
      if fallback.len > 0 and fallback != profile.name:
        writeShellBehaviorEvent(
          "shell_watchdog_fallback_requested",
          active.shells,
          profile,
          "tracked process exited",
          %*{"fallback": fallback},
        )
        return some(fallback)
      runner.scheduleQuickshellRecovery(
        model, "shell watchdog process exit", QuickshellSpawnStatus.Failed, nowMs
      )
    return none(string)

  if model.sessionLocked or active.shells.watchdog.exclusiveFocusTimeoutMs <= 0:
    runner.exclusiveFocusSinceMs = 0
    return none(string)
  if not model.layerFocusExclusive:
    runner.exclusiveFocusSinceMs = 0
    return none(string)
  if fallback.len == 0 or fallback == profile.name:
    runner.exclusiveFocusSinceMs = 0
    return none(string)

  if runner.exclusiveFocusSinceMs <= 0:
    runner.exclusiveFocusSinceMs = nowMs
    return none(string)

  let elapsedMs = nowMs - runner.exclusiveFocusSinceMs
  if elapsedMs < int64(active.shells.watchdog.exclusiveFocusTimeoutMs):
    return none(string)

  runner.exclusiveFocusSinceMs = 0
  writeShellBehaviorEvent(
    "shell_watchdog_exclusive_focus_timeout",
    active.shells,
    profile,
    "exclusive layer focus timeout",
    %*{
      "fallback": fallback,
      "elapsed_ms": elapsedMs,
      "timeout_ms": active.shells.watchdog.exclusiveFocusTimeoutMs,
    },
  )
  some(fallback)

proc switchShell*(
    runner: var QuickshellRunner,
    previousModel: Model,
    currentModel: Model,
    niriSocketPath: string,
    reason: string,
) =
  let previous = previousModel.activeShellProfile()
  let current = currentModel.activeShellProfile()
  if previous.profile.isSome:
    runner.stopShellProfile(
      previousModel, previous.shells, previous.profile.get(), reason & " stop"
    )
  elif runner.trackedProcess != nil:
    runner.stopTrackedQuickshell(reason & " stop")

  if current.profile.isSome:
    let status = runner.spawnShellProfile(
      currentModel, current.shells, current.profile.get(), niriSocketPath, reason
    )
    if not status.succeeded():
      runner.scheduleQuickshellRecovery(currentModel, reason, status)
  else:
    runner.clearQuickshellRecovery()

proc spawnQuickshell*(
    runner: var QuickshellRunner, model: Model, niriSocketPath: string, reason = "spawn"
): QuickshellSpawnStatus =
  if model.quickshell.enabled and model.quickshell.theme != "":
    result = QuickshellSpawnStatus.Failed
    let args = quickshellLaunchArgs(model.quickshell)
    writeQuickshellBehaviorEvent(
      "quickshell_spawn_requested",
      model.quickshell,
      reason,
      %*{"launch_args": args, "niri_socket": niriSocketPath},
    )

    try:
      let compat = prepareQuickshellCompatEnv(
        niriSocketPath, baseEnv = model.configuredProcessEnv()
      )
      if compat.warning.len > 0:
        warn "Quickshell compatibility environment is incomplete",
          warning = compat.warning
        writeQuickshellBehaviorEvent(
          "quickshell_compat_warning",
          model.quickshell,
          reason,
          %*{"warning": compat.warning},
        )
      let p = startProcess(
        model.quickshell.command, args = args, env = compat.env, options = {poUsePath}
      )
      let childPid = p.processID
      let earlyExitCode = p.pollProcessExitCode(250)
      if earlyExitCode == -1:
        runner.trackedProcess = p
        runner.trackedShellName = model.quickshell.theme
        info "Spawned Quickshell",
          command = model.quickshell.command,
          theme = model.quickshell.theme,
          pid = childPid,
          niriSocket = compat.niriSocketPath,
          shimReady = compat.shimReady,
          overlayReady = compat.overlayReady,
          xdgShare = compat.xdgSharePath
        writeQuickshellBehaviorEvent(
          "quickshell_spawned",
          model.quickshell,
          reason,
          %*{
            "child_pid": childPid,
            "launch_args": args,
            "niri_socket": compat.niriSocketPath,
            "shim_ready": compat.shimReady,
            "overlay_ready": compat.overlayReady,
            "xdg_share": compat.xdgSharePath,
          },
        )
        result = QuickshellSpawnStatus.Running
      elif earlyExitCode == 0:
        info "Quickshell launch command handed off",
          command = model.quickshell.command,
          theme = model.quickshell.theme,
          pid = childPid
        writeQuickshellBehaviorEvent(
          "quickshell_spawn_handoff",
          model.quickshell,
          reason,
          %*{"child_pid": childPid, "launch_args": args, "exit_code": earlyExitCode},
        )
        p.close()
        result = QuickshellSpawnStatus.Handoff
      else:
        info "Quickshell launch command exited immediately",
          command = model.quickshell.command,
          theme = model.quickshell.theme,
          pid = childPid,
          exitCode = earlyExitCode
        writeQuickshellBehaviorEvent(
          "quickshell_spawn_exited",
          model.quickshell,
          reason,
          %*{"child_pid": childPid, "launch_args": args, "exit_code": earlyExitCode},
        )
        p.close()
    except CatchableError as e:
      warn "Failed to spawn Quickshell",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        error = e.msg
      writeQuickshellBehaviorEvent(
        "quickshell_spawn_failed",
        model.quickshell,
        reason,
        %*{"launch_args": args, "error": e.msg},
      )
  else:
    writeQuickshellBehaviorEvent("quickshell_spawn_skipped", model.quickshell, reason)
    result = QuickshellSpawnStatus.Skipped

proc restartQuickshell*(
    runner: var QuickshellRunner, model: Model, niriSocketPath, reason: string
) =
  runner.stopQuickshell(model, reason, authoritative = true)
  let status = runner.spawnQuickshell(model, niriSocketPath, reason)
  if not status.succeeded():
    runner.scheduleQuickshellRecovery(model, reason, status)

proc pollQuickshellRecovery*(
    runner: var QuickshellRunner,
    model: Model,
    niriSocketPath: string,
    nowMs = currentUnixMs(),
): bool =
  let active = model.activeShellProfile()
  if active.profile.isNone:
    runner.clearQuickshellRecovery()
    return false
  if runner.trackedQuickshellRunning():
    if runner.recoveryPending:
      writeShellBehaviorEvent(
        "shell_recovery_succeeded",
        active.shells,
        active.profile.get(),
        runner.recoveryReason,
        %*{"attempt": runner.recoveryAttempts, "already_running": true},
      )
    runner.clearQuickshellRecovery()
    return false
  if not runner.recoveryPending or nowMs < runner.nextRecoveryMs:
    return false

  if runner.recoveryAttempts >= MaxQuickshellRecoveryAttempts:
    writeShellBehaviorEvent(
      "shell_recovery_exhausted",
      active.shells,
      active.profile.get(),
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts},
    )
    runner.clearQuickshellRecovery()
    return false

  inc runner.recoveryAttempts
  let attemptReason =
    runner.recoveryReason & " recovery attempt " & $runner.recoveryAttempts
  writeShellBehaviorEvent(
    "shell_recovery_attempt",
    active.shells,
    active.profile.get(),
    runner.recoveryReason,
    %*{"attempt": runner.recoveryAttempts, "attempt_reason": attemptReason},
  )
  runner.stopShellProfile(model, active.shells, active.profile.get(), attemptReason)
  let status = runner.spawnShellProfile(
    model, active.shells, active.profile.get(), niriSocketPath, attemptReason
  )
  result = true
  if status.succeeded():
    writeShellBehaviorEvent(
      "shell_recovery_succeeded",
      active.shells,
      active.profile.get(),
      runner.recoveryReason,
      %*{"attempt": runner.recoveryAttempts, "status": $status},
    )
    runner.clearQuickshellRecovery()
    return

  if runner.recoveryAttempts >= MaxQuickshellRecoveryAttempts:
    writeShellBehaviorEvent(
      "shell_recovery_exhausted",
      active.shells,
      active.profile.get(),
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts, "status": $status},
    )
    runner.clearQuickshellRecovery()
    return

  let delayMs = runner.recoveryAttempts.recoveryDelayMs()
  runner.nextRecoveryMs = nowMs + delayMs
  writeShellBehaviorEvent(
    "shell_recovery_rescheduled",
    active.shells,
    active.profile.get(),
    runner.recoveryReason,
    %*{
      "attempt": runner.recoveryAttempts,
      "status": $status,
      "next_recovery_ms": runner.nextRecoveryMs,
      "delay_ms": delayMs,
    },
  )

proc scheduleQuickshellSpawn*(runner: var QuickshellRunner, model: Model) =
  runner.spawnPending = model.activeShellProfile().profile.isSome

proc spawnPendingQuickshell*(
    runner: var QuickshellRunner, model: Model, niriSocketPath, reason: string
) =
  if not runner.spawnPending:
    return
  runner.spawnPending = false
  let active = model.activeShellProfile()
  if active.profile.isNone:
    return
  runner.stopStaleShellProfiles(model, reason)
  writeShellBehaviorEvent(
    "shell_startup_decision",
    active.shells,
    active.profile.get(),
    reason,
    %*{"action": "SpawnOnly"},
  )
  let status = runner.spawnShellProfile(
    model, active.shells, active.profile.get(), niriSocketPath, reason
  )
  if not status.succeeded():
    runner.stopShellProfile(
      model, active.shells, active.profile.get(), reason & " stale instance"
    )
    let restartStatus = runner.spawnShellProfile(
      model, active.shells, active.profile.get(), niriSocketPath, reason & " restart"
    )
    if not restartStatus.succeeded():
      runner.scheduleQuickshellRecovery(model, reason & " restart", restartStatus)
