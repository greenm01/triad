import wayland/native/client
import ../core/[defaults, effects, msg, restore_state, shell_profiles]
import ../systems/[binding_profiles, runtime, runtime_facade]
import ../state/engine
import ../session/[logs as session_logs, session_runner, supervisor]
import ../types/[model, shell_snapshot]
import ../types/layout_projection
import ../types/projection_values
import ../config/[parser, reload_policy]
from ../ipc/niri_shell_compat import chooseNiriCompatSocketPath
import ../ipc/[binding_dispatch, command_help, commands, socket]
import ../janet/runtime as janet_runtime
import ../types/janet_layouts
import ../utils/[behavior_log, event_poll, runtime_log, session_env, wayland_runtime]
import
  bindings_runtime, child_process_runtime, effects_runtime, input_runtime,
  ipc_broadcast_runtime, janet_script_runtime, live_restore_runtime, manage_requests,
  message_queue, memory_status, output_management_runtime, process_runner,
  protocol_diagnostics, shell_runner, registry_runtime, reload_runtime, render_runtime,
  render_invalidation, spawn_context, state, switch_event_runtime
from ../types/runtime_values import Direction, nil, PointerOpKind
import
  std/[
    asyncdispatch, asyncnet, json, nativesockets, options, os, sequtils, strutils,
    tables, times, selectors,
  ]
import fsnotify, chronicles

var daemon = initTriadDaemon()
var lastRuntimeLoopSampleIpcCounters: IpcPerfCounters

const
  IdleWakeIntervalMs = 250
  RecentFocusTickIntervalMs = 50
  AnimationTickIntervalMs = int64(DefaultFrameIntervalMs)
  MaintenancePollIntervalMs = 250'i64
  ChildReapPollIntervalMs = 1_000'i64
  MemoryMaintenanceIntervalMs = 1_000'i64
  RuntimeLoopSampleIntervalMs = 1_000'i64
  IpcListenReadyTimeoutMs = 1_000

proc failCli(message: string) =
  stderr.writeLine("triad: " & message)
  quit 1

proc validateRiverProtocolCompatibility(daemon: TriadDaemon) =
  let diagnostics = riverProtocolDiagnostics(daemon.advertisedProtocolVersions)
  for issue in diagnostics.warningIssues:
    warn "River optional protocol unavailable",
      protocol = issue.interfaceName,
      feature = issue.feature,
      advertisedVersion = issue.advertisedVersion,
      requiredVersion = issue.requiredVersion,
      missing = issue.missing,
      message = issue.message
  if diagnostics.fatalIssues.len > 0:
    for issue in diagnostics.fatalIssues:
      fatal "River protocol requirement failed",
        protocol = issue.interfaceName,
        feature = issue.feature,
        advertisedVersion = issue.advertisedVersion,
        requiredVersion = issue.requiredVersion,
        missing = issue.missing,
        message = issue.message
    quit 1

  info "River protocol compatibility",
    required = "ok", optionalWarnings = diagnostics.warningIssues.len

proc configPathFromArgs(args: seq[string]): string =
  result = getEnv("TRIAD_CONFIG", "")
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg in ["-c", "--config"]:
      if i + 1 >= args.len:
        failCli(arg & " requires a config path")
      result = args[i + 1]
      inc i
    elif arg.startsWith("--config="):
      result = arg["--config=".len ..^ 1]
    inc i

  if result.len > 0:
    result = result.absoluteConfigPath()
  else:
    result = defaultConfigPath().absoluteConfigPath()

proc validateConfigFromArgs(args: seq[string]) =
  let configPath = configPathFromArgs(args)
  let loaded = loadConfigStrict(configPath)
  if not loaded.ok:
    stderr.writeLine("triad: config invalid: " & loaded.error)
    quit 1
  let janetError = validateJanetConfig(loaded.config.janet)
  if janetError.len > 0:
    stderr.writeLine("triad: config invalid: " & janetError)
    quit 1
  stdout.writeLine("triad: config valid: " & configPath)
  quit 0

proc syncRuntimeUpdate(context: string, msg: Msg): seq[Effect] =
  proc evalCustomMovement(
      layoutContext: JanetLayoutContext, direction: Direction
  ): JanetLayoutMovementEvalResult =
    daemon.janetRuntime.evalLayoutMovementDetailed(
      daemon.runtimeState.readRuntimeSnapshot(), layoutContext, direction
    )

  daemon.runtimeState.applyRuntimeUpdate(msg, evalCustomMovement)

proc syncRuntimeLayoutProjection(context: string, msg: Msg): LayoutProjection =
  proc evalCustomLayout(context: JanetLayoutContext): JanetLayoutEvalResult =
    daemon.janetRuntime.evalLayoutDetailed(
      daemon.runtimeState.readRuntimeSnapshot(), context
    )

  daemon.runtimeState.applyRuntimeLayoutProjection(context, $msg.kind, evalCustomLayout)

