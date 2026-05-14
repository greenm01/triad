import std/[options, tables]
import chronicles
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import ../core/msg
import ../state/[iterators, queries]
import ../systems/window_rules
import ../types/runtime_values
from ../types/runtime_values import WindowId
import ../utils/process_tree
import
  bindings_runtime, live_restore_runtime, manage_requests, message_queue,
  protocol_surface_runtime, river_outputs_runtime, river_windows, state, wayland_helpers

proc callbackDaemon(data: pointer, context: string): ptr TriadDaemon =
  result = daemonFromData(data)
  if result == nil:
    warn "Ignoring River manager callback without daemon context", context = context

proc cleanupRiverObjects*(daemon: var TriadDaemon) =
  daemon.manageRequestPending = false
  daemon.manageRequestReason = ""

  daemon.destroyAllProtocolSurfaces()

  var winIds: seq[WindowId] = @[]
  for id in daemon.windowPointers.keys:
    winIds.add(id)
  for id in winIds:
    daemon.forgetWindow(id)

  var outputIds: seq[uint32] = @[]
  for id in daemon.outputPointers.keys:
    outputIds.add(id)
  for id in outputIds:
    if daemon.layerOutputPointers.hasKey(id):
      let layerOutput = daemon.layerOutputPointers[id]
      daemon.layerOutputOwners.del(layerOutput.id())
      daemon.layerOutputPointers.del(id)
      layerOutput.destroy()
    let output = daemon.outputPointers[id]
    daemon.outputPointers.del(id)
    output.destroy()

  daemon.outputWlNames.clear()

  for seat in daemon.layerSeatPointers:
    seat.destroy()
  daemon.layerSeatPointers = @[]

  daemon.destroyBindings()
  daemon.destroyXkbSeats()
  daemon.xkbSeatAteUnbound.clear()

  let seats = daemon.seatPointers
  daemon.seatPointers = @[]
  for seat in seats:
    seat.destroy()
  daemon.seatWlNames.clear()
  daemon.pointerWindowBySeat.clear()
  daemon.pointerPositionBySeat.clear()

  if daemon.riverXkbBindings != nil:
    daemon.riverXkbBindings.destroy()
    daemon.riverXkbBindings = nil
  if daemon.riverLayerShell != nil:
    daemon.riverLayerShell.destroy()
    daemon.riverLayerShell = nil

