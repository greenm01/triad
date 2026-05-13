import std/[options, tables]
import chronicles
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import wayland/native/client
import ../config/keysyms
import ../core/msg
import ../ipc/commands
import ../systems/[daemon_view, overview_geometry, runtime]
import ../types/[model, runtime_values]
import
  manage_requests, message_queue, protocol_surface_runtime, protocol_surfaces,
  render_runtime, state, wayland_helpers

const
  RiverEdgeTop = 1'u32
  RiverEdgeLeft = 4'u32
  RiverAllEdges = RiverEdgeTop or RiverEdgeBottom or RiverEdgeLeft or RiverEdgeRight
  RiverDecorationOnlySupportsCsd = 0'u32
  AllWatchedModifiers = 1'u32 or 4'u32 or 8'u32 or 32'u32 or 64'u32 or 128'u32
  WlSeatCapabilityPointer = 1'u32
  WlPointerAxisVertical = 0'u32
  WlPointerAxisHorizontal = 1'u32
  WlPointerAxisSourceWheel = 0'u32
  WlWheelClick120 = 120'i32

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

template ownedShellSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.ownedShellSurfaceId

proc callbackDaemon(data: pointer, context: string): ptr TriadDaemon =
  result = daemonFromData(data)
  if result == nil:
    warn "Ignoring callback without daemon context", callback = context

proc attachLayerOutput*(daemon: var TriadDaemon, outputId: uint32)
proc attachLayerSeat*(daemon: var TriadDaemon, seat: ptr RiverSeatV1)
proc attachXkbSeat*(daemon: var TriadDaemon, seat: ptr RiverSeatV1)
proc attachWlPointer*(daemon: var TriadDaemon, globalName: uint32)
proc detachWlPointer*(daemon: var TriadDaemon, globalName: uint32)
proc destroyBindings*(daemon: var TriadDaemon)

proc removeSeatPointer(daemon: var TriadDaemon, seat: ptr RiverSeatV1) =
  var i = 0
  while i < daemon.seatPointers.len:
    if daemon.seatPointers[i] == seat:
      daemon.seatPointers.delete(i)
    else:
      inc i

proc riverSeatIdForWlName(daemon: TriadDaemon, globalName: uint32): uint32 =
  for seatId, wlName in daemon.seatWlNames.pairs:
    if wlName == globalName:
      return seatId
  0'u32

proc mapWlPointerRiverSeat(daemon: var TriadDaemon, globalName: uint32) =
  if not daemon.wlPointerPointers.hasKey(globalName):
    return
  let pointerId = daemon.wlPointerPointers[globalName].id()
  let seatId = daemon.riverSeatIdForWlName(globalName)
  if seatId == 0:
    daemon.wlPointerRiverSeats.del(pointerId)
  else:
    daemon.wlPointerRiverSeats[pointerId] = seatId

proc removeWlPointerRiverSeat(daemon: var TriadDaemon, seatId: uint32) =
  var target = 0'u32
  for pointerId, mappedSeatId in daemon.wlPointerRiverSeats.pairs:
    if mappedSeatId == seatId:
      target = pointerId
  if target != 0:
    daemon.wlPointerRiverSeats.del(target)

proc wheelTicks(total120: int32, discrete: int32, remainder: var int32): int32 =
  if discrete != 0:
    remainder = 0
    return discrete
  if total120 == 0:
    return 0

  let total = remainder + total120
  if total >= WlWheelClick120:
    result = total div WlWheelClick120
    remainder = total mod WlWheelClick120
  elif total <= -WlWheelClick120:
    result = -((-total) div WlWheelClick120)
    remainder = -((-total) mod WlWheelClick120)
  else:
    remainder = total

proc clearWlPointerFrame(daemon: var TriadDaemon, pointerId: uint32) =
  daemon.wlPointerWheelFrames[pointerId] = WlPointerWheelFrame()

proc queueWindowFocus(daemon: var TriadDaemon, target: WindowId) =
  if target == 0:
    return
  daemon.enqueue(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: target))

proc queueWindowInteraction(daemon: var TriadDaemon, target: WindowId) =
  if daemon.currentModel.overviewActive:
    return
  daemon.queueWindowFocus(target)

proc bindingModeActive(daemon: TriadDaemon, mode: BindingMode): bool =
  case mode
  of BindingMode.BindAlways:
    true
  of BindingMode.BindNormal:
    not daemon.currentModel.overviewActive
  of BindingMode.BindOverview:
    daemon.currentModel.overviewActive

