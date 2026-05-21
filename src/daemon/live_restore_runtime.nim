import std/[json, options, tables]
import chronicles
import ../core/restore_state
import ../systems/runtime_facade
import ../types/shell_snapshot
import ../utils/behavior_log
import idle_inhibit_runtime, render_invalidation
import state

proc readModelSnapshot*(daemon: TriadDaemon): ShellSnapshot =
  daemon.runtimeState.readRuntimeSnapshot()

proc readLiveRestoreJson*(daemon: TriadDaemon): string =
  result = daemon.runtimeState.readRuntimeLiveRestoreJson()
  if behaviorLogEnabled():
    let parsed = parseLiveRestoreJson(result)
    if parsed.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_dumped", defaultLiveRestorePath(), "ipc", parsed.get()
      )

proc writeCurrentLiveRestoreState*(daemon: var TriadDaemon): LiveRestoreWriteResult =
  let payload = daemon.runtimeState.readRuntimeLiveRestoreJson()
  let candidate = parseLiveRestoreJson(payload)
  let previous = readLiveRestoreState(daemon.pendingLiveRestorePath)
  if candidate.isSome and previous.isSome and
      previous.get().suspiciousLiveRestoreCollapse(candidate.get()) and
      not liveRestoreCollapseAllowed():
    writeBehaviorEvent(
      "live_restore_snapshot_rejected",
      %*{
        "path": daemon.pendingLiveRestorePath,
        "context": "runtime suspicious collapse",
        "previous": previous.get().liveRestoreSummary(),
        "candidate": candidate.get().liveRestoreSummary(),
      },
    )
    return LiveRestoreWriteResult(
      ok: false,
      path: daemon.pendingLiveRestorePath,
      error: "refusing suspicious live restore collapse",
    )

  result =
    daemon.runtimeState.writeRuntimeLiveRestoreState(daemon.pendingLiveRestorePath)
  if result.ok and behaviorLogEnabled():
    if candidate.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_written", result.path, "runtime", candidate.get()
      )

proc markPendingLiveRestoreApplied(daemon: var TriadDaemon): bool =
  if daemon.pendingLiveRestorePath.len == 0:
    return false

  if completeLiveRestoreState(daemon.pendingLiveRestorePath):
    info "Live restore snapshot committed", path = daemon.pendingLiveRestorePath
    writeBehaviorEvent(
      "live_restore_committed",
      %*{
        "path": daemon.pendingLiveRestorePath,
        "restore_status": LiveRestoreStatusApplied,
      },
    )
    return true

  warn "Live restore snapshot could not be committed",
    path = daemon.pendingLiveRestorePath
  false

proc applyPendingLiveRestore*(daemon: var TriadDaemon, context: string) =
  if daemon.pendingLiveRestore.isNone:
    return

  let state = daemon.pendingLiveRestore.get()
  writeLiveRestoreBehaviorEvent(
    "live_restore_applied", daemon.pendingLiveRestorePath, context, state
  )
  discard daemon.runtimeState.applyRuntimeLiveRestore(state)
  daemon.syncIdleInhibitFromRuntime()
  daemon.markRenderDirty("live restore")
  daemon.pendingLiveRestore = none(LiveRestoreState)
  daemon.liveRestoreCommitPending = daemon.pendingLiveRestorePath.len > 0
  if daemon.liveRestoreCommitPending:
    daemon.liveRestoreCommitPending = not daemon.markPendingLiveRestoreApplied()
  info "Live restore snapshot applied",
    path = daemon.pendingLiveRestorePath,
    context = context,
    activeTag = state.activeTag,
    windows = state.tagByWindow.len

proc commitPendingLiveRestore*(daemon: var TriadDaemon) =
  if not daemon.liveRestoreCommitPending:
    return

  daemon.liveRestoreCommitPending = not daemon.markPendingLiveRestoreApplied()
