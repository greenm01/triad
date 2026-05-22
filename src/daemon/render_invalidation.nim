import ../systems/runtime_facade
import state

proc markRenderDirty*(daemon: var TriadDaemon, reason: string) =
  daemon.renderDirty = true
  daemon.renderDirtyReason = reason

proc canSkipRenderStart*(daemon: TriadDaemon): bool =
  not daemon.renderDirty and not daemon.runtimeState.hasPendingAdmissionWindow()

proc markRenderCleanAfterFullRender*(daemon: var TriadDaemon) =
  daemon.renderDirty = false
  daemon.renderDirtyReason = ""
