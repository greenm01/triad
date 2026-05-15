import std/[json, osproc, strutils, times]
import chronicles
import process_runner
import ../ipc/quickshell_compat
import ../types/model
from ../types/runtime_values import QuickshellConfig
import ../utils/behavior_log

type
  QuickshellRecoveryDelay* = array[3, int64]

  QuickshellSpawnStatus* {.pure.} = enum
    Skipped
    Running
    Handoff
    Failed

  QuickshellRunner* = object
    trackedProcess*: Process
    spawnPending*: bool
    recoveryPending*: bool
    recoveryAttempts*: int
    nextRecoveryMs*: int64
    recoveryReason*: string

const
  MaxQuickshellRecoveryAttempts* = 3
  QuickshellRecoveryDelaysMs*: QuickshellRecoveryDelay = [500'i64, 1000, 2000]

proc succeeded*(status: QuickshellSpawnStatus): bool =
  status == QuickshellSpawnStatus.Running

proc currentUnixMs(): int64 =
  int64(epochTime() * 1000.0)

proc recoveryDelayMs(attempts: int): int64 =
  QuickshellRecoveryDelaysMs[min(attempts, QuickshellRecoveryDelaysMs.high)]

proc clearQuickshellRecovery*(runner: var QuickshellRunner) =
  runner.recoveryPending = false
  runner.recoveryAttempts = 0
  runner.nextRecoveryMs = 0
  runner.recoveryReason = ""

proc trackedQuickshellRunning*(runner: var QuickshellRunner): bool =
  if runner.trackedProcess == nil:
    return false
  let code = runner.trackedProcess.pollProcessExitCode(0)
  if code == -1:
    return true
  writeBehaviorEvent(
    "quickshell_tracked_process_exited",
    %*{"tracked_pid": runner.trackedProcess.processID, "exit_code": code},
  )
  try:
    runner.trackedProcess.close()
  except CatchableError:
    discard
  runner.trackedProcess = nil
  false

proc needsQuickshellRecovery*(runner: var QuickshellRunner, model: Model): bool =
  model.quickshell.enabled and model.quickshell.theme.strip().len > 0 and
    not runner.trackedQuickshellRunning()

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
  if not model.quickshell.enabled or model.quickshell.theme.strip().len == 0:
    runner.clearQuickshellRecovery()
    return

  runner.recoveryPending = true
  runner.recoveryAttempts = 0
  runner.nextRecoveryMs = nowMs + runner.recoveryAttempts.recoveryDelayMs()
  runner.recoveryReason = reason
  writeQuickshellBehaviorEvent(
    "quickshell_recovery_scheduled",
    model.quickshell,
    reason,
    %*{
      "status": $status,
      "attempt": runner.recoveryAttempts,
      "next_recovery_ms": runner.nextRecoveryMs,
      "delay_ms": runner.recoveryAttempts.recoveryDelayMs(),
    },
  )

proc stopTrackedQuickshell*(runner: var QuickshellRunner, reason: string) =
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
  if not model.quickshell.enabled or model.quickshell.theme.strip().len == 0:
    runner.clearQuickshellRecovery()
    return false
  if runner.trackedQuickshellRunning():
    if runner.recoveryPending:
      writeQuickshellBehaviorEvent(
        "quickshell_recovery_succeeded",
        model.quickshell,
        runner.recoveryReason,
        %*{"attempt": runner.recoveryAttempts, "already_running": true},
      )
    runner.clearQuickshellRecovery()
    return false
  if not runner.recoveryPending or nowMs < runner.nextRecoveryMs:
    return false

  if runner.recoveryAttempts >= MaxQuickshellRecoveryAttempts:
    writeQuickshellBehaviorEvent(
      "quickshell_recovery_exhausted",
      model.quickshell,
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts},
    )
    runner.clearQuickshellRecovery()
    return false

  inc runner.recoveryAttempts
  let attemptReason =
    runner.recoveryReason & " recovery attempt " & $runner.recoveryAttempts
  writeQuickshellBehaviorEvent(
    "quickshell_recovery_attempt",
    model.quickshell,
    runner.recoveryReason,
    %*{"attempt": runner.recoveryAttempts, "attempt_reason": attemptReason},
  )
  model.stopConfiguredQuickshell(attemptReason)
  let status = runner.spawnQuickshell(model, niriSocketPath, attemptReason)
  result = true
  if status.succeeded():
    writeQuickshellBehaviorEvent(
      "quickshell_recovery_succeeded",
      model.quickshell,
      runner.recoveryReason,
      %*{"attempt": runner.recoveryAttempts, "status": $status},
    )
    runner.clearQuickshellRecovery()
    return

  if runner.recoveryAttempts >= MaxQuickshellRecoveryAttempts:
    writeQuickshellBehaviorEvent(
      "quickshell_recovery_exhausted",
      model.quickshell,
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts, "status": $status},
    )
    runner.clearQuickshellRecovery()
    return

  let delayMs = runner.recoveryAttempts.recoveryDelayMs()
  runner.nextRecoveryMs = nowMs + delayMs
  writeQuickshellBehaviorEvent(
    "quickshell_recovery_rescheduled",
    model.quickshell,
    runner.recoveryReason,
    %*{
      "attempt": runner.recoveryAttempts,
      "status": $status,
      "next_recovery_ms": runner.nextRecoveryMs,
      "delay_ms": delayMs,
    },
  )

proc scheduleQuickshellSpawn*(runner: var QuickshellRunner, model: Model) =
  runner.spawnPending =
    model.quickshell.enabled and model.quickshell.theme.strip().len > 0

proc spawnPendingQuickshell*(
    runner: var QuickshellRunner, model: Model, niriSocketPath, reason: string
) =
  if not runner.spawnPending:
    return
  runner.spawnPending = false
  let action = quickshellStartupAction(model.quickshell)
  writeQuickshellBehaviorEvent(
    "quickshell_startup_decision", model.quickshell, reason, %*{"action": $action}
  )
  case action
  of QuickshellReloadAction.Noop:
    discard
  of QuickshellReloadAction.SpawnOnly:
    let status = runner.spawnQuickshell(model, niriSocketPath, reason)
    if not status.succeeded():
      writeQuickshellBehaviorEvent(
        "quickshell_startup_restart_required", model.quickshell, reason
      )
      model.stopConfiguredQuickshell(reason & " stale instance")
      let restartStatus =
        runner.spawnQuickshell(model, niriSocketPath, reason & " restart")
      if not restartStatus.succeeded():
        runner.scheduleQuickshellRecovery(model, reason & " restart", restartStatus)
  of QuickshellReloadAction.AuthoritativeStop:
    runner.stopQuickshell(model, reason, authoritative = true)
  of QuickshellReloadAction.AuthoritativeRestart:
    runner.restartQuickshell(model, niriSocketPath, reason)