proc pendingWindowPid(daemon: TriadDaemon, id: WindowId): int32 =
  result = daemon.windowUnreliablePids.getOrDefault(id, 0'i32)
  if result <= 0 and daemon.pendingWindows.hasKey(id):
    result = daemon.pendingWindows[id].pid

proc pendingWindowAllowsSwallow(
    daemon: TriadDaemon, data: runtime_values.WindowData
): bool =
  let rule = daemon.runtimeState.model.windowRuleFor(data.appId, data.title)
  if not rule.found:
    return true
  if rule.rule.terminalSet and rule.rule.terminal:
    return false
  if rule.rule.allowSwallowSet and not rule.rule.allowSwallow:
    return false
  if rule.rule.openFloatingSet and rule.rule.openFloating:
    return false
  if rule.rule.openOnAllWorkspacesSet and rule.rule.openOnAllWorkspaces:
    return false
  if rule.rule.openNamedScratchpad.len > 0:
    return false
  if data.parentId != 0 or data.isFloating:
    return false
  true

proc swallowHostForPendingWindow(
    daemon: TriadDaemon, id: WindowId, data: runtime_values.WindowData
): WindowId =
  let childPid = daemon.pendingWindowPid(id)
  if childPid <= 0 or not daemon.pendingWindowAllowsSwallow(data):
    return 0'u32

  var fallback = 0'u32
  for logicalId in daemon.runtimeState.model.focusHistoryIdsReverse():
    let winOpt = daemon.runtimeState.model.windowData(logicalId)
    if winOpt.isNone:
      continue
    let win = winOpt.get()
    let external = WindowId(uint32(win.externalId))
    if win.isTerminal and not win.isFloating and not win.isSticky and not win.isMinimized and
        win.windowAdmitted() and win.pid > 0 and
        uint32(daemon.runtimeState.model.swallowingWindow(logicalId)) == 0'u32 and
        isDescendantProcess(win.pid, childPid):
      return external

  for logicalId, win in daemon.runtimeState.model.windowsWithId():
    let external = WindowId(uint32(win.externalId))
    if win.isTerminal and not win.isFloating and not win.isSticky and not win.isMinimized and
        win.windowAdmitted() and win.pid > 0 and
        uint32(daemon.runtimeState.model.swallowingWindow(logicalId)) == 0'u32 and
        isDescendantProcess(win.pid, childPid) and external > fallback:
      fallback = external
  fallback

proc onManagerUnavailable(data: pointer, mgr: ptr RiverWindowManagerV1) =
  fatal "River window manager interface is unavailable"
  quit 1

proc onManagerFinished(data: pointer, mgr: ptr RiverWindowManagerV1) =
  let daemon = callbackDaemon(data, "manager finished")
  if daemon == nil:
    return
  warn "River window manager interface finished"
  daemon[].cleanupRiverObjects()
  if daemon.riverManager != nil:
    daemon.riverManager.destroy()
    daemon.riverManager = nil
  daemon.shouldExit = true

proc onSessionLocked(data: pointer, mgr: ptr RiverWindowManagerV1) =
  let daemon = callbackDaemon(data, "session locked")
  if daemon == nil:
    return
  info "River session locked"
  daemon.enqueue(Msg(kind: MsgKind.WlSessionLocked))

proc onSessionUnlocked(data: pointer, mgr: ptr RiverWindowManagerV1) =
  let daemon = callbackDaemon(data, "session unlocked")
  if daemon == nil:
    return
  info "River session unlocked"
  daemon.enqueue(Msg(kind: MsgKind.WlSessionUnlocked))

proc onManageStart(data: pointer, mgr: ptr RiverWindowManagerV1) =
  let daemon = callbackDaemon(data, "manage start")
  if daemon == nil:
    return
  debug "River manage start", pendingWindows = daemon.pendingWindows.len
  daemon[].applyPendingLiveRestore("manage start")
  for id, data in daemon.pendingWindows:
    let pid = daemon[].pendingWindowPid(id)
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlWindowCreated,
        windowId: id,
        createdParentWindowId: data.parentId,
        createdSwallowHostWindowId: daemon[].swallowHostForPendingWindow(id, data),
        createdPid: pid,
        appId: data.appId,
        title: data.title,
        createdIdentifier: data.identifier,
        deferAdmission: data.parentId == 0,
      )
    )

  for id, data in daemon.pendingWindows:
    if data.actualW > 0 or data.actualH > 0:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowDimensions,
          dimensionsWindowId: id,
          actualWidth: data.actualW,
          actualHeight: data.actualH,
        )
      )
    if data.minWidth > 0 or data.minHeight > 0 or data.maxWidth > 0 or data.maxHeight > 0:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowDimensionsHint,
          hintWindowId: id,
          minWidth: data.minWidth,
          minHeight: data.minHeight,
          maxWidth: data.maxWidth,
          maxHeight: data.maxHeight,
        )
      )
    if data.hasDecorationHint:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowDecorationHint,
          decorationWindowId: id,
          decorationHint: data.decorationHint,
        )
      )
    if data.hasPresentationHint:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowPresentationHint,
          presentationWindowId: id,
          presentationHint: data.presentationHint,
        )
      )
    if data.parentId != 0:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowParent, childWindowId: id, parentWindowId: data.parentId
        )
      )
    if data.isFullscreen:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlWindowFullscreenRequested,
          fullscreenRequestId: id,
          fullscreenOutputId: data.fullscreenOutput,
        )
      )
    if data.isMaximized:
      daemon.enqueue(
        Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: id)
      )
    if data.isMinimized:
      daemon.enqueue(
        Msg(kind: MsgKind.WlWindowMinimizeRequested, minimizeRequestId: id)
      )
  daemon.pendingWindows.clear()
  daemon.enqueue(Msg(kind: MsgKind.WlManageStart))

proc onRenderStart(data: pointer, mgr: ptr RiverWindowManagerV1) =
  let daemon = callbackDaemon(data, "render start")
  if daemon == nil:
    return
  trace "River render start"
  daemon.enqueue(Msg(kind: MsgKind.WlRenderStart))

proc onWindow(data: pointer, mgr: ptr RiverWindowManagerV1, win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data, "window")
  if daemon == nil:
    return
  daemon[].trackWindow(win)

proc onOutput(data: pointer, mgr: ptr RiverWindowManagerV1, output: ptr RiverOutputV1) =
  let daemon = callbackDaemon(data, "output")
  if daemon == nil:
    return
  let id = output.id()
  info "Output discovered", outputId = id
  daemon.outputPointers[id] = output
  discard output.addListener(riverOutputListener.addr, daemonData(daemon[]))
  daemon[].attachLayerOutput(id)

proc onSeat(data: pointer, mgr: ptr RiverWindowManagerV1, seat: ptr RiverSeatV1) =
  let daemon = callbackDaemon(data, "seat")
  if daemon == nil:
    return
  info "Seat discovered", seatIndex = daemon.seatPointers.len
  daemon.seatPointers.add(seat)
  discard seat.addListener(riverSeatListener.addr, daemonData(daemon[]))
  daemon[].attachLayerSeat(seat)
  daemon.bindingsConfigured = false
  daemon[].requestManage("seat discovered")

var riverManagerListener* = RiverWindowManagerV1Listener(
  unavailable: onManagerUnavailable,
  finished: onManagerFinished,
  manageStart: onManageStart,
  renderStart: onRenderStart,
  sessionLocked: onSessionLocked,
  sessionUnlocked: onSessionUnlocked,
  window: onWindow,
  output: onOutput,
  seat: onSeat,
)
