import std/[json, options, tables]
import chronicles
import ../core/restore_state
import ../systems/runtime_facade
import ../types/shell_snapshot
import ../utils/behavior_log
import state

proc readModelSnapshot*(daemon: TriadDaemon): ShellSnapshot =
  daemon.runtimeState.readRuntimeSnapshot()

proc readLiveRestoreJson*(daemon: TriadDaemon): string =
  result = daemon.runtimeState.readRuntimeLiveRestoreJson()
  if behaviorLogEnabled():
    let parsed = parseLiveRestoreJson(result)
    if parsed.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_dumped",
        defaultLiveRestorePath(),
        "ipc",
        parsed.get())

proc writeCurrentLiveRestoreState*(
    daemon: var TriadDaemon): LiveRestoreWriteResult =
  result = daemon.runtimeState.writeRuntimeLiveRestoreState()
  if result.ok and behaviorLogEnabled():
    let parsed = parseLiveRestoreJson(
      daemon.runtimeState.readRuntimeLiveRestoreJson())
    if parsed.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_written",
        result.path,
        "runtime",
        parsed.get())

proc applyPendingLiveRestore*(daemon: var TriadDaemon; context: string) =
  if daemon.pendingLiveRestore.isNone:
    return

  let state = daemon.pendingLiveRestore.get()
  writeLiveRestoreBehaviorEvent(
    "live_restore_applied",
    daemon.pendingLiveRestorePath,
    context,
    state)
  discard daemon.runtimeState.applyRuntimeLiveRestore(state)
  daemon.pendingLiveRestore = none(LiveRestoreState)
  daemon.liveRestoreCommitPending = daemon.pendingLiveRestorePath.len > 0
  info "Live restore snapshot applied",
    path = daemon.pendingLiveRestorePath,
    context = context,
    activeTag = state.activeTag,
    windows = state.tagByWindow.len

proc commitPendingLiveRestore*(daemon: var TriadDaemon) =
  if not daemon.liveRestoreCommitPending:
    return

  if completeLiveRestoreState(daemon.pendingLiveRestorePath):
    info "Live restore snapshot committed", path = daemon.pendingLiveRestorePath
    writeBehaviorEvent("live_restore_committed", %*{
      "path": daemon.pendingLiveRestorePath,
      "restore_status": LiveRestoreStatusApplied
    })
    daemon.liveRestoreCommitPending = false
  else:
    warn "Live restore snapshot could not be committed",
        path = daemon.pendingLiveRestorePath
