import std/tables
import chronicles
import protocols/river/client as river
import render_invalidation, state

const AnimationManageReason* = "effect:CmdTick"

proc shouldReplacePendingManageReason(current, next: string): bool =
  current.len == 0 or
    (current == AnimationManageReason and next != AnimationManageReason)

proc requestManage*(daemon: var TriadDaemon, reason: string) =
  daemon.markRenderDirty(reason)
  if daemon.riverManager == nil:
    return
  daemon.manageRequestReasonCounts[reason] =
    daemon.manageRequestReasonCounts.getOrDefault(reason, 0'u64) + 1'u64
  if daemon.manageRequestPending:
    if shouldReplacePendingManageReason(daemon.manageRequestReason, reason):
      daemon.manageRequestReason = reason
    trace "Coalescing River manage request",
      reason = reason, pendingReason = daemon.manageRequestReason
    return
  daemon.manageRequestPending = true
  daemon.manageRequestReason = reason
  trace "Queued River manage sequence", reason = reason

proc flushManageRequest*(daemon: var TriadDaemon) =
  if not daemon.manageRequestPending or daemon.riverManager == nil or
      daemon.riverPhase != RiverPhase.RiverIdle:
    return
  let reason = daemon.manageRequestReason
  daemon.manageRequestPending = false
  daemon.manageRequestReason = ""
  daemon.activeManageReason = reason
  trace "Requesting River manage sequence", reason = reason
  inc daemon.perfCounters.manageRequests
  daemon.riverManager.manageDirty()