proc refreshRateFps(refreshRate: int32): int32 =
  if refreshRate <= 0:
    return 0
  max(1'i32, (refreshRate + 500) div 1000)

proc frameRate(model: Model): int32 =
  if model.frameRate > 0:
    return min(MaxFrameRate, max(MinFrameRate, model.frameRate))

  let active = model.outputData(model.activeOutput)
  if active.isSome:
    let fps = active.get().refreshRate.refreshRateFps()
    if fps > 0:
      return min(MaxFrameRate, max(MinFrameRate, fps))

  let primary = model.outputData(model.primaryOutput)
  if primary.isSome:
    let fps = primary.get().refreshRate.refreshRateFps()
    if fps > 0:
      return min(MaxFrameRate, max(MinFrameRate, fps))

  FallbackFrameRate

proc frameIntervalMs(fps: int32): int =
  if fps == FallbackFrameRate:
    return int(DefaultFrameIntervalMs)
  max(1, int(1000.0 / float(max(1'i32, fps)) + 0.5))

proc targetFrameIntervalMs(daemon: TriadDaemon): int =
  daemon.runtimeState.model.frameRate().frameIntervalMs()

proc unixMs(): int64 =
  int64(epochTime() * 1000.0)

proc cursorShakeTickNeeded(daemon: TriadDaemon): bool =
  for state in daemon.cursorShakeBySeat.values:
    if state.enlarged:
      return true

proc cursorVisibilityTickNeeded(daemon: TriadDaemon, nowMs: int64): bool =
  if daemon.runtimeState.model.cursor.hideAfterInactiveMs <= 0:
    return daemon.cursorHiddenPointers.len > 0
  let delay = int64(daemon.runtimeState.model.cursor.hideAfterInactiveMs)
  for pointerId, lastMotion in daemon.cursorLastMotionMsByPointer.pairs:
    if not daemon.cursorHiddenPointers.getOrDefault(pointerId, false):
      if nowMs - lastMotion >= delay and daemon.cursorShapeDevices.hasKey(pointerId) and
          daemon.wlPointerGlobalNames.hasKey(pointerId) and
          daemon.wlPointerPointers.hasKey(daemon.wlPointerGlobalNames[pointerId]):
        return true

proc frameTickNeeded(daemon: TriadDaemon, nowMs: int64): bool =
  daemon.runtimeState.model.needsFrameTick() or daemon.cursorShakeTickNeeded() or
    daemon.cursorVisibilityTickNeeded(nowMs)

proc frameTickNeeded(daemon: TriadDaemon): bool =
  daemon.frameTickNeeded(unixMs())

proc frameTickReasons(daemon: TriadDaemon, nowMs: int64): seq[string] =
  result = daemon.runtimeState.model.frameTickReasons()
  if daemon.cursorShakeTickNeeded():
    result.add("cursor-shake")
  if daemon.cursorVisibilityTickNeeded(nowMs):
    result.add("cursor-visibility")

proc frameTickReasons(daemon: TriadDaemon): seq[string] =
  daemon.frameTickReasons(unixMs())

proc reasonsNeedFrameRate(reasons: seq[string]): bool =
  for reason in reasons:
    if reason != "recent-focus":
      return true
  false

proc tickIntervalMs(daemon: TriadDaemon, reasons: seq[string]): int64 =
  if reasons.reasonsNeedFrameRate():
    return max(int64(daemon.targetFrameIntervalMs()), AnimationTickIntervalMs)
  int64(RecentFocusTickIntervalMs)

proc pollDue(lastPollMs, nowMs, intervalMs: int64): bool =
  lastPollMs <= 0 or nowMs - lastPollMs >= intervalMs

proc memoryMaintenanceDue(daemon: TriadDaemon, lastPollMs, nowMs: int64): bool =
  lastPollMs.pollDue(nowMs, MemoryMaintenanceIntervalMs) or
    (daemon.memoryPressureDueMs > 0 and nowMs >= daemon.memoryPressureDueMs)

proc incrementFrameTickReasonCounts(daemon: var TriadDaemon, reasons: seq[string]) =
  for reason in reasons:
    daemon.frameTickReasonCounts[reason] =
      daemon.frameTickReasonCounts.getOrDefault(reason, 0'u64) + 1'u64

proc enqueueFrameTickIfDue(daemon: var TriadDaemon, nowMs: int64) =
  let reasons = daemon.frameTickReasons(nowMs)
  if reasons.len == 0:
    daemon.lastFrameTickMs = nowMs
    return
  if daemon.lastFrameTickMs <= 0:
    daemon.lastFrameTickMs = nowMs
  let elapsedMs = nowMs - daemon.lastFrameTickMs
  let tickInterval = daemon.tickIntervalMs(reasons)
  if elapsedMs < tickInterval:
    return
  daemon.lastFrameTickMs = nowMs
  daemon.incrementFrameTickReasonCounts(reasons)
  daemon.enqueue(
    Msg(
      kind: MsgKind.CmdTick, tickElapsedMs: int32(max(1'i64, min(1000'i64, elapsedMs)))
    )
  )

proc nextShellRecoveryMs(daemon: TriadDaemon): int64 =
  if daemon.shellRunner.recoveryPending: daemon.shellRunner.nextRecoveryMs else: 0'i64

proc loopWaitTimeoutMs(daemon: TriadDaemon, nowMs: int64): int =
  result = IdleWakeIntervalMs
  if daemon.frameTickNeeded(nowMs):
    let reasons = daemon.frameTickReasons(nowMs)
    let tickInterval = daemon.tickIntervalMs(reasons)
    let elapsedMs =
      if daemon.lastFrameTickMs <= 0:
        tickInterval
      else:
        nowMs - daemon.lastFrameTickMs
    result = max(1, int(max(1'i64, tickInterval - elapsedMs)))
  if daemon.configReloadDebouncer.pending:
    result = min(result, max(1, int(daemon.configReloadDebouncer.deadlineMs - nowMs)))
  let recoveryMs = daemon.nextShellRecoveryMs()
  if recoveryMs > 0:
    result = min(result, max(1, int(recoveryMs - nowMs)))

proc asyncSelectorFd(): int =
  asyncdispatch.getGlobalDispatcher().getIoHandler().getFd()

proc waitForRuntimeEvents(
    daemon: var TriadDaemon, timeoutMs: int
): RuntimeEventPollResult =
  let waylandFd =
    if daemon.display == nil:
      -1
    else:
      daemon.display.get_fd()
  daemon.eventSwitchFds.setLen(0)
  for device in daemon.switchEventDevices:
    daemon.eventSwitchFds.add(device.fd)

  daemon.lastWaitTimeoutMs = timeoutMs
  let asyncFd = asyncSelectorFd()
  daemon.waitBackend = if asyncFd >= 0: "fd-aware" else: "timeout"
  result = daemon.eventPollFds.waitForRuntimeEventFds(
    waylandFd, asyncFd, daemon.eventSwitchFds, timeoutMs
  )
  if result.failed:
    warn "Runtime event poll failed", error = osErrorMsg(result.errorCode)

proc loopCountersJson(counters: RuntimeLoopCounters): JsonNode =
  %*{
    "loop_iterations": counters.loopIterations,
    "watcher_polls": counters.watcherPolls,
    "switch_polls": counters.switchPolls,
    "child_reap_polls": counters.childReapPolls,
    "child_reaped_processes": counters.childReapedProcesses,
    "memory_sample_checks": counters.memorySampleChecks,
    "memory_compaction_checks": counters.memoryCompactionChecks,
    "async_polls": counters.asyncPolls,
    "config_reload_checks": counters.configReloadChecks,
    "config_reloads_due": counters.configReloadsDue,
    "shell_watchdog_polls": counters.shellWatchdogPolls,
    "shell_recovery_polls": counters.shellRecoveryPolls,
    "manage_flush_checks": counters.manageFlushChecks,
    "wayland_wakeups": counters.waylandWakeups,
    "async_wakeups": counters.asyncWakeups,
    "switch_wakeups": counters.switchWakeups,
  }

proc reasonCountsJson(counts: Table[string, uint64]): JsonNode =
  result = newJObject()
  for reason, count in counts.pairs:
    result[reason] = %count

proc reasonCountDeltasJson(before, after: Table[string, uint64]): JsonNode =
  result = newJObject()
  for reason, count in after.pairs:
    let previous = before.getOrDefault(reason, 0'u64)
    if count > previous:
      result[reason] = %(count - previous)

proc incCounter(counts: var Table[string, uint64], key: string) =
  counts[key] = counts.getOrDefault(key, 0'u64) + 1

proc renderCounterDeltasJson(before, after: RenderPerfCounters): JsonNode =
  %*{
    "frame_ticks": after.frameTicks - before.frameTicks,
    "active_frame_ticks": after.activeFrameTicks - before.activeFrameTicks,
    "dirty_frame_ticks": after.dirtyFrameTicks - before.dirtyFrameTicks,
    "render_starts": after.renderStarts - before.renderStarts,
    "skipped_render_starts": after.skippedRenderStarts - before.skippedRenderStarts,
    "render_layout_projections":
      after.renderLayoutProjections - before.renderLayoutProjections,
    "render_requests": after.renderRequests - before.renderRequests,
    "skipped_render_requests":
      after.skippedRenderRequests - before.skippedRenderRequests,
    "manage_requests": after.manageRequests - before.manageRequests,
    "skipped_animation_manages":
      after.skippedAnimationManages - before.skippedAnimationManages,
    "skipped_noop_manages": after.skippedNoopManages - before.skippedNoopManages,
    "render_start_callback_skips":
      after.renderStartCallbackSkips - before.renderStartCallbackSkips,
    "render_start_queued_skips":
      after.renderStartQueuedSkips - before.renderStartQueuedSkips,
    "dimension_proposals": after.dimensionProposals - before.dimensionProposals,
    "skipped_dimension_proposals":
      after.skippedDimensionProposals - before.skippedDimensionProposals,
  }

proc ipcCounterDeltasJson(before, after: IpcPerfCounters): JsonNode =
  %*{
    "requests": after.requests - before.requests,
    "dev_mode_requests": after.devModeRequests - before.devModeRequests,
    "live_restore_requests": after.liveRestoreRequests - before.liveRestoreRequests,
    "perf_status_requests": after.perfStatusRequests - before.perfStatusRequests,
    "mem_status_requests": after.memStatusRequests - before.memStatusRequests,
    "triad_requests": after.triadRequests - before.triadRequests,
    "niri_requests": after.niriRequests - before.niriRequests,
    "text_commands": after.textCommands - before.textCommands,
    "binding_dispatch_requests":
      after.bindingDispatchRequests - before.bindingDispatchRequests,
    "invalid_requests": after.invalidRequests - before.invalidRequests,
    "dispatched_messages": after.dispatchedMessages - before.dispatchedMessages,
    "niri_subscriptions": after.niriSubscriptions - before.niriSubscriptions,
    "triad_subscriptions": after.triadSubscriptions - before.triadSubscriptions,
    "niri_broadcasts": after.niriBroadcasts - before.niriBroadcasts,
    "triad_broadcasts": after.triadBroadcasts - before.triadBroadcasts,
    "niri_broadcast_sends": after.niriBroadcastSends - before.niriBroadcastSends,
    "triad_broadcast_sends": after.triadBroadcastSends - before.triadBroadcastSends,
    "niri_broadcast_queued": after.niriBroadcastQueued - before.niriBroadcastQueued,
    "triad_broadcast_queued": after.triadBroadcastQueued - before.triadBroadcastQueued,
    "niri_broadcast_coalesced":
      after.niriBroadcastCoalesced - before.niriBroadcastCoalesced,
    "triad_broadcast_coalesced":
      after.triadBroadcastCoalesced - before.triadBroadcastCoalesced,
    "niri_broadcast_skipped_no_subscribers":
      after.niriBroadcastSkippedNoSubscribers - before.niriBroadcastSkippedNoSubscribers,
    "triad_broadcast_skipped_no_subscribers":
      after.triadBroadcastSkippedNoSubscribers -
      before.triadBroadcastSkippedNoSubscribers,
    "niri_broadcast_skipped_duplicate":
      after.niriBroadcastSkippedDuplicate - before.niriBroadcastSkippedDuplicate,
    "triad_broadcast_skipped_duplicate":
      after.triadBroadcastSkippedDuplicate - before.triadBroadcastSkippedDuplicate,
    "triad_broadcast_skipped_duplicate_by_event":
      after.triadBroadcastSkippedDuplicateByEvent -
      before.triadBroadcastSkippedDuplicateByEvent,
    "niri_broadcast_skipped_filtered":
      after.niriBroadcastSkippedFiltered - before.niriBroadcastSkippedFiltered,
    "niri_broadcast_queued_bytes":
      after.niriBroadcastQueuedBytes - before.niriBroadcastQueuedBytes,
    "triad_broadcast_queued_bytes":
      after.triadBroadcastQueuedBytes - before.triadBroadcastQueuedBytes,
    "niri_broadcast_sent_bytes":
      after.niriBroadcastSentBytes - before.niriBroadcastSentBytes,
    "triad_broadcast_sent_bytes":
      after.triadBroadcastSentBytes - before.triadBroadcastSentBytes,
    "niri_broadcast_skipped_bytes":
      after.niriBroadcastSkippedBytes - before.niriBroadcastSkippedBytes,
    "triad_broadcast_skipped_bytes":
      after.triadBroadcastSkippedBytes - before.triadBroadcastSkippedBytes,
    "dropped_subscribers": after.droppedSubscribers - before.droppedSubscribers,
  }

proc ipcCountersJson(counters: IpcPerfCounters): JsonNode =
  %*{
    "requests": counters.requests,
    "dev_mode_requests": counters.devModeRequests,
    "live_restore_requests": counters.liveRestoreRequests,
    "perf_status_requests": counters.perfStatusRequests,
    "mem_status_requests": counters.memStatusRequests,
    "triad_requests": counters.triadRequests,
    "niri_requests": counters.niriRequests,
    "text_commands": counters.textCommands,
    "binding_dispatch_requests": counters.bindingDispatchRequests,
    "invalid_requests": counters.invalidRequests,
    "dispatched_messages": counters.dispatchedMessages,
    "niri_subscriptions": counters.niriSubscriptions,
    "triad_subscriptions": counters.triadSubscriptions,
    "niri_broadcasts": counters.niriBroadcasts,
    "triad_broadcasts": counters.triadBroadcasts,
    "niri_broadcast_sends": counters.niriBroadcastSends,
    "triad_broadcast_sends": counters.triadBroadcastSends,
    "niri_broadcast_queued": counters.niriBroadcastQueued,
    "triad_broadcast_queued": counters.triadBroadcastQueued,
    "niri_broadcast_coalesced": counters.niriBroadcastCoalesced,
    "triad_broadcast_coalesced": counters.triadBroadcastCoalesced,
    "niri_broadcast_skipped_no_subscribers": counters.niriBroadcastSkippedNoSubscribers,
    "triad_broadcast_skipped_no_subscribers":
      counters.triadBroadcastSkippedNoSubscribers,
    "niri_broadcast_skipped_duplicate": counters.niriBroadcastSkippedDuplicate,
    "triad_broadcast_skipped_duplicate": counters.triadBroadcastSkippedDuplicate,
    "triad_broadcast_skipped_duplicate_by_event":
      counters.triadBroadcastSkippedDuplicateByEvent,
    "niri_broadcast_skipped_filtered": counters.niriBroadcastSkippedFiltered,
    "niri_broadcast_queued_bytes": counters.niriBroadcastQueuedBytes,
    "triad_broadcast_queued_bytes": counters.triadBroadcastQueuedBytes,
    "niri_broadcast_sent_bytes": counters.niriBroadcastSentBytes,
    "triad_broadcast_sent_bytes": counters.triadBroadcastSentBytes,
    "niri_broadcast_skipped_bytes": counters.niriBroadcastSkippedBytes,
    "triad_broadcast_skipped_bytes": counters.triadBroadcastSkippedBytes,
    "dropped_subscribers": counters.droppedSubscribers,
  }

proc delta(after, before: RuntimeLoopCounters): RuntimeLoopCounters =
  RuntimeLoopCounters(
    loopIterations: after.loopIterations - before.loopIterations,
    watcherPolls: after.watcherPolls - before.watcherPolls,
    switchPolls: after.switchPolls - before.switchPolls,
    childReapPolls: after.childReapPolls - before.childReapPolls,
    childReapedProcesses: after.childReapedProcesses - before.childReapedProcesses,
    memorySampleChecks: after.memorySampleChecks - before.memorySampleChecks,
    memoryCompactionChecks: after.memoryCompactionChecks - before.memoryCompactionChecks,
    asyncPolls: after.asyncPolls - before.asyncPolls,
    configReloadChecks: after.configReloadChecks - before.configReloadChecks,
    configReloadsDue: after.configReloadsDue - before.configReloadsDue,
    shellWatchdogPolls: after.shellWatchdogPolls - before.shellWatchdogPolls,
    shellRecoveryPolls: after.shellRecoveryPolls - before.shellRecoveryPolls,
    manageFlushChecks: after.manageFlushChecks - before.manageFlushChecks,
    waylandWakeups: after.waylandWakeups - before.waylandWakeups,
    asyncWakeups: after.asyncWakeups - before.asyncWakeups,
    switchWakeups: after.switchWakeups - before.switchWakeups,
  )

proc maybeWriteRuntimeLoopSample(daemon: var TriadDaemon, nowMs: int64) =
  if daemon.lastRuntimeLoopSampleMs == 0:
    daemon.lastRuntimeLoopSampleMs = nowMs
    daemon.lastRuntimeLoopSampleCounters = daemon.loopCounters
    daemon.lastRuntimeLoopSamplePerfCounters = daemon.perfCounters
    daemon.lastRuntimeLoopSampleFrameTickReasonCounts = daemon.frameTickReasonCounts
    daemon.lastRuntimeLoopSampleManageRequestReasonCounts =
      daemon.manageRequestReasonCounts
    daemon.lastRuntimeLoopSampleMessageKindCounts = daemon.messageKindCounts
    daemon.lastRuntimeLoopSampleEffectKindCounts = daemon.effectKindCounts
    daemon.lastRuntimeLoopSampleIpcEventCounts = ipcBroadcastEventCounts
    lastRuntimeLoopSampleIpcCounters = ipcPerfCounters
    return
  if nowMs - daemon.lastRuntimeLoopSampleMs < RuntimeLoopSampleIntervalMs:
    return

  let previousMs = daemon.lastRuntimeLoopSampleMs
  let previousLoopCounters = daemon.lastRuntimeLoopSampleCounters
  let previousPerfCounters = daemon.lastRuntimeLoopSamplePerfCounters
  let previousFrameTickReasonCounts = daemon.lastRuntimeLoopSampleFrameTickReasonCounts
  let previousManageRequestReasonCounts =
    daemon.lastRuntimeLoopSampleManageRequestReasonCounts
  let previousMessageKindCounts = daemon.lastRuntimeLoopSampleMessageKindCounts
  let previousEffectKindCounts = daemon.lastRuntimeLoopSampleEffectKindCounts
  let previousIpcEventCounts = daemon.lastRuntimeLoopSampleIpcEventCounts
  let previousIpcCounters = lastRuntimeLoopSampleIpcCounters
  daemon.lastRuntimeLoopSampleMs = nowMs
  daemon.lastRuntimeLoopSampleCounters = daemon.loopCounters
  daemon.lastRuntimeLoopSamplePerfCounters = daemon.perfCounters
  daemon.lastRuntimeLoopSampleFrameTickReasonCounts = daemon.frameTickReasonCounts
  daemon.lastRuntimeLoopSampleManageRequestReasonCounts =
    daemon.manageRequestReasonCounts
  daemon.lastRuntimeLoopSampleMessageKindCounts = daemon.messageKindCounts
  daemon.lastRuntimeLoopSampleEffectKindCounts = daemon.effectKindCounts
  daemon.lastRuntimeLoopSampleIpcEventCounts = ipcBroadcastEventCounts
  lastRuntimeLoopSampleIpcCounters = ipcPerfCounters

  if not behaviorLogEnabled():
    return

  writeBehaviorEvent(
    "runtime_loop_sample",
    %*{
      "interval_ms": nowMs - previousMs,
      "wait_timeout_ms": daemon.lastWaitTimeoutMs,
      "wait_backend": daemon.waitBackend,
      "frame_tick_active": daemon.frameTickNeeded(),
      "frame_tick_reasons": daemon.frameTickReasons(),
      "queue_len": daemon.msgQueue.len,
      "render_dirty": daemon.renderDirty,
      "render_dirty_reason": daemon.renderDirtyReason,
      "loop_counters":
        daemon.loopCounters.delta(previousLoopCounters).loopCountersJson(),
      "render_counters":
        previousPerfCounters.renderCounterDeltasJson(daemon.perfCounters),
      "frame_tick_reason_counts": previousFrameTickReasonCounts.reasonCountDeltasJson(
        daemon.frameTickReasonCounts
      ),
      "manage_request_reason_counts": previousManageRequestReasonCounts.reasonCountDeltasJson(
        daemon.manageRequestReasonCounts
      ),
      "message_kind_counts":
        previousMessageKindCounts.reasonCountDeltasJson(daemon.messageKindCounts),
      "effect_kind_counts":
        previousEffectKindCounts.reasonCountDeltasJson(daemon.effectKindCounts),
      "ipc_event_counts":
        previousIpcEventCounts.reasonCountDeltasJson(ipcBroadcastEventCounts),
      "ipc_counters": previousIpcCounters.ipcCounterDeltasJson(ipcPerfCounters),
    },
  )

proc perfStatusJson(daemon: TriadDaemon): string =
  let counters = daemon.perfCounters
  let triadScopes = triadSubscriberScopeCounts()
  var manageRequestReasons = newJObject()
  for reason, count in daemon.manageRequestReasonCounts.pairs:
    manageRequestReasons[reason] = %int(count)
  let recentDelta =
    if daemon.lastRuntimeLoopSampleMs > 0:
      %*{
        "interval_ms": unixMs() - daemon.lastRuntimeLoopSampleMs,
        "loop_counters": daemon.loopCounters
          .delta(daemon.lastRuntimeLoopSampleCounters)
          .loopCountersJson(),
        "render_counters": daemon.lastRuntimeLoopSamplePerfCounters.renderCounterDeltasJson(
          daemon.perfCounters
        ),
        "frame_tick_reason_counts": daemon.lastRuntimeLoopSampleFrameTickReasonCounts.reasonCountDeltasJson(
          daemon.frameTickReasonCounts
        ),
        "manage_request_reasons": daemon.lastRuntimeLoopSampleManageRequestReasonCounts.reasonCountDeltasJson(
          daemon.manageRequestReasonCounts
        ),
        "message_kind_counts": daemon.lastRuntimeLoopSampleMessageKindCounts.reasonCountDeltasJson(
          daemon.messageKindCounts
        ),
        "effect_kind_counts": daemon.lastRuntimeLoopSampleEffectKindCounts.reasonCountDeltasJson(
          daemon.effectKindCounts
        ),
        "ipc_event_counts": daemon.lastRuntimeLoopSampleIpcEventCounts.reasonCountDeltasJson(
          ipcBroadcastEventCounts
        ),
        "ipc_counters":
          lastRuntimeLoopSampleIpcCounters.ipcCounterDeltasJson(ipcPerfCounters),
        "subscribers": {
          "niri": subscribers.len,
          "triad": triadSubscribers.len,
          "triad_layout_only": triadScopes.layoutOnly,
          "triad_state_only": triadScopes.stateOnly,
          "triad_layout_and_state": triadScopes.layoutAndState,
          "triad_window": triadScopes.window,
          "total": subscribers.len + triadSubscribers.len,
        },
      }
    else:
      newJObject()
  $(
    %*{
      "ok": true,
      "type": "perf-status",
      "pid": getCurrentProcessId(),
      "frame_rate": daemon.runtimeState.model.frameRate(),
      "frame_interval_ms": daemon.targetFrameIntervalMs(),
      "idle_wake_interval_ms": IdleWakeIntervalMs,
      "current_wait_timeout_ms": daemon.lastWaitTimeoutMs,
      "wait_backend": daemon.waitBackend,
      "frame_tick_active": daemon.frameTickNeeded(),
      "frame_tick_reasons": daemon.frameTickReasons(),
      "counters": {
        "frame_ticks": counters.frameTicks,
        "active_frame_ticks": counters.activeFrameTicks,
        "dirty_frame_ticks": counters.dirtyFrameTicks,
        "render_starts": counters.renderStarts,
        "skipped_render_starts": counters.skippedRenderStarts,
        "render_layout_projections": counters.renderLayoutProjections,
        "render_requests": counters.renderRequests,
        "skipped_render_requests": counters.skippedRenderRequests,
        "manage_requests": counters.manageRequests,
        "skipped_animation_manages": counters.skippedAnimationManages,
        "skipped_noop_manages": counters.skippedNoopManages,
        "render_start_callback_skips": counters.renderStartCallbackSkips,
        "render_start_queued_skips": counters.renderStartQueuedSkips,
        "dimension_proposals": counters.dimensionProposals,
        "skipped_dimension_proposals": counters.skippedDimensionProposals,
      },
      "loop_counters": daemon.loopCounters.loopCountersJson(),
      "ipc_counters": ipcPerfCounters.ipcCountersJson(),
      "subscribers": {
        "niri": subscribers.len,
        "triad": triadSubscribers.len,
        "triad_layout_only": triadScopes.layoutOnly,
        "triad_state_only": triadScopes.stateOnly,
        "triad_layout_and_state": triadScopes.layoutAndState,
        "triad_window": triadScopes.window,
        "total": subscribers.len + triadSubscribers.len,
      },
      "recent_delta": recentDelta,
      "frame_tick_reason_counts": daemon.frameTickReasonCounts.reasonCountsJson(),
      "manage_request_reasons": manageRequestReasons,
    }
  )

proc specialMsgCommand(cmd: string): bool =
  cmd in ["dump-live-restore-state", "perf-status", "mem-status"] or cmd == "dev-mode" or
    cmd.startsWith("dev-mode ")

proc startStartupWindowRulesExpiry() {.async.} =
  await sleepAsync(60_000)
  {.cast(gcsafe).}:
    daemon.enqueue(Msg(kind: MsgKind.CmdExpireStartupWindowRules))

proc processQueuedMessages(configPath, niriSocketPath: string): bool =
  while daemon.hasQueuedMessages():
    let queued = daemon.popQueuedMessageWithOrigin()
    let msg = queued.msg
    daemon.messageKindCounts.incCounter($msg.kind)

    if msg.kind == MsgKind.WlPointerRelease:
      if daemon.runtimeState.model.pointerOp.kind != PointerOpKind.OpNone:
        if daemon.lastPointerOpSeat != nil:
          daemon.executeEffect(
            Effect(kind: EffectKind.EffOpEnd, endSeat: daemon.lastPointerOpSeat)
          )

    if msg.kind == MsgKind.CmdSpawnTerminal:
      let process = spawnTerminal(daemon.runtimeState.model)
      daemon.rememberSpawnPlacement(
        process, daemon.runtimeState.model, "spawn-terminal"
      )
      daemon.trackChildProcess(process)
      continue

    if msg.kind == MsgKind.CmdConfigReload:
      if daemon.applyConfigReload(configPath, niriSocketPath):
        daemon.janetRuntime.configure(daemon.runtimeState.model.janet)
        daemon.configureSwitchEventRuntime("config reload")
        result = true
      continue

    if msg.kind == MsgKind.WlRenderStart:
      inc daemon.perfCounters.renderStarts
      daemon.riverPhase = RiverPhase.RiverRender
      if daemon.canSkipRenderStart():
        inc daemon.perfCounters.skippedRenderStarts
        inc daemon.perfCounters.renderStartQueuedSkips
        daemon.executeEffect(Effect(kind: EffectKind.EffRenderFinish))
        daemon.riverPhase = RiverPhase.RiverIdle
        continue
      inc daemon.perfCounters.renderLayoutProjections
      let projection = syncRuntimeLayoutProjection("render layout", msg)
      daemon.currentFrameTabBars = projection.frameTabBars
      daemon.currentFrameEmptyChrome = projection.frameEmptyChrome
      daemon.currentBspPreselections = projection.bspPreselections
      daemon.recordDesiredPlacements(projection.instructions)
      daemon.renderDesiredPlacements()
      for windowId in daemon.runtimeState.pendingAdmissionWindowIds():
        daemon.enqueue(
          Msg(kind: MsgKind.WlWindowAdmissionSettled, admissionWindowId: windowId)
        )
      daemon.executeEffect(Effect(kind: EffectKind.EffRenderFinish))
      daemon.markRenderCleanAfterFullRender()
      daemon.riverPhase = RiverPhase.RiverIdle
      continue

    if msg.kind == MsgKind.CmdTick:
      inc daemon.perfCounters.frameTicks
      if daemon.frameTickNeeded():
        inc daemon.perfCounters.activeFrameTicks
      daemon.tickCursorShake()
      daemon.tickCursorVisibility()

    let previousModelForShell =
      if msg.kind in {MsgKind.CmdSwitchShell, MsgKind.CmdCycleShell}:
        some(daemon.runtimeState.model)
      else:
        none(Model)
    let previousOverview = daemon.runtimeState.model.overviewActive
    let previousRecentWindows = daemon.runtimeState.model.recentWindowsActive
    let previousSessionLocked = daemon.runtimeState.model.sessionLocked
    let previousExitSessionConfirm = daemon.runtimeState.model.exitSessionConfirmOpen
    let previousActiveModifiers = daemon.runtimeState.model.activeModifiers
    let previousLayoutBindingId = daemon.runtimeState.model.activeLayoutBindingId()
    let previousPointerOpActive =
      daemon.runtimeState.model.pointerOp.kind != PointerOpKind.OpNone
    let previousShortcutsInhibited =
      daemon.runtimeState.model.keyboardShortcutsInhibited()
    let dispatchJanetHooks =
      queued.origin != QueuedMsgOrigin.JanetHook and
      msg.kind.shouldDispatchJanetScripts()
    let dispatchJanetUiHooks = queued.origin.shouldDispatchJanetUiScripts()
    let beforeJanetHookSnapshot =
      if dispatchJanetHooks:
        some(daemon.readModelSnapshot())
      else:
        none(ShellSnapshot)
    let beforeJanetUiState =
      if dispatchJanetUiHooks:
        some(daemon.runtimeState.model.janetUiHookState())
      else:
        none(JanetUiHookState)
    let effects = syncRuntimeUpdate("message", msg)
    for eff in effects:
      daemon.effectKindCounts.incCounter($eff.kind)
    if msg.kind != MsgKind.WlPointerRelease and previousPointerOpActive and
        daemon.runtimeState.model.pointerOp.kind == PointerOpKind.OpNone and
        daemon.lastPointerOpSeat != nil:
      daemon.executeEffect(
        Effect(kind: EffectKind.EffOpEnd, endSeat: daemon.lastPointerOpSeat)
      )
    var nextQueuedMessages: seq[QueuedMsg] = @[]
    var afterJanetHookSnapshot = none(ShellSnapshot)
    if msg.kind == MsgKind.CmdTick and
        effects.anyIt(it.kind == EffectKind.EffManageDirty):
      inc daemon.perfCounters.dirtyFrameTicks
    if msg.kind in {MsgKind.CmdSwitchShell, MsgKind.CmdCycleShell} and
        previousModelForShell.isSome and
        not sameShellsConfig(
          previousModelForShell.get().shells, daemon.runtimeState.model.shells
        ):
      daemon.shellRunner.switchShell(
        previousModelForShell.get(),
        daemon.runtimeState.model,
        niriSocketPath,
        "command " & $msg.kind,
      )
    if msg.kind == MsgKind.WlWindowDestroyed:
      daemon.lastFullscreenRequests.del(msg.destroyedId)
      daemon.lastMaximizedRequests.del(msg.destroyedId)
      daemon.noteWindowDestroyedForMemoryPressure()
    if previousOverview and not daemon.runtimeState.model.overviewActive:
      daemon.scheduleMemoryPressureCompaction("overview_closed")
    if beforeJanetHookSnapshot.isSome:
      afterJanetHookSnapshot = some(daemon.readModelSnapshot())
      nextQueuedMessages.add(
        daemon.collectJanetScriptMessages(
          msg, beforeJanetHookSnapshot.get(), afterJanetHookSnapshot.get()
        )
      )
    if beforeJanetUiState.isSome:
      let afterJanetUiState = daemon.runtimeState.model.janetUiHookState()
      if beforeJanetUiState.get() != afterJanetUiState:
        if afterJanetHookSnapshot.isNone:
          afterJanetHookSnapshot = some(daemon.readModelSnapshot())
        nextQueuedMessages.add(
          daemon.collectJanetUiScriptMessages(
            beforeJanetUiState.get(), afterJanetUiState, afterJanetHookSnapshot.get()
          )
        )
    if nextQueuedMessages.len > 0:
      daemon.enqueueNextQueued(nextQueuedMessages)
    let recentModifiersChanged =
      daemon.runtimeState.model.recentWindowsActive and
      previousActiveModifiers != daemon.runtimeState.model.activeModifiers
    if previousOverview != daemon.runtimeState.model.overviewActive or
        previousRecentWindows != daemon.runtimeState.model.recentWindowsActive or
        previousSessionLocked != daemon.runtimeState.model.sessionLocked or
        previousExitSessionConfirm != daemon.runtimeState.model.exitSessionConfirmOpen or
        previousLayoutBindingId != daemon.runtimeState.model.activeLayoutBindingId() or
        recentModifiersChanged or
        previousShortcutsInhibited !=
        daemon.runtimeState.model.keyboardShortcutsInhibited():
      daemon.requestBindingReconfigure("binding profile changed")

    if msg.kind == MsgKind.WlManageStart:
      daemon.riverPhase = RiverPhase.RiverManage
      let manageReason = daemon.activeManageReason
      daemon.activeManageReason = ""
      let animationOnlyManage =
        manageReason == AnimationManageReason and daemon.pendingManageEffects.len == 0
      let noopManage =
        daemon.initialManageComplete and manageReason.len == 0 and
        daemon.pendingManageEffects.len == 0 and effects.len == 0 and
        not daemon.renderDirty
      if not animationOnlyManage and not noopManage:
        let projection = syncRuntimeLayoutProjection("manage layout", msg)
        daemon.currentFrameTabBars = projection.frameTabBars
        daemon.currentFrameEmptyChrome = projection.frameEmptyChrome
        daemon.currentBspPreselections = projection.bspPreselections
        daemon.proposeDesiredDimensions(projection.instructions)
        daemon.applyManageState()
        daemon.flushPendingManageEffects()
      elif animationOnlyManage:
        inc daemon.perfCounters.skippedAnimationManages
      else:
        inc daemon.perfCounters.skippedNoopManages
      for eff in effects:
        if eff.kind != EffectKind.EffManageDirty:
          daemon.executeEffect(eff)
      daemon.executeEffect(Effect(kind: EffectKind.EffManageFinish))
      daemon.riverPhase = RiverPhase.RiverIdle
      if not daemon.initialManageComplete:
        daemon.initialManageComplete = true
        info "Initial manage completed",
          outputs = daemon.outputPointers.len,
          windows = daemon.windowPointers.len,
          seats = daemon.seatPointers.len
        daemon.writeMemorySample("initial_manage_complete")
      if daemon.postManageBroadcastPending:
        let reason = daemon.postManageBroadcastReason
        daemon.postManageBroadcastPending = false
        daemon.postManageBroadcastReason = ""
        let snapshot = daemon.readModelSnapshot()
        writeBehaviorEvent(
          "niri_compat_post_manage_broadcast",
          %*{"reason": reason, "snapshot": snapshot.snapshotBehaviorPayload()},
        )
        broadcastNiriSnapshot(snapshot)
      daemon.flushIpcBroadcasts()
      continue

    for eff in effects:
      if eff.kind == EffectKind.EffManageDirty:
        daemon.requestManage("effect:" & $msg.kind)
      else:
        daemon.executeEffect(eff)
    daemon.flushIpcBroadcasts()

proc hasInitialRiverState(): bool =
  daemon.outputPointers.len > 0 or daemon.seatPointers.len > 0

proc waitForInitialRiverState(timeoutMs: int): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while not hasInitialRiverState() and epochTime() < deadline:
    if not dispatchPendingWayland(daemon.display):
      return false
    if hasInitialRiverState():
      return true
    if not prepareWaylandRead(daemon.display):
      return false
    if hasInitialRiverState():
      daemon.display.cancel_read()
      return true

    discard daemon.display.flush()
    let remainingMs = max(1, min(16, int((deadline - epochTime()) * 1000.0)))
    if waitForWaylandEvents(daemon.display, remainingMs):
      if daemon.display.read_events() == -1:
        return false
    else:
      daemon.display.cancel_read()

  hasInitialRiverState()

# --- Main Loop ---

proc main*() =
  let args = commandLineParams()
  if args.len > 0 and args[0] in ["--help", "-h", "help"]:
    stdout.writeLine(renderTriadHelp())
    return

  if args.len > 0 and args[0] in ["validate-config", "check-config"]:
    let validateArgs =
      if args.len > 1:
        args[1 ..^ 1]
      else:
        @[]
    validateConfigFromArgs(validateArgs)

  if args.len >= 1 and args[0] == "session":
    quit runSession()

  if args.len >= 1 and args[0] == "supervise":
    quit runSupervisor()

  if args.len >= 1 and args[0] == "logs":
    if args.len > 2 or (args.len == 2 and args[1] != "--json"):
      failCli("usage: triad logs [--json]")
    if args.len == 2:
      stdout.writeLine($session_logs.logsJson())
    else:
      stdout.writeLine(session_logs.renderLogs())
    return

  if args.len >= 1 and args[0] == "msg":
    if args.len < 2:
      failCli("missing msg command")
    let cmdPart = args[1]
    if cmdPart in ["--help", "-h", "help"]:
      let topic =
        if args.len > 2:
          args[2]
        else:
          ""
      stdout.writeLine(renderMsgHelp(topic))
      return

    if cmdPart == "commands":
      if args.len > 3 or (args.len == 3 and args[2] != "--json"):
        failCli("usage: triad msg commands [--json]")
      if args.len == 3:
        stdout.writeLine($commandCatalogJson())
      else:
        stdout.writeLine(renderCommandList())
      return

    if cmdPart == "validate":
      if args.len < 3:
        failCli("usage: triad msg validate <command...>")
      var validateCmd = ""
      for i in 2 ..< args.len:
        if i > 2:
          validateCmd.add(" ")
        validateCmd.add(args[i])
      if parseTextCommand(validateCmd).isNone and
          triadMsgRequestPayload(validateCmd).isNone and
          not validateCmd.specialMsgCommand():
        failCli("invalid msg command: " & validateCmd)
      stdout.writeLine("triad: msg command valid: " & validateCmd)
      return

    if cmdPart == "request":
      if args.len < 3:
        failCli("usage: triad msg request <json>")
      var request = ""
      for i in 2 ..< args.len:
        if i > 2:
          request.add(" ")
        request.add(args[i])
      try:
        let reply = waitFor sendIpcRequest(triadSocketPath(), request)
        stdout.writeLine(reply)
      except CatchableError as e:
        failCli("socket request failed: " & e.msg)
      return

    if cmdPart == "event-stream":
      var native = false
      var nativeEvents: seq[string]
      if args.len > 2:
        if args[2] != "--native":
          failCli("usage: triad msg event-stream [--native [layout,state,window]]")
        native = true
        if args.len > 4:
          failCli("usage: triad msg event-stream [--native [layout,state,window]]")
        if args.len == 4:
          nativeEvents = args[3].split(',')
      # Subscription client
      let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      try:
        waitFor client.connectUnix(triadSocketPath())
        let payload =
          if native:
            nativeEventStreamPayload(nativeEvents)
          else:
            "event-stream"
        waitFor client.send(payload & "\L")
        while not client.isClosed:
          let line = waitFor client.recvLine()
          if line != "":
            echo line
      except CatchableError as e:
        if not client.isClosed:
          client.close()
        failCli("event stream failed: " & e.msg)
      return

    var cmd = ""
    for i in 1 ..< args.len:
      if i > 1:
        cmd.add(" ")
      cmd.add(args[i])
    try:
      let requestPayload = triadMsgRequestPayload(cmd)
      if requestPayload.isSome:
        let reply = waitFor sendIpcRequest(triadSocketPath(), requestPayload.get())
        stdout.writeLine(reply)
      elif cmd.specialMsgCommand():
        let reply = waitFor sendIpcRequest(triadSocketPath(), cmd)
        stdout.writeLine(reply)
      else:
        if parseTextCommand(cmd).isNone:
          failCli("invalid msg command: " & cmd)
        waitFor sendIpcMsg(triadSocketPath(), cmd)
    except CatchableError as e:
      failCli("socket request failed: " & e.msg)
    return

  let liveReloadDevMode = consumeLiveReloadDevMode()
  configureDevMode(args)
  configureLogging()

  info "Triad process starting",
    pid = getCurrentProcessId(),
    runtimeDir = runtimeDir(),
    waylandDisplay = getEnv("WAYLAND_DISPLAY", ""),
    devMode = devModeEnabled(),
    behaviorLog = behaviorLogEnabled()
  if liveReloadDevMode:
    info "Live reload dev mode marker consumed",
      path = defaultLiveReloadDevModePath(),
      devMode = devModeEnabled(),
      behaviorLog = behaviorLogEnabled()

  daemon.pendingLiveRestorePath = defaultLiveRestorePath()
  let hadRestoreSnapshot = fileExists(daemon.pendingLiveRestorePath)

  let sessionProblem = currentWaylandSessionProblem()
  if sessionProblem.len > 0:
    fatal "Refusing to start outside a Wayland session", reason = sessionProblem
    quit 1

  daemon.display = connectDisplay(nil)
  if daemon.display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  daemon.registry = daemon.display.getRegistry()
  discard daemon.registry.addListener(registryListener.addr, daemonData(daemon))

  let roundtripResult = daemon.display.roundtrip()
  debug "Wayland registry roundtrip finished", result = roundtripResult
  discard roundtripResult

  daemon.validateRiverProtocolCompatibility()

  if daemon.riverManager == nil:
    fatal "river_window_manager_v1 not advertised; Triad must run inside River 0.4+"
    quit 1

  let managerRoundtripResult = daemon.display.roundtrip()
  debug "River manager roundtrip finished",
    result = managerRoundtripResult,
    outputs = daemon.outputPointers.len,
    pendingWindows = pendingWindows.len,
    seats = daemon.seatPointers.len
  if managerRoundtripResult == -1:
    fatal "Failed during River manager initialization roundtrip"
    quit 1

  # Setup and Load Config
  daemon.setupConfig(configPathFromArgs(args))
  let initialLoaded = daemon.loadStartupConfig()
  let initialConfig = initialLoaded.config
  daemon.runtimeState = initRuntimeStateFromConfig(initialConfig)
  daemon.janetRuntime = initJanetRuntime(daemon.runtimeState.model.janet)
  daemon.writeMemorySample("startup")
  daemon.installInputRuntimeHooks()
  daemon.configureXkbKeymap("initial config")
  daemon.applyAllInputConfig("initial config")
  daemon.resetOutputManagementRetry()
  daemon.applyOutputManagementConfig("initial config")
  daemon.configureSwitchEventRuntime("initial config")
  info "Initial config loaded", path = daemon.configPath

  daemon.pendingLiveRestore = loadLiveRestoreState(daemon.pendingLiveRestorePath)
  if daemon.pendingLiveRestore.isSome:
    let state = daemon.pendingLiveRestore.get()
    info "Live restore snapshot loaded",
      path = daemon.pendingLiveRestorePath,
      activeTag = state.activeTag,
      windows = state.tagByWindow.len
    writeLiveRestoreBehaviorEvent(
      "live_restore_loaded", daemon.pendingLiveRestorePath, "startup", state
    )
  elif hadRestoreSnapshot and liveRestoreStateApplied(daemon.pendingLiveRestorePath):
    info "Applied live restore snapshot retained", path = daemon.pendingLiveRestorePath
  elif hadRestoreSnapshot:
    if quarantineLiveRestoreState(daemon.pendingLiveRestorePath):
      warn "Invalid live restore snapshot quarantined",
        path = daemon.pendingLiveRestorePath
    else:
      warn "Invalid live restore snapshot could not be quarantined",
        path = daemon.pendingLiveRestorePath

  if daemon.pendingLiveRestore.isSome and not hasInitialRiverState():
    info "Live restore handoff waiting for initial River state",
      path = daemon.pendingLiveRestorePath
    if not waitForInitialRiverState(250):
      warn "Live restore handoff has no initial River state; retrying startup",
        path = daemon.pendingLiveRestorePath
      quit 0

  info "Triad connected to River",
    outputs = daemon.outputPointers.len, seats = daemon.seatPointers.len

  daemon.applyPendingLiveRestore("startup")

  # Setup Watcher
  daemon.watcher = initWatcher()
  proc onConfigChange(events: seq[PathEvent]) {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.configReloadDebouncer.schedule(int64(epochTime() * 1000.0))

  proc configureConfigWatcher() =
    daemon.watcher = initWatcher()
    let paths =
      if daemon.configWatchPaths.len > 0:
        daemon.configWatchPaths
      else:
        @[daemon.configPath]
    daemon.watcher.register(paths, onConfigChange, treatAsFile = true)

  configureConfigWatcher()

  # Start IPC Server
  proc queueMsg(msg: Msg) {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.enqueue(msg)

  proc snapshotModel(): ShellSnapshot {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.readModelSnapshot()

  proc snapshotLiveRestoreJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.readLiveRestoreJson()

  proc snapshotPerfStatusJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.perfStatusJson()

  proc snapshotMemStatusJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.memoryStatusJson()

  proc dispatchBindingJson(request: BindingDispatchRequest): string {.gcsafe.} =
    {.cast(gcsafe).}:
      daemon.dispatchBindingRequest(request).bindingDispatchReply()

  let triadSocket = triadSocketPath()
  let niriSocketPath = chooseNiriCompatSocketPath(triadSocket)
  var ipcStarted = false
  var ipcStartupGateOpen = false

  proc waitForIpcListenersReady(listeners: openArray[Future[bool]]): bool =
    let deadline = epochTime() + float(IpcListenReadyTimeoutMs) / 1000.0
    while true:
      var pending = false
      for listener in listeners:
        if not listener.finished:
          pending = true
          break
      if not pending:
        break
      if epochTime() >= deadline:
        return false
      asyncdispatch.poll(10)

    result = true
    for listener in listeners:
      if listener.failed or not listener.read:
        result = false

  proc startIpcServers(): bool =
    if ipcStartupGateOpen:
      return true
    if ipcStarted:
      return false
    ipcStarted = true
    var listeners: seq[Future[bool]] = @[]

    let triadListenReady = newFuture[bool]("triad ipc listener ready")
    listeners.add(triadListenReady)
    info "Starting Triad IPC server", path = triadSocket
    writeBehaviorEvent("triad_ipc_server_starting", %*{"path": triadSocket})
    asyncCheck startIpcServer(
      triadSocket,
      queueMsg,
      snapshotModel,
      snapshotLiveRestoreJson,
      snapshotPerfStatusJson,
      snapshotMemStatusJson,
      dispatchBindingJson,
      listenReady = triadListenReady,
    )

    if niriSocketPath.len > 0 and niriSocketPath != triadSocket:
      let niriListenReady = newFuture[bool]("niri compat ipc listener ready")
      listeners.add(niriListenReady)
      info "Starting Niri-compatible IPC server", path = niriSocketPath
      writeBehaviorEvent("niri_compat_ipc_server_starting", %*{"path": niriSocketPath})
      asyncCheck startIpcServer(
        niriSocketPath,
        queueMsg,
        snapshotModel,
        snapshotLiveRestoreJson,
        snapshotPerfStatusJson,
        snapshotMemStatusJson,
        dispatchBindingJson,
        listenReady = niriListenReady,
        requestTimeoutMs = IpcNoRequestTimeoutMs,
      )

    let ready = waitForIpcListenersReady(listeners)
    ipcStartupGateOpen = true
    writeBehaviorEvent(
      "ipc_startup_listeners_ready",
      %*{"ready": ready, "timeout_ms": IpcListenReadyTimeoutMs},
    )
    if not ready:
      error "IPC listeners were not ready before startup commands",
        timeout_ms = IpcListenReadyTimeoutMs
    true

  asyncCheck startStartupWindowRulesExpiry()

  # Spawn startup commands after River accepts the initial manage pass and IPC is ready.
  daemon.scheduleStartupCommands(daemon.runtimeState.model)
  daemon.shellRunner.scheduleShellSpawn(daemon.runtimeState.model)

  var lastWatcherPollMs = 0'i64
  var lastChildReapPollMs = 0'i64
  var lastMemoryMaintenanceMs = 0'i64
  var lastShellPollMs = 0'i64

  var running = true
  while running:
    inc daemon.loopCounters.loopIterations
    if not dispatchPendingWayland(daemon.display):
      break

    let nowMs = unixMs()
    if lastWatcherPollMs.pollDue(nowMs, MaintenancePollIntervalMs):
      lastWatcherPollMs = nowMs
      inc daemon.loopCounters.watcherPolls
      daemon.watcher.poll(0)

    if lastChildReapPollMs.pollDue(nowMs, ChildReapPollIntervalMs):
      lastChildReapPollMs = nowMs
      inc daemon.loopCounters.childReapPolls
      daemon.loopCounters.childReapedProcesses += uint64(daemon.reapChildProcesses())

    daemon.enqueueFrameTickIfDue(nowMs)
    if daemon.memoryMaintenanceDue(lastMemoryMaintenanceMs, nowMs):
      lastMemoryMaintenanceMs = nowMs
      inc daemon.loopCounters.memorySampleChecks
      daemon.maybeWriteMemorySample(nowMs)
      inc daemon.loopCounters.memoryCompactionChecks
      daemon.maybeRunMemoryPressureCompaction(nowMs)

    let waitTimeout = daemon.loopWaitTimeoutMs(nowMs)

    # Poll async IPC without sleeping before Wayland events are serviced.
    inc daemon.loopCounters.asyncPolls
    asyncdispatch.poll(0)

    if daemon.configReloadDebouncer.pending:
      inc daemon.loopCounters.configReloadChecks
    if daemon.configReloadDebouncer.pending and
        daemon.configReloadDebouncer.takeDue(nowMs):
      inc daemon.loopCounters.configReloadsDue
      daemon.enqueue(Msg(kind: MsgKind.CmdConfigReload))

    # Process Message Queue
    if processQueuedMessages(daemon.configPath, niriSocketPath):
      configureConfigWatcher()
    if daemon.shouldExit:
      running = false
      continue

    if daemon.initialManageComplete:
      if startIpcServers():
        daemon.spawnPendingStartupCommands(
          daemon.runtimeState.model, "initial manage ipc ready"
        )
        daemon.shellRunner.spawnPendingShell(
          daemon.runtimeState.model, niriSocketPath, "initial manage ipc ready"
        )
      let shellPollMs = nowMs
      let recoveryMs = daemon.nextShellRecoveryMs()
      let shellPollDue =
        lastShellPollMs.pollDue(shellPollMs, MaintenancePollIntervalMs) or
        (recoveryMs > 0 and shellPollMs >= recoveryMs)
      if shellPollDue:
        lastShellPollMs = shellPollMs
        inc daemon.loopCounters.shellWatchdogPolls
        let watchdogFallback =
          daemon.shellRunner.pollShellWatchdog(daemon.runtimeState.model, shellPollMs)
        if watchdogFallback.isSome:
          daemon.enqueue(
            Msg(kind: MsgKind.CmdSwitchShell, shellName: watchdogFallback.get())
          )
        else:
          inc daemon.loopCounters.shellRecoveryPolls
          discard daemon.shellRunner.pollShellRecovery(
            daemon.runtimeState.model, niriSocketPath, shellPollMs
          )

    if daemon.manageRequestPending:
      inc daemon.loopCounters.manageFlushChecks
      daemon.flushManageRequest()

    if not prepareWaylandRead(daemon.display):
      break

    discard daemon.display.flush()
    let waitResult = daemon.waitForRuntimeEvents(waitTimeout)
    if waitResult.waylandReady:
      inc daemon.loopCounters.waylandWakeups
      if daemon.display.read_events() == -1:
        running = false
    else:
      daemon.display.cancel_read()
    if waitResult.asyncReady:
      inc daemon.loopCounters.asyncWakeups
      inc daemon.loopCounters.asyncPolls
      asyncdispatch.poll(0)
    if waitResult.switchReady:
      inc daemon.loopCounters.switchWakeups
      inc daemon.loopCounters.switchPolls
      daemon.pollSwitchEventDevices()
    daemon.maybeWriteRuntimeLoopSample(unixMs())

  daemon.closeSwitchEventDevices()
  daemon.janetRuntime.close()

if isMainModule:
  main()
