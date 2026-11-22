import std/[json, options, os, osproc, sequtils, strtabs, strutils, times]
import chronicles
import process_runner
import process_handle
import tracked_child
import ../core/shell_profiles
import ../ipc/[niri_shell_compat, socket]
import ../types/model
from ../types/runtime_values import ShellProfileConfig, ShellsConfig
import ../utils/behavior_log
import ../utils/process_options

type
  ShellRecoveryDelay* = array[3, int64]

  ShellSpawnStatus* {.pure.} = enum
    Skipped
    Running
    Handoff
    Failed

  ShellTrackedExit* = object
    shellName*: string
    pid*: int
    exitCode*: int

  PendingShellLaunch* = object
    process*: ProcessHandle
    profile*: ShellProfileConfig
    shells*: ShellsConfig
    spawnInfo*: JsonNode
    niriSocketPath*: string
    reason*: string
    startedAtMs*: int64
    retryAllowed*: bool

  ShellRunner* = object
    trackedProcess*: ProcessHandle
    trackedShellName*: string
    spawnPending*: bool
    recoveryPending*: bool
    recoveryAttempts*: int
    nextRecoveryMs*: int64
    recoveryReason*: string
    exclusiveFocusSinceMs*: int64
    terminatingShells*: seq[TrackedChild]
    pendingLaunchActive*: bool
    pendingLaunch*: PendingShellLaunch
    releasedPids*: seq[int32]
    overlayProcesses*: seq[Process]

proc setTrackedProcessHandle*(
    runner: var ShellRunner, handle: ProcessHandle, name: string
) =
  runner.trackedProcess = handle
  runner.trackedShellName = name

proc queueFakeShellLaunch*(
    runner: var ShellRunner,
    handle: ProcessHandle,
    profile: ShellProfileConfig,
    shells: ShellsConfig,
    niriSocketPath: string,
    reason: string,
    nowMs = 0'i64,
    retryAllowed = false,
) =
  runner.pendingLaunch = PendingShellLaunch(
    process: handle,
    profile: profile,
    shells: shells,
    niriSocketPath: niriSocketPath,
    spawnInfo: nil,
    reason: reason,
    startedAtMs: nowMs,
    retryAllowed: retryAllowed,
  )
  runner.pendingLaunchActive = true

proc takeOverlayProcesses*(runner: var ShellRunner): seq[Process] =
  result = runner.overlayProcesses
  runner.overlayProcesses = @[]