proc keyBindingActive(daemon: TriadDaemon, binding: KeyBindingConfig): bool =
  if not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc pointerBindingActive(daemon: TriadDaemon, binding: PointerBindingConfig): bool =
  if not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc hasOverviewLeftClickBinding(daemon: TriadDaemon): bool =
  for binding in daemon.currentModel.pointerBindings:
    if binding.button == 0x110'u32 and binding.modifiers == 0'u32 and
        binding.mode in {BindingMode.BindAlways, BindingMode.BindOverview}:
      return true
  false

proc hasOverviewRightClickBinding(daemon: TriadDaemon): bool =
  for binding in daemon.currentModel.pointerBindings:
    if binding.button == 0x111'u32 and binding.modifiers == 0'u32 and
        binding.mode in {BindingMode.BindAlways, BindingMode.BindOverview}:
      return true
  false

proc overviewSelectPointerBinding(): PointerBindingConfig =
  PointerBindingConfig(
    button: 0x110'u32,
    modifiers: 0'u32,
    op: PointerOpKind.OpNone,
    command: "select-window",
    mode: BindingMode.BindOverview,
  )

proc overviewScrollPointerBinding(): PointerBindingConfig =
  PointerBindingConfig(
    button: 0x111'u32,
    modifiers: 0'u32,
    op: PointerOpKind.OpOverviewScroll,
    command: "overview-scroll",
    mode: BindingMode.BindOverview,
  )

proc overviewKeyBindingFallbacks*(): seq[KeyBindingConfig] =
  @[
    KeyBindingConfig(
      key: "Escape",
      modifiers: 0'u32,
      command: "toggle-overview",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Return",
      modifiers: 0'u32,
      command: "toggle-overview",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Left",
      modifiers: 0'u32,
      command: "focus-left",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Right",
      modifiers: 0'u32,
      command: "focus-right",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Up",
      modifiers: 0'u32,
      command: "focus-window-or-workspace-up",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Down",
      modifiers: 0'u32,
      command: "focus-window-or-workspace-down",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Page_Up",
      modifiers: 0'u32,
      command: "focus-tag-left",
      mode: BindingMode.BindOverview,
    ),
    KeyBindingConfig(
      key: "Page_Down",
      modifiers: 0'u32,
      command: "focus-tag-right",
      mode: BindingMode.BindOverview,
    ),
  ]

proc sameOverviewKeySlot(binding, candidate: KeyBindingConfig): bool =
  if binding.mode notin {BindingMode.BindAlways, BindingMode.BindOverview}:
    return false
  binding.modifiers == candidate.modifiers and
    keySymForBinding(binding.key, binding.modifiers) != 0 and
    keySymForBinding(binding.key, binding.modifiers) ==
    keySymForBinding(candidate.key, candidate.modifiers)

proc hasOverviewKeyBinding*(model: Model, candidate: KeyBindingConfig): bool =
  for binding in model.keyBindings:
    if binding.sameOverviewKeySlot(candidate):
      return true
  false

proc overviewFallbackKeyBindings*(model: Model): seq[KeyBindingConfig] =
  for binding in overviewKeyBindingFallbacks():
    if not model.hasOverviewKeyBinding(binding):
      result.add(binding)

proc onSeatRemoved(data: pointer, seat: ptr RiverSeatV1) =
  let daemon = callbackDaemon(data, "seat removed")
  if daemon == nil:
    return
  info "Seat removed"
  let seatId = seat.id()
  daemon[].removeSeatPointer(seat)
  daemon[].removeWlPointerRiverSeat(seatId)
  daemon.seatWlNames.del(seatId)
  daemon.pointerWindowBySeat.del(seatId)
  daemon.pointerPositionBySeat.del(seatId)
  if daemon.xkbSeatPointers.hasKey(seatId):
    daemon.xkbSeatPointers[seatId].destroy()
    daemon.xkbSeatPointers.del(seatId)
  for layerSeat in daemon.layerSeatPointers:
    layerSeat.destroy()
  daemon.layerSeatPointers = @[]
  daemon[].destroyBindings()
  seat.destroy()

proc onSeatWlSeat(data: pointer, seat: ptr RiverSeatV1, name: uint32) =
  let daemon = callbackDaemon(data, "seat wl_seat")
  if daemon == nil:
    return
  daemon.seatWlNames[seat.id()] = name
  daemon[].mapWlPointerRiverSeat(name)
  trace "Seat wl_seat received", seatId = seat.id(), name = name

proc onSeatPointerEnter(data: pointer, seat: ptr RiverSeatV1, win: ptr RiverWindowV1) =
  let daemon = callbackDaemon(data, "seat pointer enter")
  if daemon == nil:
    return
  if win != nil:
    daemon.pointerWindowBySeat[seat.id()] = win.id()
    trace "Pointer entered window", seatId = seat.id(), windowId = win.id()

