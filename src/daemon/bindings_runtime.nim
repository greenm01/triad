import std/[options, sequtils, strutils, tables, times]
import chronicles
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import wayland/native/client
import wayland/protocols/staging/cursorshape/v1/client as cursorShape
import wayland/protocols/unstable/pointergesturesunstable/v1/client as pointerGestures
import ../config/[keysyms, parser]
import ../core/msg
import ../ipc/commands
import
  ../systems/
    [daemon_view, overview_geometry, overview_hot_corners, runtime, window_rules]
import ../types/[model, runtime_values]
import
  cursor_shake, manage_requests, message_queue, protocol_surface_runtime,
  protocol_surfaces, render_runtime, state, wayland_helpers

const
  RiverEdgeTop* = 1'u32
  RiverEdgeLeft* = 4'u32
  RiverAllEdges* = RiverEdgeTop or RiverEdgeBottom or RiverEdgeLeft or RiverEdgeRight
  RiverDecorationOnlySupportsCsd = 0'u32
  AllWatchedModifiers = 1'u32 or 4'u32 or 8'u32 or 32'u32 or 64'u32 or 128'u32
  WlSeatCapabilityPointer = 1'u32
  WlPointerAxisVertical = 0'u32
  WlPointerAxisHorizontal = 1'u32
  WlPointerAxisSourceWheel = 0'u32
  WlWheelClick120 = 120'i32
  WlSwipeThreshold = 16.0

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
proc attachCursorShapePointer*(daemon: var TriadDaemon, pointerId: uint32)
proc attachWlSwipePointer*(daemon: var TriadDaemon, pointerId: uint32)
proc detachWlSwipePointer*(daemon: var TriadDaemon, pointerId: uint32)
proc destroyCursorShapeRuntime*(daemon: var TriadDaemon)
proc destroyPointerGesturesRuntime*(daemon: var TriadDaemon)
proc destroyBindings*(daemon: var TriadDaemon)
proc enqueuePointerCommand(
  daemon: var TriadDaemon, seatId: uint32, seat: ptr RiverSeatV1, msg: Msg
)

proc requestBindingReconfigure*(daemon: var TriadDaemon, reason: string)

proc tiledEdgesForWindow*(runtimeModel: Model, data: model.WindowData): uint32 =
  let ruleMatch = runtimeModel.windowRuleFor(data)
  if ruleMatch.found and ruleMatch.rule.tiledStateSet:
    return if ruleMatch.rule.tiledState: RiverAllEdges else: 0'u32
  if data.isFloating or data.isFullscreen: 0'u32 else: RiverAllEdges

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

func fixedToFloat(value: Fixed): float64 =
  float64(value) / 256.0

func gestureDirectionForSwipe*(
    dx, dy: float64, cancelled: bool
): GestureBindingDirection =
  if cancelled:
    return GestureBindingDirection.GestureNone
  if dx * dx + dy * dy < WlSwipeThreshold * WlSwipeThreshold:
    return GestureBindingDirection.GestureNone
  if abs(dx) > abs(dy):
    if dx < 0:
      GestureBindingDirection.GestureSwipeLeft
    else:
      GestureBindingDirection.GestureSwipeRight
  elif dy < 0:
    GestureBindingDirection.GestureSwipeUp
  else:
    GestureBindingDirection.GestureSwipeDown

proc clearWlPointerFrame(daemon: var TriadDaemon, pointerId: uint32) =
  daemon.wlPointerWheelFrames[pointerId] = WlPointerWheelFrame()

proc nowMs(): int64 =
  int64(epochTime() * 1000.0)

proc applyCursorSize(seat: ptr RiverSeatV1, theme: string, size: uint32) =
  if seat == nil or theme.len == 0:
    return
  seat.setXcursorTheme(cstring(theme), size)

proc applyCurrentCursorSize(daemon: TriadDaemon, seat: ptr RiverSeatV1, size: uint32) =
  seat.applyCursorSize(daemon.currentModel.cursor.theme, size)

proc restoreCursorSize(daemon: TriadDaemon, seat: ptr RiverSeatV1, seatId: uint32) =
  var theme = daemon.currentModel.cursor.theme
  var size = daemon.currentModel.cursor.cursorBaseSize()
  if theme.len == 0 and daemon.cursorShakeBySeat.hasKey(seatId):
    let state = daemon.cursorShakeBySeat[seatId]
    theme = state.restoreTheme
    if state.restoreSize > 0:
      size = state.restoreSize
  seat.applyCursorSize(theme, size)

proc configuredCursorSize(daemon: TriadDaemon, seatId: uint32): uint32 =
  result = daemon.currentModel.cursor.cursorBaseSize()
  if daemon.currentModel.cursor.cursorShakeEnabled() and
      daemon.cursorShakeBySeat.hasKey(seatId) and
      daemon.cursorShakeBySeat[seatId].enlarged:
    result = daemon.currentModel.cursor.cursorShakeSize()

proc wlPointerById(daemon: TriadDaemon, pointerId: uint32): ptr Pointer =
  if not daemon.wlPointerGlobalNames.hasKey(pointerId):
    return nil
  let globalName = daemon.wlPointerGlobalNames[pointerId]
  daemon.wlPointerPointers.getOrDefault(globalName)

