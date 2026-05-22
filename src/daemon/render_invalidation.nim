import std/times
import ../systems/runtime_facade
import protocols/river/client as river
import state

const CleanRenderFinishIntervalMs* = 250'i64

proc renderUnixMs(): int64 =
  int64(epochTime() * 1000.0)

proc deferCleanRenderFinish*(daemon: var TriadDaemon) =
  daemon.cleanRenderStartPending = true
  daemon.cleanRenderFinishDueMs = renderUnixMs() + CleanRenderFinishIntervalMs

proc finishPendingCleanRender*(daemon: var TriadDaemon) =
  if not daemon.cleanRenderStartPending:
    return
  daemon.cleanRenderStartPending = false
  daemon.cleanRenderFinishDueMs = 0
  if daemon.riverManager != nil and daemon.riverPhase == RiverPhase.RiverRender:
    daemon.riverManager.renderFinish()
  if daemon.riverPhase == RiverPhase.RiverRender:
    daemon.riverPhase = RiverPhase.RiverIdle

proc markRenderDirty*(daemon: var TriadDaemon, reason: string) =
  daemon.finishPendingCleanRender()
  daemon.renderDirty = true
  daemon.renderDirtyReason = reason

proc canSkipRenderStart*(daemon: TriadDaemon): bool =
  not daemon.renderDirty and not daemon.runtimeState.hasPendingAdmissionWindow()

proc markRenderCleanAfterFullRender*(daemon: var TriadDaemon) =
  daemon.cleanRenderStartPending = false
  daemon.cleanRenderFinishDueMs = 0
  daemon.renderDirty = false
  daemon.renderDirtyReason = ""