proc onSeatPointerLeave(data: pointer, seat: ptr RiverSeatV1) =
  let daemon = callbackDaemon(data, "seat pointer leave")
  if daemon == nil:
    return
  daemon.pointerWindowBySeat.del(seat.id())
  trace "Pointer left window", seatId = seat.id()

proc onSeatWindowInteraction(
    data: pointer, seat: ptr RiverSeatV1, win: ptr RiverWindowV1
) =
  let daemon = callbackDaemon(data, "seat window interaction")
  if daemon == nil:
    return
  if win != nil:
    let id = win.id()
    debug "Seat window interaction", windowId = id
    daemon[].queueWindowInteraction(id)

proc onSeatShellSurfaceInteraction(
    data: pointer, seat: ptr RiverSeatV1, shellSurface: ptr RiverShellSurfaceV1
) =
  let daemon = callbackDaemon(data, "seat shell surface interaction")
  if daemon == nil:
    return
  if shellSurface != nil:
    let id = shellSurface.id()
    daemon.shellSurfacePointers[id] = shellSurface
    trace "Seat shell surface interaction", shellSurfaceId = id
    daemon.enqueue(Msg(kind: MsgKind.WlShellSurfaceInteraction, shellSurfaceId: id))

proc onOpDelta(data: pointer, seat: ptr RiverSeatV1, dx: int32, dy: int32) =
  let daemon = callbackDaemon(data, "op delta")
  if daemon == nil:
    return
  daemon.enqueue(Msg(kind: MsgKind.WlPointerDelta, dx: dx, dy: dy))

proc onOpRelease(data: pointer, seat: ptr RiverSeatV1) =
  let daemon = callbackDaemon(data, "op release")
  if daemon == nil:
    return
  daemon.enqueue(Msg(kind: MsgKind.WlPointerRelease))

proc onSeatPointerPosition(data: pointer, seat: ptr RiverSeatV1, x: int32, y: int32) =
  let daemon = callbackDaemon(data, "seat pointer position")
  if daemon == nil:
    return
  daemon.pointerPositionBySeat[seat.id()] = Rect(x: x, y: y, w: 0, h: 0)
  trace "Seat pointer position", seatId = seat.id(), x = x, y = y

var riverSeatListener* = RiverSeatV1Listener(
  removed: onSeatRemoved,
  seat: onSeatWlSeat,
  pointerEnter: onSeatPointerEnter,
  pointerLeave: onSeatPointerLeave,
  windowInteraction: onSeatWindowInteraction,
  shellSurfaceInteraction: onSeatShellSurfaceInteraction,
  opDelta: onOpDelta,
  opRelease: onOpRelease,
  pointerPosition: onSeatPointerPosition,
)

proc onWlSeatCapabilities(data: pointer, seat: ptr Seat, capabilities: uint32) =
  let listenerData = cast[ptr WlSeatListenerData](data)
  if listenerData == nil:
    warn "Ignoring wl_seat capabilities without listener context"
    return
  let daemon = listenerData.daemon
  if daemon == nil:
    warn "Ignoring wl_seat capabilities without daemon context"
    return
  if (capabilities and WlSeatCapabilityPointer) != 0:
    daemon[].attachWlPointer(listenerData.globalName)
  else:
    daemon[].detachWlPointer(listenerData.globalName)

proc onWlSeatName(data: pointer, seat: ptr Seat, name: cstring) =
  discard

var wlSeatListener* =
  SeatListener(capabilities: onWlSeatCapabilities, name: onWlSeatName)

proc onWlPointerAxisSource(data: pointer, pointer: ptr Pointer, axisSource: uint32) =
  let daemon = callbackDaemon(data, "wl_pointer axis source")
  if daemon == nil:
    return
  let pointerId = pointer.id()
  var frame = daemon.wlPointerWheelFrames.getOrDefault(pointerId)
  frame.hasSource = true
  frame.source = axisSource
  daemon.wlPointerWheelFrames[pointerId] = frame

proc onWlPointerAxisDiscrete(
    data: pointer, pointer: ptr Pointer, axis: uint32, discrete: int32
) =
  let daemon = callbackDaemon(data, "wl_pointer axis discrete")
  if daemon == nil:
    return
  let pointerId = pointer.id()
  var frame = daemon.wlPointerWheelFrames.getOrDefault(pointerId)
  if axis == WlPointerAxisHorizontal:
    frame.horizontalDiscrete += discrete
  elif axis == WlPointerAxisVertical:
    frame.verticalDiscrete += discrete
  daemon.wlPointerWheelFrames[pointerId] = frame