const
  MaxShellRecoveryAttempts* = 3
  ShellRecoveryDelaysMs*: ShellRecoveryDelay = [500'i64, 1000, 2000]

proc succeeded*(status: ShellSpawnStatus): bool =
  status == ShellSpawnStatus.Running

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
  ShellRecoveryDelaysMs[min(attempts, ShellRecoveryDelaysMs.high)]

proc clearShellRecovery*(runner: var ShellRunner) =
  runner.recoveryPending = false
  runner.recoveryAttempts = 0
  runner.nextRecoveryMs = 0
  runner.recoveryReason = ""

proc pollTrackedShellExit(runner: var ShellRunner): Option[ShellTrackedExit] =
  if runner.trackedProcess == nil:
    return none(ShellTrackedExit)
  let code = runner.trackedProcess.peekExitCode()
  if code == -1:
    return none(ShellTrackedExit)
  result = some(
    ShellTrackedExit(
      shellName: runner.trackedShellName,
      pid: runner.trackedProcess.processID(),
      exitCode: code,
    )
  )
  writeBehaviorEvent(
    "shell_tracked_process_exited",
    %*{
      "tracked_pid": result.get().pid,
      "profile": result.get().shellName,
      "exit_code": result.get().exitCode,
    },
  )
  try:
    runner.trackedProcess.closeProcessHandle()
  except CatchableError:
    discard
  runner.trackedProcess = nil
  runner.trackedShellName = ""

proc trackedShellRunning*(runner: var ShellRunner): bool =
  if runner.trackedProcess == nil:
    return false
  if runner.pollTrackedShellExit().isSome:
    return false
  true

proc activeShellProfile(
  model: Model
): tuple[shells: ShellsConfig, profile: Option[ShellProfileConfig]]

proc needsShellRecovery*(runner: var ShellRunner, model: Model): bool =
  let active = model.activeShellProfile()
  active.profile.isSome and not runner.trackedShellRunning()

proc effectiveShells(model: Model): ShellsConfig =
  result = model.shells
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

proc shellCompatBehaviorPayload(
    profile: ShellProfileConfig, niriSocketPath: string, compat: NiriShellCompatEnv
): JsonNode =
  result = %*{"launch": profile.launch, "niri_socket": niriSocketPath}
  if not profile.niriCompat:
    return

  result["niri_socket"] = %compat.niriSocketPath
  result["shim_ready"] = %compat.shimReady
  result["overlay_ready"] = %compat.overlayReady
  result["compat_bin"] = %compat.compatBinPath
  result["niri_shim"] = %compat.niriShimPath
  result["triad_niri"] = %compat.triadNiriPath
  result["xdg_overlay"] = %compat.xdgOverlayPath
  result["xdg_share"] = %compat.xdgSharePath
  if compat.warning.len > 0:
    result["compat_warning"] = %compat.warning

proc prepareNativeShellEnv(model: Model): StringTableRef =
  result = model.configuredProcessEnv()
  result["TRIAD_SOCKET"] = triadSocketPath()
  result["XDG_CURRENT_DESKTOP"] = "triad"
  result["XDG_SESSION_DESKTOP"] = "triad"
  result["DESKTOP_SESSION"] = "triad"

proc shellSpawnEventPayload(
    spawnInfo: JsonNode, childPid = 0, exitCode: Option[int] = none(int), error = ""
): JsonNode =
  result = newJObject()
  if spawnInfo != nil and spawnInfo.kind == JObject:
    for key, value in spawnInfo.pairs:
      result[key] = value
  if childPid > 0:
    result["child_pid"] = %childPid
  if exitCode.isSome:
    result["exit_code"] = %exitCode.get()
  if error.len > 0:
    result["error"] = %error

proc scheduleShellRecovery*(
    runner: var ShellRunner,
    model: Model,
    reason: string,
    status: ShellSpawnStatus,
    nowMs = currentUnixMs(),
) =
  let active = model.activeShellProfile()
  if active.profile.isNone:
    runner.clearShellRecovery()
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

proc stopTrackedShell*(runner: var ShellRunner, reason: string) =
  runner.exclusiveFocusSinceMs = 0
  if runner.trackedProcess == nil:
    writeBehaviorEvent(
      "shell_tracked_stop_skipped", %*{"reason": reason, "tracked": false}
    )
    return

  let pid = runner.trackedProcess.processID()
  writeBehaviorEvent(
    "shell_tracked_stop_requested", %*{"reason": reason, "tracked_pid": pid}
  )
  let nowMs = currentUnixMs()
  var child = initTrackedChild(runner.trackedProcess, nowMs, 250'i64)
  child.beginTermination(nowMs, 250'i64)
  runner.terminatingShells.add(child)
  runner.trackedProcess = nil
  runner.trackedShellName = ""

proc advanceTerminatingShells*(runner: var ShellRunner, nowMs = currentUnixMs()) =
  var index = runner.terminatingShells.high
  while index >= 0:
    var child = runner.terminatingShells[index]
    if child.advanceTrackedChild(nowMs, 250'i64):
      let pid = child.process.processID()
      info "Stopped shell", pid = pid, reason = "tracked shell"
      writeBehaviorEvent(
        "shell_tracked_stop_completed",
        %*{
          "reason": "tracked shell",
          "tracked_pid": pid,
          "exit_code": child.exitCode,
          "killed": child.killSent,
        },
      )
      child.process.closeProcessHandle()
      runner.terminatingShells.delete(index)
    else:
      runner.terminatingShells[index] = child
    dec index

proc releaseTrackedShell*(runner: var ShellRunner, reason: string) =
  runner.exclusiveFocusSinceMs = 0
  if runner.trackedProcess == nil:
    writeBehaviorEvent("shell_release_skipped", %*{"reason": reason, "tracked": false})
    return

  let pid = runner.trackedProcess.processID()
  try:
    runner.trackedProcess.closeProcessHandle()
    info "Released shell for manager handoff", pid = pid, reason = reason
    writeBehaviorEvent("shell_released", %*{"reason": reason, "tracked_pid": pid})
  except CatchableError as e:
    warn "Failed to release shell for manager handoff",
      pid = pid, reason = reason, error = e.msg
    writeBehaviorEvent(
      "shell_release_failed", %*{"reason": reason, "tracked_pid": pid, "error": e.msg}
    )
  runner.trackedProcess = nil
  runner.releasedPids.add(int32(pid))
  runner.trackedShellName = ""


proc advanceReleasedShells*(runner: var ShellRunner) =
  var index = 0
  while index < runner.releasedPids.len:
    if reapReleasedPid(runner.releasedPids[index]):
      runner.releasedPids.delete(index)
    else:
      inc index


proc stopShellProfile(
    runner: var ShellRunner,
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
          options = InheritedProcessOptions,
        )
        var code = p.pollProcessExitCode(250)
        var killed = false
        if code == -1:
          p.kill()
          code = p.waitForExit(250)
          killed = true
        if killed:
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
    runner.stopTrackedShell(reason)

proc spawnShellProfile(
    runner: var ShellRunner,
    model: Model,
    shells: ShellsConfig,
    profile: ShellProfileConfig,
    niriSocketPath: string,
    reason: string,
    retryAllowed = true,
): ShellSpawnStatus =
  if not shells.enabled or profile.launch.len == 0:
    writeShellBehaviorEvent("shell_spawn_skipped", shells, profile, reason)
    return ShellSpawnStatus.Skipped

  result = ShellSpawnStatus.Failed
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

  var spawnInfo =
    shellCompatBehaviorPayload(profile, niriSocketPath, NiriShellCompatEnv())
  try:
    let baseEnv = model.prepareNativeShellEnv()
    var compat = NiriShellCompatEnv()
    let env =
      if profile.niriCompat:
        compat = prepareNiriShellCompatEnv(niriSocketPath, baseEnv = baseEnv)
        runner.overlayProcesses.add(compat.pendingProcesses)
        spawnInfo = shellCompatBehaviorPayload(profile, niriSocketPath, compat)
        let niriSocketAccepting = niriCompatSocketReady(compat.niriSocketPath)
        spawnInfo["niri_socket_accepting"] = %niriSocketAccepting
        if not niriSocketAccepting:
          warn "Niri compatibility socket is not accepting connections before shell launch",
            profile = profile.name, niriSocket = compat.niriSocketPath
          writeShellBehaviorEvent(
            "shell_compat_socket_unavailable", shells, profile, reason, spawnInfo
          )
        if compat.warning.len > 0:
          warn "Shell compatibility environment is incomplete",
            profile = profile.name, warning = compat.warning
          writeShellBehaviorEvent(
            "shell_compat_warning", shells, profile, reason, spawnInfo
          )
        compat.env
      else:
        baseEnv
    writeShellBehaviorEvent("shell_spawn_requested", shells, profile, reason, spawnInfo)
    let p = startProcess(
      profile.launch[0],
      args = profile.launch.commandArgs(),
      env = env,
      options = InheritedProcessOptions,
    )
    if runner.pendingLaunchActive:
      let nowMs = currentUnixMs()
      var stale = initTrackedChild(runner.pendingLaunch.process, nowMs, 250'i64)
      stale.beginTermination(nowMs, 250'i64)
      runner.terminatingShells.add(stale)
      runner.pendingLaunchActive = false
    runner.pendingLaunch = PendingShellLaunch(
      process: newProcessHandle(p),
      profile: profile,
      shells: shells,
      niriSocketPath: niriSocketPath,
      reason: reason,
      spawnInfo: spawnInfo,
      startedAtMs: currentUnixMs(),
      retryAllowed: retryAllowed,
    )
    runner.pendingLaunchActive = true
    result = ShellSpawnStatus.Running
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
      spawnInfo.shellSpawnEventPayload(error = e.msg),
    )

proc advanceShellLifecycle*(
    runner: var ShellRunner,
    model: Model,
    niriSocketPath: string,
    nowMs = currentUnixMs(),
) =
  if not runner.pendingLaunchActive:
    return

  let launch = runner.pendingLaunch
  let code = launch.process.peekExitCode()
  if code != -1:
    runner.pendingLaunchActive = false
    let eventName =
      if code == 0: "shell_spawn_handoff" else: "shell_spawn_exited"
    writeShellBehaviorEvent(
      eventName,
      launch.shells,
      launch.profile,
      launch.reason,
      shellSpawnEventPayload(
        launch.spawnInfo, childPid = launch.process.processID(), exitCode = some(code)
      ),
    )
    launch.process.closeProcessHandle()
    if launch.retryAllowed:
      runner.stopShellProfile(
        model,
        launch.shells,
        launch.profile,
        launch.reason & " stale instance",
        stopTracked = false,
      )
      discard runner.spawnShellProfile(
        model,
        launch.shells,
        launch.profile,
        launch.niriSocketPath,
        launch.reason & " restart",
        retryAllowed = false,
      )
    else:
      let attemptsBefore = runner.recoveryAttempts
      runner.scheduleShellRecovery(
        model,
        launch.reason & " restart",
        if code == 0: ShellSpawnStatus.Handoff else: ShellSpawnStatus.Failed,
        nowMs,
      )
      runner.recoveryAttempts = attemptsBefore
      runner.nextRecoveryMs = nowMs + attemptsBefore.recoveryDelayMs()
  elif nowMs - launch.startedAtMs >= 250'i64:
    runner.pendingLaunchActive = false
    runner.trackedProcess = launch.process
    runner.trackedShellName = launch.profile.name
    writeShellBehaviorEvent(
      "shell_spawned",
      launch.shells,
      launch.profile,
      launch.reason,
      shellSpawnEventPayload(launch.spawnInfo, childPid = launch.process.processID()),
    )

proc activeShellProfile(
    model: Model
): tuple[shells: ShellsConfig, profile: Option[ShellProfileConfig]] =
  result.shells = model.effectiveShells()
  result.profile = result.shells.activeShellProfile()

proc stopStaleShellProfiles*(runner: var ShellRunner, model: Model, reason: string) =
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
    runner: var ShellRunner, model: Model, nowMs = currentUnixMs()
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
      runner.scheduleShellRecovery(
        model, "shell watchdog process exit", ShellSpawnStatus.Failed, nowMs
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
    runner: var ShellRunner,
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
    runner.stopTrackedShell(reason & " stop")

  if current.profile.isSome:
    let status = runner.spawnShellProfile(
      currentModel, current.shells, current.profile.get(), niriSocketPath, reason
    )
    if not status.succeeded():
      runner.scheduleShellRecovery(currentModel, reason, status)
  else:
    runner.clearShellRecovery()

proc pollShellRecovery*(
    runner: var ShellRunner,
    model: Model,
    niriSocketPath: string,
    nowMs = currentUnixMs(),
): bool =
  let active = model.activeShellProfile()
  if active.profile.isNone:
    runner.clearShellRecovery()
    return false
  if runner.trackedShellRunning():
    if runner.recoveryPending:
      writeShellBehaviorEvent(
        "shell_recovery_succeeded",
        active.shells,
        active.profile.get(),
        runner.recoveryReason,
        %*{"attempt": runner.recoveryAttempts, "already_running": true},
      )
    runner.clearShellRecovery()
    return false
  if not runner.recoveryPending or nowMs < runner.nextRecoveryMs:
    return false

  if runner.recoveryAttempts >= MaxShellRecoveryAttempts:
    writeShellBehaviorEvent(
      "shell_recovery_exhausted",
      active.shells,
      active.profile.get(),
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts},
    )
    runner.clearShellRecovery()
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

  if runner.recoveryAttempts >= MaxShellRecoveryAttempts:
    writeShellBehaviorEvent(
      "shell_recovery_exhausted",
      active.shells,
      active.profile.get(),
      runner.recoveryReason,
      %*{"attempts": runner.recoveryAttempts, "status": $status},
    )
    if runner.pendingLaunchActive:
      runner.pendingLaunch.process.closeProcessHandle()
      runner.pendingLaunchActive = false
    runner.clearShellRecovery()
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

proc scheduleShellSpawn*(runner: var ShellRunner, model: Model) =
  runner.spawnPending = model.activeShellProfile().profile.isSome

proc spawnPendingShell*(
    runner: var ShellRunner, model: Model, niriSocketPath, reason: string
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
      runner.scheduleShellRecovery(model, reason & " restart", restartStatus)
