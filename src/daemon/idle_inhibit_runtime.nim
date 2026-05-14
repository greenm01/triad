import chronicles
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import wayland/protocols/unstable/idleinhibitunstable/v1/client as idle
import wayland/protocols/wayland/client as wlCore
import ../systems/[idle_inhibit, runtime_facade]
import state

proc premulTransparent(): tuple[r, g, b, a: uint32] =
  (0'u32, 0'u32, 0'u32, 0'u32)

proc ensureIdleInhibitSurface(daemon: var TriadDaemon): bool =
  if daemon.idleInhibitSurface != nil:
    return true
  if daemon.compositor == nil:
    return false

  let surface = daemon.compositor.createSurface()
  if surface == nil:
    return false
  daemon.idleInhibitSurface = surface

  if daemon.singlePixelManager != nil:
    let transparent = premulTransparent()
    daemon.idleInhibitBuffer = daemon.singlePixelManager.createU32RgbaBuffer(
      transparent.r, transparent.g, transparent.b, transparent.a
    )
    if daemon.idleInhibitBuffer != nil:
      surface.attach(daemon.idleInhibitBuffer, 0, 0)
      surface.damage(0, 0, 1, 1)
  surface.commit()
  true

proc maybeWarnIdleInhibitUnavailable(daemon: var TriadDaemon) =
  if daemon.idleInhibitUnavailableWarned:
    return
  daemon.idleInhibitUnavailableWarned = true
  warn "Idle inhibit requested but required Wayland globals are unavailable"

proc applyIdleInhibitDesired*(daemon: var TriadDaemon) =
  if not daemon.idleInhibitDesired:
    if daemon.idleInhibitor != nil:
      daemon.idleInhibitor.destroy()
      daemon.idleInhibitor = nil
      debug "Disabled idle inhibitor"
    return

  if daemon.idleInhibitor != nil:
    return
  if daemon.idleInhibitManager == nil or not daemon.ensureIdleInhibitSurface():
    daemon.maybeWarnIdleInhibitUnavailable()
    return

  daemon.idleInhibitor =
    daemon.idleInhibitManager.createInhibitor(daemon.idleInhibitSurface)
  if daemon.idleInhibitor == nil:
    daemon.maybeWarnIdleInhibitUnavailable()
    return
  daemon.idleInhibitUnavailableWarned = false
  debug "Enabled idle inhibitor"

proc setIdleInhibit*(daemon: var TriadDaemon, active: bool) =
  daemon.idleInhibitDesired = active
  daemon.applyIdleInhibitDesired()

proc syncIdleInhibitFromRuntime*(daemon: var TriadDaemon) =
  daemon.setIdleInhibit(daemon.runtimeState.readRuntimeSnapshot().idleInhibitActive())

proc destroyIdleInhibitRuntime*(daemon: var TriadDaemon) =
  daemon.idleInhibitDesired = false
  daemon.applyIdleInhibitDesired()
  if daemon.idleInhibitSurface != nil:
    daemon.idleInhibitSurface.attach(nil, 0, 0)
    daemon.idleInhibitSurface.commit()
    daemon.idleInhibitSurface.destroy()
    daemon.idleInhibitSurface = nil
  if daemon.idleInhibitBuffer != nil:
    daemon.idleInhibitBuffer.destroy()
    daemon.idleInhibitBuffer = nil