proc onWlPointerAxisValue120(
    data: pointer, pointer: ptr Pointer, axis: uint32, value120: int32
) =
  let daemon = callbackDaemon(data, "wl_pointer axis value120")
  if daemon == nil:
    return
  let pointerId = pointer.id()
  var frame = daemon.wlPointerWheelFrames.getOrDefault(pointerId)
  if axis == WlPointerAxisHorizontal:
    frame.horizontal120 += value120
  elif axis == WlPointerAxisVertical:
    frame.vertical120 += value120
  daemon.wlPointerWheelFrames[pointerId] = frame

proc onWlPointerFrame(data: pointer, pointer: ptr Pointer) =
  let daemon = callbackDaemon(data, "wl_pointer frame")
  if daemon == nil:
    return
  let pointerId = pointer.id()
  let frame = daemon.wlPointerWheelFrames.getOrDefault(pointerId)
  if frame.hasSource and frame.source != WlPointerAxisSourceWheel:
    daemon[].clearWlPointerFrame(pointerId)
    return
  if not daemon.wlPointerRiverSeats.hasKey(pointerId):
    daemon[].clearWlPointerFrame(pointerId)
    return
  let seatId = daemon.wlPointerRiverSeats[pointerId]
  if not daemon.pointerPositionBySeat.hasKey(seatId):
    daemon[].clearWlPointerFrame(pointerId)
    return

  var remainder = daemon.wlPointerWheelRemainders.getOrDefault(pointerId)
  let horizontal =
    wheelTicks(frame.horizontal120, frame.horizontalDiscrete, remainder.horizontal120)
  let vertical =
    wheelTicks(frame.vertical120, frame.verticalDiscrete, remainder.vertical120)
  daemon.wlPointerWheelRemainders[pointerId] = remainder
  daemon[].clearWlPointerFrame(pointerId)

  if horizontal == 0 and vertical == 0:
    return
  if not daemon[].currentModel.overviewUsesWorkspacePreviews():
    return

  let point = daemon.pointerPositionBySeat[seatId]
  daemon.enqueue(
    Msg(
      kind: MsgKind.WlOverviewWheel,
      overviewWheelX: point.x,
      overviewWheelY: point.y,
      overviewWheelHorizontal: horizontal,
      overviewWheelVertical: vertical,
    )
  )

proc ignoreWlPointerEnter(
    data: pointer,
    pointer: ptr Pointer,
    serial: uint32,
    surface: ptr Surface,
    surfaceX: Fixed,
    surfaceY: Fixed,
) =
  discard

proc ignoreWlPointerLeave(
    data: pointer, pointer: ptr Pointer, serial: uint32, surface: ptr Surface
) =
  discard

proc ignoreWlPointerMotion(
    data: pointer, pointer: ptr Pointer, time: uint32, surfaceX: Fixed, surfaceY: Fixed
) =
  discard

proc ignoreWlPointerButton(
    data: pointer,
    pointer: ptr Pointer,
    serial: uint32,
    time: uint32,
    button: uint32,
    state: uint32,
) =
  discard

proc ignoreWlPointerAxis(
    data: pointer, pointer: ptr Pointer, time: uint32, axis: uint32, value: Fixed
) =
  discard

proc ignoreWlPointerAxisStop(
    data: pointer, pointer: ptr Pointer, time: uint32, axis: uint32
) =
  discard

proc ignoreWlPointerAxisRelativeDirection(
    data: pointer, pointer: ptr Pointer, axis: uint32, direction: uint32
) =
  discard

var wlPointerListener* = PointerListener(
  enter: ignoreWlPointerEnter,
  leave: ignoreWlPointerLeave,
  motion: ignoreWlPointerMotion,
  button: ignoreWlPointerButton,
  axis: ignoreWlPointerAxis,
  frame: onWlPointerFrame,
  axisSource: onWlPointerAxisSource,
  axisStop: ignoreWlPointerAxisStop,
  axisDiscrete: onWlPointerAxisDiscrete,
  axisValue120: onWlPointerAxisValue120,
  axisRelativeDirection: ignoreWlPointerAxisRelativeDirection,
)

proc onXkbPressed(data: pointer, binding: ptr riverXkb.RiverXkbBindingV1) =
  let daemon = callbackDaemon(data, "xkb pressed")
  if daemon == nil:
    return
  let id = binding.id()
  daemon.xkbBindingPressed[id] = true
  if daemon.xkbBindingModes.hasKey(id) and
      not daemon[].bindingModeActive(daemon.xkbBindingModes[id]):
    return
  if daemon.xkbBindings.hasKey(id):
    let msg = daemon.xkbBindings[id]
    daemon.enqueue(msg)
    if daemon[].currentModel.hotkeyOverlayOpen and
        msg.kind notin {
          MsgKind.CmdShowHotkeyOverlay, MsgKind.CmdToggleHotkeyOverlay,
          MsgKind.CmdHideHotkeyOverlay,
        }:
      daemon.enqueue(Msg(kind: MsgKind.CmdHideHotkeyOverlay))

