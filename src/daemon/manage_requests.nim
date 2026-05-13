import chronicles
import protocols/river/client as river
import state

proc requestManage*(daemon: var TriadDaemon, reason: string) =
  if daemon.riverManager == nil:
    return
  if daemon.manageRequestPending:
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
  trace "Requesting River manage sequence", reason = reason
  daemon.riverManager.manageDirty()