proc showCursorPointer(daemon: var TriadDaemon, pointerId: uint32) =
  if not daemon.cursorHiddenPointers.getOrDefault(pointerId, false):
    return
  if daemon.cursorShapeDevices.hasKey(pointerId):
    daemon.cursorShapeDevices[pointerId].setShape(
      0'u32, uint32(cursorShape.shape_default)
    )
  daemon.cursorHiddenPointers.del(pointerId)

proc hideCursorPointer(daemon: var TriadDaemon, pointerId: uint32) =
  if daemon.cursorHiddenPointers.getOrDefault(pointerId, false):
    return
  if not daemon.cursorShapeDevices.hasKey(pointerId):
    return
  let pointer = daemon.wlPointerById(pointerId)
  if pointer == nil:
    return
  pointer.setCursor(0'u32, nil, 0, 0)
  daemon.cursorHiddenPointers[pointerId] = true

proc pointerIdForRiverSeat(daemon: TriadDaemon, seatId: uint32): uint32 =
  for pointerId, mappedSeatId in daemon.wlPointerRiverSeats.pairs:
    if mappedSeatId == seatId:
      return pointerId
  0'u32

proc observeCursorActivity(daemon: var TriadDaemon, seatId: uint32, now: int64) =
  let pointerId = daemon.pointerIdForRiverSeat(seatId)
  if pointerId == 0:
    return
  daemon.cursorLastMotionMsByPointer[pointerId] = now
  daemon.showCursorPointer(pointerId)

proc hideAllCursors(daemon: var TriadDaemon) =
  for pointerId in daemon.wlPointerRiverSeats.keys:
    daemon.hideCursorPointer(pointerId)

proc tickCursorVisibility*(daemon: var TriadDaemon) =
  if not daemon.currentModel.cursor.cursorHideInactiveEnabled():
    for pointerId in daemon.cursorHiddenPointers.keys.toSeq():
      daemon.showCursorPointer(pointerId)
    return
  let now = nowMs()
  let delay = int64(daemon.currentModel.cursor.hideAfterInactiveMs)
  for pointerId, lastMotion in daemon.cursorLastMotionMsByPointer.pairs:
    if now - lastMotion >= delay:
      daemon.hideCursorPointer(pointerId)

proc applyCursorShakeMotion(
    daemon: var TriadDaemon, seat: ptr RiverSeatV1, x, y: int32
) =
  if seat == nil:
    return
  let seatId = seat.id()
  let action = daemon.cursorShakeBySeat
    .mgetOrPut(seatId, CursorShakeState())
    .observeCursorMotion(daemon.currentModel.cursor, x, y, nowMs())
  case action
  of CursorShakeAction.None:
    discard
  of CursorShakeAction.Enlarge:
    daemon.applyCurrentCursorSize(seat, daemon.currentModel.cursor.cursorShakeSize())
  of CursorShakeAction.Restore:
    daemon.restoreCursorSize(seat, seatId)

proc tickCursorShake*(daemon: var TriadDaemon) =
  if daemon.cursorShakeBySeat.len == 0:
    return
  let now = nowMs()
  for seat in daemon.seatPointers:
    let seatId = seat.id()
    if daemon.cursorShakeBySeat.hasKey(seatId):
      let action = daemon.cursorShakeBySeat[seatId].tickCursorShake(
        daemon.currentModel.cursor, now
      )
      if action == CursorShakeAction.Restore:
        daemon.restoreCursorSize(seat, seatId)

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
    not daemon.currentModel.overviewActive and
      not daemon.currentModel.recentWindowsActive
  of BindingMode.BindOverview:
    daemon.currentModel.overviewActive
  of BindingMode.BindRecent:
    daemon.currentModel.recentWindowsActive

proc isRecentAdvanceCommand(command: string): bool =
  let parts = command.strip().splitWhitespace()
  parts.len > 0 and parts[0] in ["recent-window-next", "recent-window-prev"]

proc recentBindingCanOpen(model: Model, mode: BindingMode, msg: Msg): bool =
  mode == BindingMode.BindRecent and not model.recentWindowsActive and
    not model.overviewActive and
    msg.kind in {MsgKind.CmdRecentWindowNext, MsgKind.CmdRecentWindowPrev}

proc isOverviewTabOpenCommand(msg: Msg): bool =
  msg.kind in {MsgKind.CmdToggleOverview, MsgKind.CmdOpenOverview}

proc overviewTabBindingCanCycle(model: Model, binding: KeyBindingConfig): bool =
  if not model.overviewTabMode or not model.overviewTabModeActive or
      binding.modifiers == 0'u32 or binding.modifiers != model.overviewTabModeModifiers:
    return false
  let parsed = parseTextCommand(binding.command)
  parsed.isSome and parsed.get().isOverviewTabOpenCommand()

proc recentOpenCommandForBinding(binding: KeyBindingConfig): string =
  let parsed = parseTextCommand(binding.command)
  if parsed.isNone:
    return ""
  let msg = parsed.get()
  case msg.kind
  of MsgKind.CmdFocusDirection:
    case msg.direction
    of Direction.DirLeft: "recent-window-prev"
    of Direction.DirRight: "recent-window-next"
    of Direction.DirUp, Direction.DirDown: ""
  of MsgKind.CmdFocusColumnFirst:
    "recent-window-first"
  of MsgKind.CmdFocusColumnLast:
    "recent-window-last"
  else:
    ""

proc keyBindingActive(daemon: TriadDaemon, binding: KeyBindingConfig): bool =
  if daemon.currentModel.exitSessionConfirmOpen:
    return false
  if daemon.currentModel.sessionLocked and not binding.whileLocked:
    return false
  if daemon.currentModel.recentWindowsActive and binding.mode != BindingMode.BindRecent and
      binding.recentOpenCommandForBinding().len > 0:
    return false
  if binding.mode == BindingMode.BindRecent and
      not daemon.currentModel.recentWindowsActive and
      binding.command.isRecentAdvanceCommand() and not daemon.currentModel.overviewActive:
    discard
  elif daemon.currentModel.overviewTabBindingCanCycle(binding):
    discard
  elif not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc liveXkbBindingActive(daemon: TriadDaemon, id: uint32): bool =
  if daemon.currentModel.sessionLocked and
      not daemon.xkbBindingWhileLocked.getOrDefault(id, false):
    return false
  if daemon.xkbBindingModes.hasKey(id) and
      not daemon.bindingModeActive(daemon.xkbBindingModes[id]):
    if daemon.xkbBindings.hasKey(id) and
        daemon.xkbBindings[id].isOverviewTabOpenCommand() and
        daemon.currentModel.overviewTabModeActive and
        daemon.xkbBindingModifiers.getOrDefault(id, 0'u32) ==
        daemon.currentModel.overviewTabModeModifiers:
      return true
    if not daemon.xkbBindings.hasKey(id) or
        daemon.xkbBindingModifiers.getOrDefault(id, 0'u32) == 0'u32 or
        not daemon.currentModel.recentBindingCanOpen(
          daemon.xkbBindingModes[id], daemon.xkbBindings[id]
        ):
      return false
  true

proc enqueueHotkeyOverlayDismiss(daemon: var TriadDaemon): bool =
  if not daemon.currentModel.hotkeyOverlayOpen:
    return false
  daemon.hotkeyOverlayKeyEatArmed = false
  daemon.enqueue(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
  true

proc enqueueExitSessionConfirmDismiss(daemon: var TriadDaemon): bool =
  if not daemon.currentModel.exitSessionConfirmOpen:
    return false
  daemon.hotkeyOverlayKeyEatArmed = false
  daemon.enqueue(Msg(kind: MsgKind.CmdDismissExitSessionConfirm))
  true

proc enqueueXkbBindingCommand(daemon: var TriadDaemon, id: uint32) =
  if daemon.xkbBindings.hasKey(id):
    let msg = daemon.xkbBindings[id]
    if daemon.enqueueHotkeyOverlayDismiss():
      return
    daemon.enqueue(msg)

proc handleXkbBindingPressed*(daemon: var TriadDaemon, id: uint32) =
  daemon.xkbBindingPressed[id] = true
  daemon.xkbBindingReleaseArmed[id] = false
  if daemon.currentModel.exitSessionConfirmOpen:
    daemon.hotkeyOverlayKeyEatArmed = false
    if daemon.xkbBindings.hasKey(id) and
        daemon.xkbBindings[id].kind == MsgKind.CmdConfirmExitSession:
      daemon.enqueue(daemon.xkbBindings[id])
    else:
      daemon.enqueue(Msg(kind: MsgKind.CmdDismissExitSessionConfirm))
    return
  if daemon.xkbBindings.hasKey(id) and daemon.enqueueHotkeyOverlayDismiss():
    return
  if not daemon.liveXkbBindingActive(id):
    return
  if daemon.xkbBindingOnRelease.getOrDefault(id, false):
    daemon.xkbBindingReleaseArmed[id] = true
  else:
    daemon.enqueueXkbBindingCommand(id)

proc handleXkbBindingReleased*(daemon: var TriadDaemon, id: uint32) =
  daemon.xkbBindingPressed[id] = false
  if daemon.xkbBindingOnRelease.getOrDefault(id, false) and
      daemon.xkbBindingReleaseArmed.getOrDefault(id, false):
    daemon.xkbBindingReleaseArmed[id] = false
    if not daemon.currentModel.sessionLocked or
        daemon.xkbBindingWhileLocked.getOrDefault(id, false):
      daemon.enqueueXkbBindingCommand(id)

proc handleXkbSeatAteUnboundKey*(daemon: var TriadDaemon, id: uint32) =
  daemon.xkbSeatAteUnbound[id] =
    daemon.xkbSeatAteUnbound.getOrDefault(id, 0'u32) + 1'u32
  trace "XKB seat ate unbound key", xkbSeatId = id, count = daemon.xkbSeatAteUnbound[id]
  if not daemon.enqueueExitSessionConfirmDismiss():
    discard daemon.enqueueHotkeyOverlayDismiss()

proc syncHotkeyOverlayKeyCapture*(daemon: var TriadDaemon) =
  if daemon.currentModel.hotkeyOverlayOpen or daemon.currentModel.exitSessionConfirmOpen:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.ensureNextKeyEaten()
    daemon.hotkeyOverlayKeyEatArmed = true
  elif daemon.hotkeyOverlayKeyEatArmed:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.cancelEnsureNextKeyEaten()
    daemon.hotkeyOverlayKeyEatArmed = false

proc pointerBindingActive(daemon: TriadDaemon, binding: PointerBindingConfig): bool =
  if daemon.currentModel.exitSessionConfirmOpen:
    return false
  if daemon.currentModel.sessionLocked:
    return false
  if not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc axisBindingActive(daemon: TriadDaemon, binding: AxisBindingConfig): bool =
  if daemon.currentModel.exitSessionConfirmOpen:
    return false
  if daemon.currentModel.sessionLocked:
    return false
  if not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc gestureBindingActive(daemon: TriadDaemon, binding: GestureBindingConfig): bool =
  if daemon.currentModel.exitSessionConfirmOpen:
    return false
  if daemon.currentModel.sessionLocked:
    return false
  if not daemon.bindingModeActive(binding.mode):
    return false
  if daemon.currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc axisDirectionForWheelTicks*(
    horizontalAxis: bool, ticks: int32
): AxisBindingDirection =
  if ticks == 0:
    return AxisBindingDirection.AxisNone
  if horizontalAxis:
    if ticks > 0: AxisBindingDirection.AxisRight else: AxisBindingDirection.AxisLeft
  elif ticks > 0:
    AxisBindingDirection.AxisDown
  else:
    AxisBindingDirection.AxisUp

proc activeAxisBinding(
    daemon: TriadDaemon, direction: AxisBindingDirection
): Option[AxisBindingConfig] =
  let modifiers = daemon.currentModel.activeModifiers
  for binding in daemon.currentModel.axisBindings:
    if binding.direction == direction and binding.modifiers == modifiers and
        daemon.axisBindingActive(binding):
      return some(binding)
  none(AxisBindingConfig)

proc activeGestureBinding(
    daemon: TriadDaemon, direction: GestureBindingDirection, fingers: uint32
): Option[GestureBindingConfig] =
  let modifiers = daemon.currentModel.activeModifiers
  for binding in daemon.currentModel.gestureBindings:
    if binding.direction == direction and binding.fingers == fingers and
        binding.modifiers == modifiers and daemon.gestureBindingActive(binding):
      return some(binding)
  none(GestureBindingConfig)

proc activeSwitchEvent(
    daemon: TriadDaemon, kind: SwitchEventKind
): Option[SwitchEventConfig] =
  for event in daemon.currentModel.switchEvents:
    if event.kind == kind:
      return some(event)
  none(SwitchEventConfig)

proc overviewHotCornerCanOpen(daemon: TriadDaemon): bool =
  not daemon.currentModel.overviewActive and not daemon.currentModel.sessionLocked and
    not daemon.currentModel.layerFocusExclusive and
    not daemon.currentModel.keyboardShortcutsInhibited() and
    daemon.currentModel.pointerOp.kind == PointerOpKind.OpNone

proc updateOverviewHotCornerState*(
    daemon: var TriadDaemon, seatId: uint32, x, y: int32
): bool =
  let inside = daemon.currentModel.overviewHotCornerAt(x, y)
  let wasInside = daemon.pointerHotCornerInsideBySeat.getOrDefault(seatId, false)
  if inside:
    daemon.pointerHotCornerInsideBySeat[seatId] = true
  else:
    daemon.pointerHotCornerInsideBySeat.del(seatId)
  inside and not wasInside and daemon.overviewHotCornerCanOpen()

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

proc sameModalKeySlot(binding, candidate: KeyBindingConfig): bool =
  binding.modifiers == candidate.modifiers and
    keySymForBinding(binding.key, binding.modifiers) != 0 and
    keySymForBinding(binding.key, binding.modifiers) ==
    keySymForBinding(candidate.key, candidate.modifiers)

proc hasModalKeyBinding(
    bindings: seq[KeyBindingConfig], candidate: KeyBindingConfig
): bool =
  for binding in bindings:
    if binding.sameModalKeySlot(candidate):
      return true
  false

proc hasExplicitModalKeyBinding(
    model: Model,
    candidate: KeyBindingConfig,
    targetMode: BindingMode,
    includeAlways: bool,
): bool =
  for binding in model.keyBindings:
    if binding.mode == targetMode or (includeAlways and binding.mode == BindAlways):
      if binding.sameModalKeySlot(candidate):
        return true
  false

proc addModalFallback(
    model: Model,
    bindings: var seq[KeyBindingConfig],
    candidate: KeyBindingConfig,
    targetMode: BindingMode,
    includeAlwaysExplicit: bool,
) =
  if not model.hasExplicitModalKeyBinding(candidate, targetMode, includeAlwaysExplicit) and
      not bindings.hasModalKeyBinding(candidate):
    bindings.add(candidate)

proc overviewCommandForBinding(binding: KeyBindingConfig): string =
  let parsed = parseTextCommand(binding.command)
  if parsed.isNone:
    return ""
  let msg = parsed.get()
  case msg.kind
  of MsgKind.CmdFocusDirection, MsgKind.CmdFocusColumnFirst, MsgKind.CmdFocusColumnLast,
      MsgKind.CmdFocusWindowOrWorkspaceUp, MsgKind.CmdFocusWindowOrWorkspaceDown:
    binding.command
  else:
    ""

proc modalFallbackKeyBindings(
    model: Model,
    presets: seq[KeyBindingConfig],
    targetMode: BindingMode,
    targetModifiers: uint32,
    sourceModes: set[BindingMode],
    includeAlwaysExplicit: bool,
    commandForBinding: proc(binding: KeyBindingConfig): string,
): seq[KeyBindingConfig] =
  for binding in presets:
    var candidate = binding
    candidate.modifiers = targetModifiers
    model.addModalFallback(result, candidate, targetMode, includeAlwaysExplicit)
  for binding in model.keyBindings:
    if binding.mode notin sourceModes:
      continue
    let command = commandForBinding(binding)
    if command.len == 0:
      continue
    let candidate = KeyBindingConfig(
      key: binding.key, modifiers: targetModifiers, command: command, mode: targetMode
    )
    model.addModalFallback(result, candidate, targetMode, includeAlwaysExplicit)

proc hasOverviewKeyBinding*(model: Model, candidate: KeyBindingConfig): bool =
  for binding in model.keyBindings:
    if binding.sameOverviewKeySlot(candidate):
      return true
  false

proc overviewFallbackKeyBindings*(model: Model): seq[KeyBindingConfig] =
  model.modalFallbackKeyBindings(
    overviewKeyBindingFallbacks(),
    BindingMode.BindOverview,
    0'u32,
    {BindingMode.BindAlways, BindingMode.BindNormal, BindingMode.BindOverview},
    includeAlwaysExplicit = true,
    overviewCommandForBinding,
  )

proc recentOpenFallbackKeyBindings*(model: Model): seq[KeyBindingConfig] =
  model.modalFallbackKeyBindings(
    recentWindowFallbackBindings(),
    BindingMode.BindRecent,
    model.activeModifiers,
    {BindingMode.BindAlways, BindingMode.BindNormal},
    includeAlwaysExplicit = false,
    recentOpenCommandForBinding,
  )

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
  daemon.pointerHotCornerInsideBySeat.del(seatId)
  daemon.cursorShakeBySeat.del(seatId)
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
  daemon[].observeCursorActivity(seat.id(), nowMs())
  daemon[].applyCursorShakeMotion(seat, x, y)
  if daemon[].currentModel.recentWindowsActive:
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlRecentWindowPointerMotion, recentPointerX: x, recentPointerY: y
      )
    )
  if daemon[].updateOverviewHotCornerState(seat.id(), x, y):
    daemon.enqueue(Msg(kind: MsgKind.CmdOpenOverview))
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

proc riverSeatPointerById(daemon: TriadDaemon, seatId: uint32): ptr RiverSeatV1 =
  for seat in daemon.seatPointers:
    if seat != nil and seat.id() == seatId:
      return seat
  nil

proc dispatchAxisBindingTicks*(
    daemon: var TriadDaemon, seatId: uint32, ticks: int32, horizontalAxis: bool
): bool =
  let direction = axisDirectionForWheelTicks(horizontalAxis, ticks)
  if direction == AxisBindingDirection.AxisNone:
    return false
  let binding = daemon.activeAxisBinding(direction)
  if binding.isNone:
    return false
  let msg = parseTextCommand(binding.get().command)
  if msg.isNone:
    return false

  let seat = daemon.riverSeatPointerById(seatId)
  for _ in 0 ..< abs(ticks).int:
    daemon.enqueuePointerCommand(seatId, seat, msg.get())
  true

proc dispatchGestureBinding*(
    daemon: var TriadDaemon,
    seatId: uint32,
    direction: GestureBindingDirection,
    fingers: uint32,
): bool =
  if direction == GestureBindingDirection.GestureNone:
    return false
  let binding = daemon.activeGestureBinding(direction, fingers)
  if binding.isNone:
    return false
  let msg = parseTextCommand(binding.get().command)
  if msg.isNone:
    return false

  let seat = daemon.riverSeatPointerById(seatId)
  daemon.enqueuePointerCommand(seatId, seat, msg.get())
  true

proc beginSwipeGesture*(daemon: var TriadDaemon, pointerId, fingers: uint32) =
  daemon.wlSwipeStates[pointerId] =
    WlSwipeState(active: true, fingers: fingers, dx: 0, dy: 0)

proc updateSwipeGesture*(daemon: var TriadDaemon, pointerId: uint32, dx, dy: float64) =
  var state = daemon.wlSwipeStates.getOrDefault(pointerId)
  if not state.active:
    return
  state.dx += dx
  state.dy += dy
  daemon.wlSwipeStates[pointerId] = state

proc endSwipeGesture*(
    daemon: var TriadDaemon, pointerId: uint32, cancelled: bool
): bool =
  let state = daemon.wlSwipeStates.getOrDefault(pointerId)
  daemon.wlSwipeStates[pointerId] = WlSwipeState()
  if not state.active:
    return false
  let direction = gestureDirectionForSwipe(state.dx, state.dy, cancelled)
  if direction == GestureBindingDirection.GestureNone:
    return false
  if not daemon.wlPointerRiverSeats.hasKey(pointerId):
    return false
  daemon.dispatchGestureBinding(
    daemon.wlPointerRiverSeats[pointerId], direction, state.fingers
  )

proc dispatchSwitchEvent*(daemon: var TriadDaemon, kind: SwitchEventKind): bool =
  if kind == SwitchEventKind.SwitchNone:
    return false
  let event = daemon.activeSwitchEvent(kind)
  if event.isNone:
    return false
  let msg = parseTextCommand(event.get().command)
  if msg.isNone:
    return false
  daemon.enqueue(msg.get())
  true

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

  let point = daemon.pointerPositionBySeat[seatId]
  var overviewHorizontal = horizontal
  var overviewVertical = vertical
  if daemon[].dispatchAxisBindingTicks(seatId, horizontal, horizontalAxis = true):
    overviewHorizontal = 0
  if daemon[].dispatchAxisBindingTicks(seatId, vertical, horizontalAxis = false):
    overviewVertical = 0
  if overviewHorizontal == 0 and overviewVertical == 0:
    return
  if not daemon[].currentModel.overviewUsesWorkspacePreviews():
    return

  daemon.enqueue(
    Msg(
      kind: MsgKind.WlOverviewWheel,
      overviewWheelX: point.x,
      overviewWheelY: point.y,
      overviewWheelHorizontal: overviewHorizontal,
      overviewWheelVertical: overviewVertical,
    )
  )

proc pointerIdForSwipeGesture(
    daemon: TriadDaemon, swipe: ptr pointerGestures.ZwpPointerGestureSwipeV1
): uint32 =
  if swipe == nil:
    return 0
  daemon.wlSwipePointerIds.getOrDefault(swipe.id(), 0'u32)

proc onWlSwipeBegin(
    data: pointer,
    swipe: ptr pointerGestures.ZwpPointerGestureSwipeV1,
    serial: uint32,
    time: uint32,
    surface: ptr Surface,
    fingers: uint32,
) =
  let daemon = callbackDaemon(data, "pointer swipe begin")
  if daemon == nil:
    return
  let pointerId = daemon[].pointerIdForSwipeGesture(swipe)
  if pointerId == 0:
    return
  daemon[].beginSwipeGesture(pointerId, fingers)
  trace "Pointer swipe begin", pointerId = pointerId, fingers = fingers

proc onWlSwipeUpdate(
    data: pointer,
    swipe: ptr pointerGestures.ZwpPointerGestureSwipeV1,
    time: uint32,
    dx: Fixed,
    dy: Fixed,
) =
  let daemon = callbackDaemon(data, "pointer swipe update")
  if daemon == nil:
    return
  let pointerId = daemon[].pointerIdForSwipeGesture(swipe)
  if pointerId == 0:
    return
  daemon[].updateSwipeGesture(pointerId, dx.fixedToFloat(), dy.fixedToFloat())

proc onWlSwipeEnd(
    data: pointer,
    swipe: ptr pointerGestures.ZwpPointerGestureSwipeV1,
    serial: uint32,
    time: uint32,
    cancelled: int32,
) =
  let daemon = callbackDaemon(data, "pointer swipe end")
  if daemon == nil:
    return
  let pointerId = daemon[].pointerIdForSwipeGesture(swipe)
  if pointerId == 0:
    return
  let dispatched = daemon[].endSwipeGesture(pointerId, cancelled != 0)
  trace "Pointer swipe end",
    pointerId = pointerId, cancelled = cancelled != 0, dispatched = dispatched

var wlSwipeListener* = pointerGestures.ZwpPointerGestureSwipeV1Listener(
  begin: onWlSwipeBegin, update: onWlSwipeUpdate, `end`: onWlSwipeEnd
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
  if daemon[].currentModel.cursor.hideWhenTyping:
    daemon[].hideAllCursors()
  let id = binding.id()
  daemon[].handleXkbBindingPressed(id)

proc onXkbReleased(data: pointer, binding: ptr riverXkb.RiverXkbBindingV1) =
  let daemon = callbackDaemon(data, "xkb released")
  if daemon == nil:
    return
  let id = binding.id()
  daemon[].handleXkbBindingReleased(id)
  trace "XKB binding released", bindingId = id

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
  daemon[].handleXkbSeatAteUnboundKey(seat.id())

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

proc pointerCommandTarget(
    daemon: TriadDaemon, seatId: uint32, seat: ptr RiverSeatV1
): WindowId =
  let focused = daemon.currentModel.activeFocusRiverId()
  if daemon.currentModel.overviewActive:
    if seat == nil:
      return 0
    daemon.overviewWindowAtPointer(seat)
  else:
    daemon.pointerWindowBySeat.getOrDefault(seatId, focused)

proc enqueuePointerCommand(
    daemon: var TriadDaemon, seatId: uint32, seat: ptr RiverSeatV1, msg: Msg
) =
  let target = daemon.pointerCommandTarget(seatId, seat)
  case msg.kind
  of MsgKind.CmdCloseWindow:
    if target != 0:
      daemon.enqueue(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: target))
    elif not daemon.currentModel.overviewActive:
      daemon.enqueue(msg)
  of MsgKind.CmdCloseWindowById:
    if target != 0 and daemon.currentModel.overviewActive:
      daemon.enqueue(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: target))
    else:
      daemon.enqueue(msg)
  of MsgKind.CmdSelectWindow:
    if daemon.currentModel.overviewActive and target != 0:
      daemon.queueWindowFocus(target)
      daemon.enqueue(msg)
    elif not daemon.currentModel.overviewActive:
      daemon.enqueue(msg)
  of MsgKind.CmdToggleFloating, MsgKind.CmdToggleFullscreen, MsgKind.CmdToggleMaximized,
      MsgKind.CmdMaximizeColumn, MsgKind.CmdMinimize, MsgKind.CmdMoveToScratchpad,
      MsgKind.CmdMoveToNamedScratchpad, MsgKind.CmdMoveFloating,
      MsgKind.CmdResizeFloating:
    if target != 0:
      daemon.queueWindowFocus(target)
      daemon.enqueue(msg)
    elif not daemon.currentModel.overviewActive:
      daemon.enqueue(msg)
  else:
    daemon.enqueue(msg)

proc onPointerBindingPressed(data: pointer, binding: ptr RiverPointerBindingV1) =
  let daemon = callbackDaemon(data, "pointer binding pressed")
  if daemon == nil:
    return
  let id = binding.id()
  daemon.pointerBindingPressed[id] = true
  if not daemon.pointerBindingSeats.hasKey(id):
    return
  let seat = daemon.pointerBindingSeats[id]
  let seatId = seat.id()
  let button = daemon.pointerBindingButtons.getOrDefault(id, 0'u32)
  let point = daemon.pointerPositionBySeat.getOrDefault(seatId, Rect())
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
  let target = daemon[].pointerCommandTarget(seatId, seat)
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
    daemon[].enqueuePointerCommand(seatId, seat, daemon.pointerBindings[id])

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
  daemon.attachCursorShapePointer(pointer.id())
  daemon.attachWlSwipePointer(pointer.id())
  discard pointer.addListener(wlPointerListener.addr, daemonData(daemon))

proc attachCursorShapePointer*(daemon: var TriadDaemon, pointerId: uint32) =
  if daemon.cursorShapeManager == nil or daemon.cursorShapeDevices.hasKey(pointerId):
    return
  let pointer = daemon.wlPointerById(pointerId)
  if pointer == nil:
    return
  daemon.cursorShapeDevices[pointerId] = daemon.cursorShapeManager.getPointer(pointer)

proc attachWlSwipePointer*(daemon: var TriadDaemon, pointerId: uint32) =
  if daemon.pointerGestures == nil or daemon.wlSwipePointers.hasKey(pointerId):
    return
  let pointer = daemon.wlPointerById(pointerId)
  if pointer == nil:
    return
  let swipe = daemon.pointerGestures.getSwipeGesture(pointer)
  if swipe == nil:
    return
  daemon.wlSwipePointers[pointerId] = swipe
  daemon.wlSwipePointerIds[swipe.id()] = pointerId
  daemon.wlSwipeStates[pointerId] = WlSwipeState()
  discard swipe.addListener(wlSwipeListener.addr, daemonData(daemon))

proc detachWlSwipePointer*(daemon: var TriadDaemon, pointerId: uint32) =
  if not daemon.wlSwipePointers.hasKey(pointerId):
    daemon.wlSwipeStates.del(pointerId)
    return
  let swipe = daemon.wlSwipePointers[pointerId]
  daemon.wlSwipePointerIds.del(swipe.id())
  daemon.wlSwipePointers.del(pointerId)
  daemon.wlSwipeStates.del(pointerId)
  swipe.destroy()

proc detachWlPointer*(daemon: var TriadDaemon, globalName: uint32) =
  if not daemon.wlPointerPointers.hasKey(globalName):
    return
  let pointer = daemon.wlPointerPointers[globalName]
  let pointerId = pointer.id()
  daemon.detachWlSwipePointer(pointerId)
  if daemon.cursorShapeDevices.hasKey(pointerId):
    daemon.cursorShapeDevices[pointerId].destroy()
    daemon.cursorShapeDevices.del(pointerId)
  daemon.cursorHiddenPointers.del(pointerId)
  daemon.cursorLastMotionMsByPointer.del(pointerId)
  pointer.destroy()
  daemon.wlPointerPointers.del(globalName)
  daemon.wlPointerGlobalNames.del(pointerId)
  daemon.wlPointerRiverSeats.del(pointerId)
  daemon.wlPointerWheelFrames.del(pointerId)
  daemon.wlPointerWheelRemainders.del(pointerId)

proc destroyPointerGesturesRuntime*(daemon: var TriadDaemon) =
  for swipe in daemon.wlSwipePointers.values:
    swipe.destroy()
  daemon.wlSwipePointers.clear()
  daemon.wlSwipePointerIds.clear()
  daemon.wlSwipeStates.clear()
  if daemon.pointerGestures != nil:
    if daemon.pointerGestures.getVersion() >= 2'u32:
      daemon.pointerGestures.release()
    else:
      daemon.pointerGestures.destroy()
  daemon.pointerGestures = nil
  daemon.pointerGesturesGlobalName = 0'u32

proc destroyCursorShapeRuntime*(daemon: var TriadDaemon) =
  for device in daemon.cursorShapeDevices.values:
    device.destroy()
  daemon.cursorShapeDevices.clear()
  daemon.cursorHiddenPointers.clear()
  if daemon.cursorShapeManager != nil:
    daemon.cursorShapeManager.destroy()
  daemon.cursorShapeManager = nil
  daemon.cursorShapeGlobalName = 0'u32

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
  daemon.xkbBindingOnRelease.clear()
  daemon.xkbBindingReleaseArmed.clear()
  daemon.xkbBindingWhileLocked.clear()
  daemon.xkbBindingModes.clear()
  daemon.xkbBindingModifiers.clear()
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

proc requestBindingReconfigure*(daemon: var TriadDaemon, reason: string) =
  daemon.bindingsReconfigurePending = true
  daemon.requestManage(reason)

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
  var storedMsg = msg
  if daemon.currentModel.overviewTabMode and modifiers != 0'u32 and
      msg.isOverviewTabOpenCommand():
    storedMsg = Msg(kind: MsgKind.CmdOverviewTab, overviewTabModifiers: modifiers)
  daemon.xkbBindingPointers.add(binding)
  daemon.xkbBindings[binding.id()] = storedMsg
  daemon.xkbBindingModes[binding.id()] = bindingConfig.mode
  daemon.xkbBindingModifiers[binding.id()] = modifiers
  daemon.xkbBindingOnRelease[binding.id()] = bindingConfig.onRelease
  daemon.xkbBindingWhileLocked[binding.id()] = bindingConfig.whileLocked
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

proc exitSessionConfirmKeyBinding(): KeyBindingConfig =
  KeyBindingConfig(key: "Return", modifiers: 0'u32, mode: BindingMode.BindAlways)

proc setupDefaultBindings*(daemon: var TriadDaemon) =
  if daemon.bindingsConfigured:
    return
  if daemon.seatPointers.len == 0:
    return

  for seat in daemon.seatPointers:
    daemon.attachXkbSeat(seat)

    if daemon.currentModel.exitSessionConfirmOpen:
      let binding = exitSessionConfirmKeyBinding()
      daemon.addXkbBinding(
        seat,
        binding,
        keySymForBinding(binding.key, binding.modifiers),
        binding.modifiers,
        Msg(kind: MsgKind.CmdConfirmExitSession),
      )
      continue

    for binding in daemon.currentModel.keyBindings:
      if not daemon.keyBindingActive(binding):
        continue
      let parsed = parseTextCommand(binding.command)
      let sym = keySymForBinding(binding.key, binding.modifiers)
      if parsed.isSome and sym != 0:
        daemon.addXkbBinding(seat, binding, sym, binding.modifiers, parsed.get())
    if not daemon.currentModel.sessionLocked and
        daemon.currentModel.overviewUsesWorkspacePreviews():
      for binding in daemon.currentModel.overviewFallbackKeyBindings():
        let parsed = parseTextCommand(binding.command)
        let sym = keySymForBinding(binding.key, binding.modifiers)
        if parsed.isSome and sym != 0:
          daemon.addXkbBinding(seat, binding, sym, binding.modifiers, parsed.get())
    if not daemon.currentModel.sessionLocked and daemon.currentModel.recentWindowsActive:
      for binding in daemon.currentModel.recentOpenFallbackKeyBindings():
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
  if daemon.bindingsReconfigurePending:
    daemon.destroyBindings()
    daemon.bindingsReconfigurePending = false
  daemon.setupDefaultBindings()
  daemon.syncHotkeyOverlayKeyCapture()
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
      edges = daemon.currentModel.tiledEdgesForWindow(data)
      discard daemon.ensureDecorationSurface(id, ProtocolSurfaceKind.PskDecorationBelow)
      discard daemon.ensureDecorationSurface(id, ProtocolSurfaceKind.PskDecorationAbove)
    else:
      win.useSsd()
    win.setTiled(edges)

  let focused = daemon.currentModel.activeFocusRiverId()
  for seat in daemon.seatPointers:
    if daemon.currentModel.cursor.theme.len > 0:
      seat.setXcursorTheme(
        cstring(daemon.currentModel.cursor.theme),
        daemon.configuredCursorSize(seat.id()),
      )
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