proc onXkbReleased(data: pointer, binding: ptr riverXkb.RiverXkbBindingV1) =
  let daemon = callbackDaemon(data, "xkb released")
  if daemon == nil:
    return
  daemon.xkbBindingPressed[binding.id()] = false
  trace "XKB binding released", bindingId = binding.id()

proc onXkbStopRepeat(data: pointer, binding: ptr riverXkb.RiverXkbBindingV1) =
  let daemon = callbackDaemon(data, "xkb stop-repeat")
  if daemon == nil:
    return
  let id = binding.id()
  daemon.xkbStopRepeatCount[id] =
    daemon.xkbStopRepeatCount.getOrDefault(id, 0'u32) + 1'u32
  trace "XKB binding stop-repeat", bindingId = id, count = daemon.xkbStopRepeatCount[id]

var xkbBindingListener* = riverXkb.RiverXkbBindingV1Listener(
  pressed: onXkbPressed, released: onXkbReleased, stopRepeat: onXkbStopRepeat
)

proc onXkbSeatAteUnboundKey(data: pointer, seat: ptr riverXkb.RiverXkbBindingsSeatV1) =
  let daemon = callbackDaemon(data, "xkb seat ate unbound key")
  if daemon == nil:
    return
  let id = seat.id()
  daemon.xkbSeatAteUnbound[id] =
    daemon.xkbSeatAteUnbound.getOrDefault(id, 0'u32) + 1'u32
  trace "XKB seat ate unbound key", xkbSeatId = id, count = daemon.xkbSeatAteUnbound[id]

proc onXkbSeatModifiersUpdate(
    data: pointer, seat: ptr riverXkb.RiverXkbBindingsSeatV1, old: uint32, new: uint32
) =
  let daemon = callbackDaemon(data, "xkb seat modifiers update")
  if daemon == nil:
    return
  trace "XKB modifiers updated", xkbSeatId = seat.id(), old = old, new = new
  daemon.enqueue(
    Msg(kind: MsgKind.WlModifiersChanged, oldModifiers: old, newModifiers: new)
  )

var xkbSeatListener* = riverXkb.RiverXkbBindingsSeatV1Listener(
  ateUnboundKey: onXkbSeatAteUnboundKey, modifiersUpdate: onXkbSeatModifiersUpdate
)

proc onPointerBindingPressed(data: pointer, binding: ptr RiverPointerBindingV1) =
  let daemon = callbackDaemon(data, "pointer binding pressed")
  if daemon == nil:
    return
  let id = binding.id()
  daemon.pointerBindingPressed[id] = true
  if not daemon.pointerBindingSeats.hasKey(id):
    return
  let seat = daemon.pointerBindingSeats[id]
  let button = daemon.pointerBindingButtons.getOrDefault(id, 0'u32)
  let point = daemon.pointerPositionBySeat.getOrDefault(seat.id(), Rect())
  if daemon[].currentModel.overviewUsesWorkspacePreviews():
    if button == 0x110'u32:
      let target = daemon[].overviewWindowAtPointer(seat)
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlOverviewPointerDragRequested,
          overviewDragWinId: target,
          overviewDragSeat: seat,
          overviewDragX: point.x,
          overviewDragY: point.y,
        )
      )
      return
    if button == 0x111'u32 or
        daemon.pointerBindingKinds.getOrDefault(id, PointerOpKind.OpNone) ==
        PointerOpKind.OpOverviewScroll:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlOverviewPointerScrollRequested,
          overviewScrollSeat: seat,
          overviewScrollX: point.x,
          overviewScrollY: point.y,
        )
      )
      return
  let focused = daemon[].currentModel.activeFocusRiverId()
  let target =
    if daemon[].currentModel.overviewActive:
      daemon[].overviewWindowAtPointer(seat)
    else:
      daemon.pointerWindowBySeat.getOrDefault(seat.id(), focused)
  if daemon.pointerBindingKinds.hasKey(id):
    if daemon[].currentModel.overviewActive:
      return
    if target == 0:
      return
    case daemon.pointerBindingKinds[id]
    of PointerOpKind.OpMove:
      daemon.enqueue(
        Msg(kind: MsgKind.WlPointerMoveRequested, moveWinId: target, moveSeat: seat)
      )
    of PointerOpKind.OpResize:
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlPointerResizeRequested,
          resizeWinId: target,
          resizeSeat: seat,
          resizeEdges: RiverEdgeBottom or RiverEdgeRight,
        )
      )
    of PointerOpKind.OpNone, PointerOpKind.OpOverviewDrag,
        PointerOpKind.OpOverviewScroll:
      discard
  elif daemon.pointerBindings.hasKey(id):
    let msg = daemon.pointerBindings[id]
    case msg.kind
    of MsgKind.CmdCloseWindow:
      if target != 0:
        daemon.enqueue(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: target))
      elif not daemon[].currentModel.overviewActive:
        daemon.enqueue(msg)
    of MsgKind.CmdCloseWindowById:
      if target != 0 and daemon[].currentModel.overviewActive:
        daemon.enqueue(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: target))
      else:
        daemon.enqueue(msg)
    of MsgKind.CmdSelectWindow:
      if daemon[].currentModel.overviewActive and target != 0:
        daemon[].queueWindowFocus(target)
        daemon.enqueue(msg)
      elif not daemon[].currentModel.overviewActive:
        daemon.enqueue(msg)
    of MsgKind.CmdToggleFloating, MsgKind.CmdToggleFullscreen,
        MsgKind.CmdToggleMaximized, MsgKind.CmdMaximizeColumn, MsgKind.CmdMinimize,
        MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
        MsgKind.CmdMoveFloating, MsgKind.CmdResizeFloating:
      if target != 0:
        daemon[].queueWindowFocus(target)
        daemon.enqueue(msg)
      elif not daemon[].currentModel.overviewActive:
        daemon.enqueue(msg)
    else:
      daemon.enqueue(msg)

proc onPointerBindingReleased(data: pointer, binding: ptr RiverPointerBindingV1) =
  let daemon = callbackDaemon(data, "pointer binding released")
  if daemon == nil:
    return
  daemon.pointerBindingPressed[binding.id()] = false
  trace "Pointer binding released", bindingId = binding.id()

var pointerBindingListener* = RiverPointerBindingV1Listener(
  pressed: onPointerBindingPressed, released: onPointerBindingReleased
)

proc onLayerOutputNonExclusive(
    data: pointer,
    layerOutput: ptr riverLayer.RiverLayerShellOutputV1,
    x: int32,
    y: int32,
    width: int32,
    height: int32,
) =
  let daemon = callbackDaemon(data, "layer output non-exclusive")
  if daemon == nil:
    return
  let layerId = layerOutput.id()
  if daemon.layerOutputOwners.hasKey(layerId):
    let outputId = daemon.layerOutputOwners[layerId]
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputUsable,
        usableOutputId: outputId,
        usableX: x,
        usableY: y,
        usableW: width,
        usableH: height,
      )
    )

var layerOutputListener* = riverLayer.RiverLayerShellOutputV1Listener(
  nonExclusiveArea: onLayerOutputNonExclusive
)

proc onLayerSeatFocusExclusive(
    data: pointer, seat: ptr riverLayer.RiverLayerShellSeatV1
) =
  let daemon = callbackDaemon(data, "layer seat focus exclusive")
  if daemon == nil:
    return
  trace "Layer shell focus exclusive"
  daemon.enqueue(Msg(kind: MsgKind.WlLayerFocusExclusive))

proc onLayerSeatFocusNonExclusive(
    data: pointer, seat: ptr riverLayer.RiverLayerShellSeatV1
) =
  let daemon = callbackDaemon(data, "layer seat focus non-exclusive")
  if daemon == nil:
    return
  trace "Layer shell focus non-exclusive"
  daemon.enqueue(Msg(kind: MsgKind.WlLayerFocusNonExclusive))

proc onLayerSeatFocusNone(data: pointer, seat: ptr riverLayer.RiverLayerShellSeatV1) =
  let daemon = callbackDaemon(data, "layer seat focus none")
  if daemon == nil:
    return
  daemon.enqueue(Msg(kind: MsgKind.WlLayerFocusNone))
  daemon[].requestManage("layer focus none")

var layerSeatListener* = riverLayer.RiverLayerShellSeatV1Listener(
  focusExclusive: onLayerSeatFocusExclusive,
  focusNonExclusive: onLayerSeatFocusNonExclusive,
  focusNone: onLayerSeatFocusNone,
)

proc attachLayerOutput*(daemon: var TriadDaemon, outputId: uint32) =
  if daemon.riverLayerShell == nil or not daemon.outputPointers.hasKey(outputId) or
      daemon.layerOutputPointers.hasKey(outputId):
    return
  let layerOutput = daemon.riverLayerShell.getOutput(daemon.outputPointers[outputId])
  daemon.layerOutputPointers[outputId] = layerOutput
  daemon.layerOutputOwners[layerOutput.id()] = outputId
  discard layerOutput.addListener(layerOutputListener.addr, daemonData(daemon))

proc attachLayerSeat*(daemon: var TriadDaemon, seat: ptr RiverSeatV1) =
  if daemon.riverLayerShell == nil or seat == nil:
    return
  let layerSeat = daemon.riverLayerShell.getSeat(seat)
  daemon.layerSeatPointers.add(layerSeat)
  discard layerSeat.addListener(layerSeatListener.addr, daemonData(daemon))

proc attachWlPointer*(daemon: var TriadDaemon, globalName: uint32) =
  if not daemon.wlSeatPointers.hasKey(globalName) or
      daemon.wlPointerPointers.hasKey(globalName):
    return
  let pointer = daemon.wlSeatPointers[globalName].getPointer()
  daemon.wlPointerPointers[globalName] = pointer
  daemon.wlPointerGlobalNames[pointer.id()] = globalName
  daemon.wlPointerWheelFrames[pointer.id()] = WlPointerWheelFrame()
  daemon.wlPointerWheelRemainders[pointer.id()] = WlPointerWheelRemainder()
  daemon.mapWlPointerRiverSeat(globalName)
  discard pointer.addListener(wlPointerListener.addr, daemonData(daemon))

proc detachWlPointer*(daemon: var TriadDaemon, globalName: uint32) =
  if not daemon.wlPointerPointers.hasKey(globalName):
    return
  let pointer = daemon.wlPointerPointers[globalName]
  let pointerId = pointer.id()
  pointer.destroy()
  daemon.wlPointerPointers.del(globalName)
  daemon.wlPointerGlobalNames.del(pointerId)
  daemon.wlPointerRiverSeats.del(pointerId)
  daemon.wlPointerWheelFrames.del(pointerId)
  daemon.wlPointerWheelRemainders.del(pointerId)

proc attachXkbSeat*(daemon: var TriadDaemon, seat: ptr RiverSeatV1) =
  if daemon.riverXkbBindings == nil or seat == nil:
    return
  if daemon.riverXkbBindings.getVersion() < 2'u32:
    return
  let seatId = seat.id()
  if daemon.xkbSeatPointers.hasKey(seatId):
    return
  let xkbSeat = daemon.riverXkbBindings.getSeat(seat)
  daemon.xkbSeatPointers[seatId] = xkbSeat
  discard xkbSeat.addListener(xkbSeatListener.addr, daemonData(daemon))
  xkbSeat.modifiersWatch(AllWatchedModifiers)

proc destroyBindings*(daemon: var TriadDaemon) =
  for binding in daemon.xkbBindingPointers:
    binding.disable()
    binding.destroy()
  daemon.xkbBindingPointers = @[]
  daemon.xkbBindings.clear()
  daemon.xkbBindingPressed.clear()
  daemon.xkbBindingModes.clear()
  daemon.xkbStopRepeatCount.clear()

  for binding in daemon.pointerBindingPointers:
    binding.disable()
    binding.destroy()
  daemon.pointerBindingPointers = @[]
  daemon.pointerBindings.clear()
  daemon.pointerBindingKinds.clear()
  daemon.pointerBindingSeats.clear()
  daemon.pointerBindingButtons.clear()
  daemon.pointerBindingPressed.clear()
  daemon.bindingsConfigured = false

proc destroyXkbSeats*(daemon: var TriadDaemon) =
  for xkbSeat in daemon.xkbSeatPointers.values:
    xkbSeat.destroy()
  daemon.xkbSeatPointers.clear()

proc addXkbBinding(
    daemon: var TriadDaemon,
    seat: ptr RiverSeatV1,
    bindingConfig: KeyBindingConfig,
    keysym, modifiers: uint32,
    msg: Msg,
) =
  if daemon.riverXkbBindings == nil:
    return
  let binding = daemon.riverXkbBindings.getXkbBinding(seat, keysym, modifiers)
  daemon.xkbBindingPointers.add(binding)
  daemon.xkbBindings[binding.id()] = msg
  daemon.xkbBindingModes[binding.id()] = bindingConfig.mode
  discard binding.addListener(xkbBindingListener.addr, daemonData(daemon))
  if bindingConfig.hasLayoutOverride:
    binding.setLayoutOverride(bindingConfig.layoutOverride)
  binding.enable()

proc addPointerBinding(
    daemon: var TriadDaemon, seat: ptr RiverSeatV1, bindingConfig: PointerBindingConfig
) =
  var msg = none(Msg)
  if bindingConfig.op == PointerOpKind.OpNone:
    msg = parseTextCommand(bindingConfig.command)
    if msg.isNone:
      return

  let binding = seat.getPointerBinding(bindingConfig.button, bindingConfig.modifiers)
  daemon.pointerBindingPointers.add(binding)
  if bindingConfig.op != PointerOpKind.OpNone:
    daemon.pointerBindingKinds[binding.id()] = bindingConfig.op
  else:
    daemon.pointerBindings[binding.id()] = msg.get()
  daemon.pointerBindingSeats[binding.id()] = seat
  daemon.pointerBindingButtons[binding.id()] = bindingConfig.button
  discard binding.addListener(pointerBindingListener.addr, daemonData(daemon))
  binding.enable()

proc setupDefaultBindings*(daemon: var TriadDaemon) =
  if daemon.currentModel.sessionLocked:
    return
  if daemon.bindingsConfigured:
    return
  if daemon.seatPointers.len == 0:
    return

  for seat in daemon.seatPointers:
    daemon.attachXkbSeat(seat)

    for binding in daemon.currentModel.keyBindings:
      if not daemon.keyBindingActive(binding):
        continue
      let parsed = parseTextCommand(binding.command)
      let sym = keySymForBinding(binding.key, binding.modifiers)
      if parsed.isSome and sym != 0:
        daemon.addXkbBinding(seat, binding, sym, binding.modifiers, parsed.get())
    if daemon.currentModel.overviewUsesWorkspacePreviews():
      for binding in daemon.currentModel.overviewFallbackKeyBindings():
        let parsed = parseTextCommand(binding.command)
        let sym = keySymForBinding(binding.key, binding.modifiers)
        if parsed.isSome and sym != 0:
          daemon.addXkbBinding(seat, binding, sym, binding.modifiers, parsed.get())

    for binding in daemon.currentModel.pointerBindings:
      if daemon.pointerBindingActive(binding):
        daemon.addPointerBinding(seat, binding)
    if daemon.currentModel.overviewActive and not daemon.hasOverviewLeftClickBinding():
      daemon.addPointerBinding(seat, overviewSelectPointerBinding())
    if daemon.currentModel.overviewUsesWorkspacePreviews() and
        not daemon.hasOverviewRightClickBinding():
      daemon.addPointerBinding(seat, overviewScrollPointerBinding())

  daemon.bindingsConfigured = true

proc applyManageState*(daemon: var TriadDaemon) =
  daemon.setupDefaultBindings()
  if daemon.currentModel.protocolSurfaces.enabled:
    daemon.ensureOwnedShellSurface()
  else:
    daemon.destroyAllProtocolSurfaces()

  for id, win in daemon.windowPointers.pairs:
    win.setCapabilities(daemon.currentModel.supportedCapabilities())
    var edges = RiverAllEdges
    let dataOpt = daemon.currentModel.windowDataForRiverId(id)
    if dataOpt.isSome:
      let data = dataOpt.get()
      if data.hasDecorationHint and data.decorationHint == RiverDecorationOnlySupportsCsd:
        win.useCsd()
      else:
        win.useSsd()
      win.setDimensionBounds(data.maxWidth, data.maxHeight)
      if data.isFloating or data.isFullscreen:
        edges = 0
      discard daemon.ensureDecorationSurface(id, ProtocolSurfaceKind.PskDecorationBelow)
      discard daemon.ensureDecorationSurface(id, ProtocolSurfaceKind.PskDecorationAbove)
    else:
      win.useSsd()
    win.setTiled(edges)

  let focused = daemon.currentModel.activeFocusRiverId()
  for seat in daemon.seatPointers:
    if daemon.currentModel.cursor.theme.len > 0:
      let cursorSize =
        if daemon.currentModel.cursor.size == 0:
          24'u32
        else:
          daemon.currentModel.cursor.size
      seat.setXcursorTheme(cstring(daemon.currentModel.cursor.theme), cursorSize)
    if daemon.currentModel.layerFocusExclusive or daemon.currentModel.sessionLocked:
      seat.clearFocus()
    elif daemon.currentModel.overviewActive and daemon.ownedShellSurfaceId != 0 and
        daemon.shellSurfacePointers.hasKey(daemon.ownedShellSurfaceId):
      seat.focusShellSurface(daemon.shellSurfacePointers[daemon.ownedShellSurfaceId])
    elif focused != 0 and daemon.windowPointers.hasKey(focused):
      seat.focusWindow(daemon.windowPointers[focused])
    else:
      seat.clearFocus()

  let primaryOutput = daemon.currentModel.primaryOutputRiverId()
  if primaryOutput != 0 and daemon.layerOutputPointers.hasKey(primaryOutput):
    daemon.layerOutputPointers[primaryOutput].setDefault()
