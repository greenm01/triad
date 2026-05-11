import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as river_layer
import protocols/river_xkb_bindings/client as river_xkb
import wayland/protocols/wayland/client as wl_core
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import core/effects
import core/msg
import core/restore_state
import core/niri_state
import core/render_visibility
import systems/daemon_view
import systems/layout_projection
import systems/runtime
import systems/runtime_facade
import types/model
import types/shell_snapshot
import config/parser
import config/defaults
import config/keysyms
import config/reload_policy
import daemon/state
import daemon/process_runner
import daemon/protocol_surfaces
import daemon/protocol_surface_runtime
import daemon/quickshell_runner
import daemon/river_windows
import daemon/screenshot_runner
import ipc/commands
import ipc/quickshell_compat
import ipc/socket
import utils/overview_hit_test
import utils/behavior_log
import utils/runtime_log
import utils/session_env
import utils/wayland_runtime
from types/runtime_values import nil
from types/runtime_values import BindingMode, KeyBindingConfig,
  PointerBindingConfig, PointerOpKind, PresentationMode,
  ProtocolSurfacesConfig, QuickshellConfig, Rect, RenderInstruction,
  TerminalConfig, WindowId
import tables, os, fsnotify, asyncdispatch, chronicles, algorithm, asyncnet,
    nativesockets, strutils, options, times, json

var daemon = initTriadDaemon()

template display: untyped = daemon.display
template registry: untyped = daemon.registry
template river_manager: untyped = daemon.riverManager
template river_layer_shell: untyped = daemon.riverLayerShell
template river_xkb_bindings: untyped = daemon.riverXkbBindings
template compositor: untyped = daemon.compositor
template shm: untyped = daemon.shm
template singlePixelManager: untyped = daemon.singlePixelManager
template riverPhase: untyped = daemon.riverPhase
template bindingsConfigured: untyped = daemon.bindingsConfigured
template manageRequestPending: untyped = daemon.manageRequestPending
template manageRequestReason: untyped = daemon.manageRequestReason
template shmBufferCounter: untyped = daemon.shmBufferCounter
template runtimeState: untyped = daemon.runtimeState
template msgQueue: untyped = daemon.msgQueue
template pendingManageEffects: untyped = daemon.pendingManageEffects
template desiredPlacements: untyped = daemon.desiredPlacements
template desiredPlacementOrder: untyped = daemon.desiredPlacementOrder
template lastPointerOpSeat: untyped = daemon.lastPointerOpSeat
template windowPointers: untyped = daemon.windowPointers
template windowNodes: untyped = daemon.windowNodes
template outputPointers: untyped = daemon.outputPointers
template layerOutputPointers: untyped = daemon.layerOutputPointers
template layerOutputOwners: untyped = daemon.layerOutputOwners
template seatPointers: untyped = daemon.seatPointers
template layerSeatPointers: untyped = daemon.layerSeatPointers
template xkbBindings: untyped = daemon.xkbBindings
template xkbBindingPointers: untyped = daemon.xkbBindingPointers
template xkbSeatPointers: untyped = daemon.xkbSeatPointers
template xkbSeatAteUnbound: untyped = daemon.xkbSeatAteUnbound
template xkbBindingPressed: untyped = daemon.xkbBindingPressed
template xkbBindingModes: untyped = daemon.xkbBindingModes
template xkbStopRepeatCount: untyped = daemon.xkbStopRepeatCount
template pointerBindings: untyped = daemon.pointerBindings
template pointerBindingKinds: untyped = daemon.pointerBindingKinds
template pointerBindingSeats: untyped = daemon.pointerBindingSeats
template pointerBindingPointers: untyped = daemon.pointerBindingPointers
template pointerBindingPressed: untyped = daemon.pointerBindingPressed
template shellSurfacePointers: untyped = daemon.shellSurfacePointers
template protocolSurfaceRuntime: untyped = daemon.protocolSurfaceRuntime
template outputWlNames: untyped = daemon.outputWlNames
template outputGlobalOwners: untyped = daemon.outputGlobalOwners
template outputGlobalNames: untyped = daemon.outputGlobalNames
template wlOutputPointers: untyped = daemon.wlOutputPointers
template wlOutputListenerData: untyped = daemon.wlOutputListenerData
template seatWlNames: untyped = daemon.seatWlNames
template pointerWindowBySeat: untyped = daemon.pointerWindowBySeat
template pointerPositionBySeat: untyped = daemon.pointerPositionBySeat
template windowUnreliablePids: untyped = daemon.windowUnreliablePids
template pendingWindows: untyped = daemon.pendingWindows
template configPath: untyped = daemon.configPath
template watcher: untyped = daemon.watcher
template configReloadDebouncer: untyped = daemon.configReloadDebouncer
template shouldExit: untyped = daemon.shouldExit
template quickshellState: untyped = daemon.quickshellState
template startupCommandsPending: untyped = daemon.startupCommandsPending
template initialManageComplete: untyped = daemon.initialManageComplete
template pendingLiveRestorePath: untyped = daemon.pendingLiveRestorePath
template pendingLiveRestore: untyped = daemon.pendingLiveRestore
template liveRestoreCommitPending: untyped = daemon.liveRestoreCommitPending

template currentModel: untyped =
  runtimeState.model

template surfaceTable: untyped =
  protocolSurfaceRuntime.surfaces

template ownedShellSurfaceId: untyped =
  protocolSurfaceRuntime.ownedShellSurfaceId

template hotkeyOverlaySurfaceId: untyped =
  protocolSurfaceRuntime.hotkeyOverlaySurfaceId

template windowDecorationAbove: untyped =
  protocolSurfaceRuntime.windowDecorationAbove

template windowDecorationBelow: untyped =
  protocolSurfaceRuntime.windowDecorationBelow

proc id(p: pointer): uint32 =
  get_id(cast[ptr Proxy](p))

proc failCli(message: string) =
  stderr.writeLine("triad: " & message)
  quit 1

proc syncRuntimeUpdate(context: string; msg: Msg): seq[Effect] =
  runtimeState.applyRuntimeUpdate(msg)

proc readModelSnapshot(): ShellSnapshot =
  runtimeState.readRuntimeSnapshot()

proc readLiveRestoreJson(): string =
  result = runtimeState.readRuntimeLiveRestoreJson()
  if behaviorLogEnabled():
    let parsed = parseLiveRestoreJson(result)
    if parsed.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_dumped",
        defaultLiveRestorePath(),
        "ipc",
        parsed.get())

proc writeCurrentLiveRestoreState(): LiveRestoreWriteResult =
  result = runtimeState.writeRuntimeLiveRestoreState()
  if result.ok and behaviorLogEnabled():
    let parsed = parseLiveRestoreJson(runtimeState.readRuntimeLiveRestoreJson())
    if parsed.isSome:
      writeLiveRestoreBehaviorEvent(
        "live_restore_snapshot_written",
        result.path,
        "runtime",
        parsed.get())

proc syncRuntimeLayoutProjection(
    context: string; msg: Msg): seq[RenderInstruction] =
  runtimeState.applyRuntimeLayoutProjection().instructions

proc applyPendingLiveRestore(context: string) =
  if pendingLiveRestore.isNone:
    return

  let state = pendingLiveRestore.get()
  writeLiveRestoreBehaviorEvent(
    "live_restore_applied",
    pendingLiveRestorePath,
    context,
    state)
  discard runtimeState.applyRuntimeLiveRestore(state)
  pendingLiveRestore = none(LiveRestoreState)
  liveRestoreCommitPending = pendingLiveRestorePath.len > 0
  info "Live restore snapshot applied",
    path = pendingLiveRestorePath,
    context = context,
    activeTag = state.activeTag,
    windows = state.tagByWindow.len

proc commitPendingLiveRestore() =
  if not liveRestoreCommitPending:
    return

  if completeLiveRestoreState(pendingLiveRestorePath):
    info "Live restore snapshot committed", path = pendingLiveRestorePath
    writeBehaviorEvent("live_restore_committed", %*{
      "path": pendingLiveRestorePath,
      "restore_status": LiveRestoreStatusApplied
    })
    liveRestoreCommitPending = false
  else:
    warn "Live restore snapshot could not be committed",
        path = pendingLiveRestorePath

proc setupConfig() =
  configPath = defaultConfigPath()
  let configDir = configPath.splitFile().dir
  if not dirExists(configDir):
    createDir(configDir)

  if not fileExists(configPath):
    writeFile(configPath, FallbackConfigContent)
    info "Created default config", path = configPath

proc scheduleStartupCommands(model: Model) =
  startupCommandsPending = model.startupCommands.len > 0

proc spawnPendingStartupCommands(model: Model; reason: string) =
  if not startupCommandsPending:
    return
  startupCommandsPending = false
  info "Spawning startup commands", reason = reason
  spawnStartupCommands(model)

proc requestManage(reason: string)
proc destroyBindings()

proc broadcastNiriSnapshot(snapshot: ShellSnapshot) =
  for event in initialNiriEvents(snapshot):
    asyncCheck broadcastJson(event)

proc applyConfigReload(configPath, niriSocketPath: string): bool =
  let loaded = loadConfigStrict(configPath)
  if not loaded.ok:
    warn "Config reload rejected; keeping current config", path = configPath,
        error = loaded.error
    return false

  let previousModel = currentModel
  discard runtimeState.applyRuntimeConfig(loaded.config)
  quickshellState.spawnPending = false

  let quickshellAction = quickshellConfigReloadAction(
    previousModel.quickshell,
    currentModel.quickshell)
  writeBehaviorEvent("quickshell_config_reload_decision", %*{
    "reason": "config reload",
    "action": $quickshellAction,
    "changed": quickshellAction != QuickshellReloadAction.Noop,
    "previous": quickshellBehaviorPayload(
      previousModel.quickshell,
      "config reload"),
    "current": quickshellBehaviorPayload(
      currentModel.quickshell,
      "config reload")
  })

  case quickshellAction
  of QuickshellReloadAction.Noop, QuickshellReloadAction.SpawnOnly:
    discard
  of QuickshellReloadAction.AuthoritativeStop:
    quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true)
  of QuickshellReloadAction.AuthoritativeRestart:
    quickshellState.stopQuickshell(
      previousModel, "config reload", authoritative = true)
    discard quickshellState.spawnQuickshell(
      currentModel, niriSocketPath, "config reload")

  destroyBindings()
  info "Config reloaded", path = configPath
  requestManage("config reload")
  broadcastNiriSnapshot(readModelSnapshot())
  true


const
  RiverEdgeTop = 1'u32
  RiverEdgeBottom = 2'u32
  RiverEdgeLeft = 4'u32
  RiverEdgeRight = 8'u32
  RiverAllEdges = RiverEdgeTop or RiverEdgeBottom or RiverEdgeLeft or RiverEdgeRight
  RiverCapabilityFullscreen = 4'u32
  RiverCapabilityMaximize = 2'u32
  RiverCapabilityMinimize = 8'u32
  RiverCapabilityWindowMenu = 1'u32
  RiverBaseCapabilities = RiverCapabilityFullscreen or
      RiverCapabilityMaximize or RiverCapabilityMinimize
  RiverDecorationOnlySupportsCsd = 0'u32
  RiverPresentationVsync = 0'u32
  RiverPresentationAsync = 1'u32
  AllWatchedModifiers = 1'u32 or 4'u32 or 8'u32 or 32'u32 or 64'u32 or 128'u32

var
  xkb_binding_listener: river_xkb.RiverXkbBindingV1Listener
  pointer_binding_listener: RiverPointerBindingV1Listener
  layer_output_listener: river_layer.RiverLayerShellOutputV1Listener
  layer_seat_listener: river_layer.RiverLayerShellSeatV1Listener
  xkb_seat_listener: river_xkb.RiverXkbBindingsSeatV1Listener

proc applyBorder(win: ptr RiverWindowV1; focused: bool; edges: uint32) =
  let color =
    if focused:
      premulColor(currentModel.focusedBorderColor)
    else:
      premulColor(currentModel.unfocusedBorderColor)
  win.setBorders(
    edges, currentModel.borderWidth, color.r, color.g, color.b, color.a)

proc supportedCapabilities(model: Model): uint32 =
  result = RiverBaseCapabilities
  if model.windowMenuCommand.len > 0:
    result = result or RiverCapabilityWindowMenu

proc configuredPresentationMode(model: Model): uint32 =
  case model.presentationMode
  of PresentationMode.PresentationAsync: RiverPresentationAsync
  else: RiverPresentationVsync

proc hasPresentationPreference(model: Model): bool =
  model.presentationMode != PresentationMode.PresentationDefault

proc attachLayerOutput(outputId: uint32) =
  if river_layer_shell == nil or not outputPointers.hasKey(outputId) or
      layerOutputPointers.hasKey(outputId):
    return
  let layerOutput = river_layer_shell.getOutput(outputPointers[outputId])
  layerOutputPointers[outputId] = layerOutput
  layerOutputOwners[layerOutput.id()] = outputId
  discard layerOutput.addListener(
    layer_output_listener.addr, daemonData(daemon))

proc attachLayerSeat(seat: ptr RiverSeatV1) =
  if river_layer_shell == nil or seat == nil:
    return
  let layerSeat = river_layer_shell.getSeat(seat)
  layerSeatPointers.add(layerSeat)
  discard layerSeat.addListener(layer_seat_listener.addr, daemonData(daemon))

proc attachXkbSeat(seat: ptr RiverSeatV1) =
  if river_xkb_bindings == nil or seat == nil:
    return
  if river_xkb_bindings.getVersion() < 2'u32:
    return
  let seatId = seat.id()
  if xkbSeatPointers.hasKey(seatId):
    return
  let xkbSeat = river_xkb_bindings.getSeat(seat)
  xkbSeatPointers[seatId] = xkbSeat
  discard xkbSeat.addListener(xkb_seat_listener.addr, daemonData(daemon))
  xkbSeat.modifiersWatch(AllWatchedModifiers)

proc destroyBindings() =
  for binding in xkbBindingPointers:
    binding.disable()
    binding.destroy()
  xkbBindingPointers = @[]
  xkbBindings.clear()
  xkbBindingPressed.clear()
  xkbBindingModes.clear()
  xkbStopRepeatCount.clear()

  for binding in pointerBindingPointers:
    binding.disable()
    binding.destroy()
  pointerBindingPointers = @[]
  pointerBindings.clear()
  pointerBindingKinds.clear()
  pointerBindingSeats.clear()
  pointerBindingPressed.clear()
  bindingsConfigured = false

proc destroyXkbSeats() =
  for xkbSeat in xkbSeatPointers.values:
    xkbSeat.destroy()
  xkbSeatPointers.clear()

proc addXkbBinding(seat: ptr RiverSeatV1; bindingConfig: KeyBindingConfig;
    keysym, modifiers: uint32; msg: Msg) =
  if river_xkb_bindings == nil:
    return
  let binding = river_xkb_bindings.getXkbBinding(seat, keysym, modifiers)
  xkbBindingPointers.add(binding)
  xkbBindings[binding.id()] = msg
  xkbBindingModes[binding.id()] = bindingConfig.mode
  discard binding.addListener(xkb_binding_listener.addr, daemonData(daemon))
  if bindingConfig.hasLayoutOverride:
    binding.setLayoutOverride(bindingConfig.layoutOverride)
  binding.enable()

proc addPointerBinding(
    seat: ptr RiverSeatV1; bindingConfig: PointerBindingConfig) =
  var msg = none(Msg)
  if bindingConfig.op == PointerOpKind.OpNone:
    msg = parseTextCommand(bindingConfig.command)
    if msg.isNone:
      return

  let binding = seat.getPointerBinding(
    bindingConfig.button, bindingConfig.modifiers)
  pointerBindingPointers.add(binding)
  if bindingConfig.op != PointerOpKind.OpNone:
    pointerBindingKinds[binding.id()] = bindingConfig.op
  else:
    pointerBindings[binding.id()] = msg.get()
  pointerBindingSeats[binding.id()] = seat
  discard binding.addListener(pointer_binding_listener.addr, daemonData(daemon))
  binding.enable()

proc bindingModeActive(mode: BindingMode): bool =
  case mode
  of BindingMode.BindAlways: true
  of BindingMode.BindNormal: not currentModel.overviewActive
  of BindingMode.BindOverview: currentModel.overviewActive

proc keyBindingActive(binding: KeyBindingConfig): bool =
  if not bindingModeActive(binding.mode):
    return false
  if currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc pointerBindingActive(binding: PointerBindingConfig): bool =
  if not bindingModeActive(binding.mode):
    return false
  if currentModel.keyboardShortcutsInhibited() and
      not binding.bypassShortcutsInhibit:
    return false
  true

proc hasOverviewLeftClickBinding(): bool =
  for binding in currentModel.pointerBindings:
    if binding.button == 0x110'u32 and binding.modifiers == 0'u32 and
        binding.mode in {BindingMode.BindAlways, BindingMode.BindOverview}:
      return true
  false

proc overviewSelectPointerBinding(): PointerBindingConfig =
  PointerBindingConfig(
    button: 0x110'u32,
    modifiers: 0'u32,
    op: PointerOpKind.OpNone,
    command: "select-window",
    mode: BindingMode.BindOverview)

proc setupDefaultBindings() =
  if bindingsConfigured:
    return
  if seatPointers.len == 0:
    return

  for seat in seatPointers:
    attachXkbSeat(seat)

    for binding in currentModel.keyBindings:
      if not keyBindingActive(binding):
        continue
      let parsed = parseTextCommand(binding.command)
      let sym = keySymForBinding(binding.key, binding.modifiers)
      if parsed.isSome and sym != 0:
        addXkbBinding(seat, binding, sym, binding.modifiers, parsed.get())

    for binding in currentModel.pointerBindings:
      if pointerBindingActive(binding):
        addPointerBinding(seat, binding)
    if currentModel.overviewActive and not hasOverviewLeftClickBinding():
      addPointerBinding(seat, overviewSelectPointerBinding())

  bindingsConfigured = true

proc applyManageState() =
  setupDefaultBindings()
  if currentModel.protocolSurfaces.enabled:
    daemon.ensureOwnedShellSurface()
  else:
    daemon.destroyAllProtocolSurfaces()

  for id, win in windowPointers.pairs:
    win.setCapabilities(currentModel.supportedCapabilities())
    var edges = RiverAllEdges
    let dataOpt = currentModel.windowDataForRiverId(id)
    if dataOpt.isSome:
      let data = dataOpt.get()
      if data.hasDecorationHint and data.decorationHint == RiverDecorationOnlySupportsCsd:
        win.useCsd()
      else:
        win.useSsd()
      win.setDimensionBounds(data.maxWidth, data.maxHeight)
      if data.isFloating or data.isFullscreen:
        edges = 0
      discard daemon.ensureDecorationSurface(id,
          ProtocolSurfaceKind.PskDecorationBelow)
      discard daemon.ensureDecorationSurface(id,
          ProtocolSurfaceKind.PskDecorationAbove)
    else:
      win.useSsd()
    win.setTiled(edges)

  let focused = currentModel.activeFocusRiverId()
  for seat in seatPointers:
    if currentModel.cursor.theme.len > 0:
      let cursorSize = if currentModel.cursor.size ==
          0: 24'u32 else: currentModel.cursor.size
      seat.setXcursorTheme(cstring(currentModel.cursor.theme), cursorSize)
    if currentModel.layerFocusExclusive or currentModel.sessionLocked:
      seat.clearFocus()
    elif currentModel.overviewActive and ownedShellSurfaceId != 0 and
        shellSurfacePointers.hasKey(ownedShellSurfaceId):
      seat.focusShellSurface(shellSurfacePointers[ownedShellSurfaceId])
    elif focused != 0 and windowPointers.hasKey(focused):
      seat.focusWindow(windowPointers[focused])
    else:
      seat.clearFocus()

  let primaryOutput = currentModel.primaryOutputRiverId()
  if primaryOutput != 0 and layerOutputPointers.hasKey(primaryOutput):
    layerOutputPointers[primaryOutput].setDefault()

# --- RiverSeatV1 Callbacks ---

proc removeSeatPointer(seat: ptr RiverSeatV1) =
  var i = 0
  while i < seatPointers.len:
    if seatPointers[i] == seat:
      seatPointers.delete(i)
    else:
      inc i

proc on_seat_removed(data: pointer; seat: ptr RiverSeatV1) =
  info "Seat removed"
  let seatId = seat.id()
  removeSeatPointer(seat)
  seatWlNames.del(seatId)
  pointerWindowBySeat.del(seatId)
  pointerPositionBySeat.del(seatId)
  if xkbSeatPointers.hasKey(seatId):
    xkbSeatPointers[seatId].destroy()
    xkbSeatPointers.del(seatId)
  for layerSeat in layerSeatPointers:
    layerSeat.destroy()
  layerSeatPointers = @[]
  destroyBindings()
  seat.destroy()

proc on_seat_wl_seat(data: pointer; seat: ptr RiverSeatV1; name: uint32) =
  seatWlNames[seat.id()] = name
  trace "Seat wl_seat received", seatId = seat.id(), name = name

proc on_seat_pointer_enter(data: pointer; seat: ptr RiverSeatV1;
    win: ptr RiverWindowV1) =
  if win != nil:
    pointerWindowBySeat[seat.id()] = win.id()
    trace "Pointer entered window", seatId = seat.id(),
        windowId = win.id()

proc on_seat_pointer_leave(data: pointer; seat: ptr RiverSeatV1) =
  pointerWindowBySeat.del(seat.id())
  trace "Pointer left window", seatId = seat.id()

proc queueWindowFocus(target: WindowId) =
  if target == 0:
    return
  msgQueue.add(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: target))

proc queueWindowInteraction(target: WindowId) =
  if currentModel.overviewActive:
    return
  queueWindowFocus(target)

proc isDescendantRiverWindow(child, ancestor: WindowId): bool =
  if child == 0 or ancestor == 0 or child == ancestor:
    return false
  var current = child
  var depth = 0
  while current != 0 and depth < 64:
    let winOpt = currentModel.windowDataForRiverId(current)
    if winOpt.isNone:
      return false
    let parent = WindowId(uint32(winOpt.get().parentExternalId))
    if parent == 0:
      return false
    if parent == ancestor:
      return true
    current = parent
    inc depth
  false

proc logicalWindowSortKey(id: WindowId): uint32 =
  let logicalId = currentModel.windowForRiverId(id)
  if uint32(logicalId) != 0:
    return uint32(logicalId)
  uint32(id)

proc desiredStackCmp(a, b: WindowId): int =
  if isDescendantRiverWindow(a, b):
    return 1
  if isDescendantRiverWindow(b, a):
    return -1
  cmp(logicalWindowSortKey(a), logicalWindowSortKey(b))

proc orderedDesiredIds(): seq[WindowId] =
  for id in desiredPlacements.keys:
    if desiredPlacementOrder.find(id) == -1:
      result.add(id)
  for id in desiredPlacementOrder:
    if desiredPlacements.hasKey(id) and result.find(id) == -1:
      result.add(id)
  result.sort(desiredStackCmp)

proc orderedDesiredInstructions(): seq[RenderInstruction] =
  let highlighted =
    if currentModel.overviewActive: currentModel.highlightRiverId()
    else: 0'u32
  for id in orderedDesiredIds():
    if id != highlighted:
      result.add(RenderInstruction(
        windowId: id,
        geom: desiredPlacements[id]))
  if highlighted != 0 and desiredPlacements.hasKey(highlighted):
    result.add(RenderInstruction(
      windowId: highlighted,
      geom: desiredPlacements[highlighted]))

proc overviewWindowAtPointer(seat: ptr RiverSeatV1): WindowId =
  if not currentModel.overviewActive or seat == nil:
    return 0
  let seatId = seat.id()
  if not pointerPositionBySeat.hasKey(seatId):
    return 0
  let point = pointerPositionBySeat[seatId]
  overviewHitTest(orderedDesiredInstructions(), point.x, point.y)

proc on_seat_window_interaction(data: pointer; seat: ptr RiverSeatV1;
    win: ptr RiverWindowV1) =
  if win != nil:
    let id = win.id()
    debug "Seat window interaction", windowId = id
    queueWindowInteraction(id)

proc on_seat_shell_surface_interaction(data: pointer; seat: ptr RiverSeatV1;
    shellSurface: ptr RiverShellSurfaceV1) =
  if shellSurface != nil:
    let id = shellSurface.id()
    shellSurfacePointers[id] = shellSurface
    trace "Seat shell surface interaction", shellSurfaceId = id
    msgQueue.add(Msg(kind: MsgKind.WlShellSurfaceInteraction,
        shellSurfaceId: id))

proc on_op_delta(data: pointer; seat: ptr RiverSeatV1; dx: int32; dy: int32) =
  msgQueue.add(Msg(kind: MsgKind.WlPointerDelta, dx: dx, dy: dy))

proc on_op_release(data: pointer; seat: ptr RiverSeatV1) =
  msgQueue.add(Msg(kind: MsgKind.WlPointerRelease))

proc on_seat_pointer_position(data: pointer; seat: ptr RiverSeatV1; x: int32; y: int32) =
  pointerPositionBySeat[seat.id()] = Rect(x: x, y: y, w: 0, h: 0)
  trace "Seat pointer position", seatId = seat.id(), x = x, y = y

var seat_listener = RiverSeatV1Listener(
  removed: on_seat_removed,
  seat: on_seat_wl_seat,
  pointerEnter: on_seat_pointer_enter,
  pointerLeave: on_seat_pointer_leave,
  windowInteraction: on_seat_window_interaction,
  shellSurfaceInteraction: on_seat_shell_surface_interaction,
  opDelta: on_op_delta,
  opRelease: on_op_release,
  pointerPosition: on_seat_pointer_position
)

proc on_xkb_pressed(data: pointer; binding: ptr river_xkb.RiverXkbBindingV1) =
  let id = binding.id()
  xkbBindingPressed[id] = true
  if xkbBindingModes.hasKey(id) and not bindingModeActive(xkbBindingModes[id]):
    return
  if xkbBindings.hasKey(id):
    let msg = xkbBindings[id]
    msgQueue.add(msg)
    if currentModel.hotkeyOverlayOpen and
        msg.kind notin {MsgKind.CmdShowHotkeyOverlay,
          MsgKind.CmdToggleHotkeyOverlay, MsgKind.CmdHideHotkeyOverlay}:
      msgQueue.add(Msg(kind: MsgKind.CmdHideHotkeyOverlay))

proc on_xkb_released(data: pointer; binding: ptr river_xkb.RiverXkbBindingV1) =
  xkbBindingPressed[binding.id()] = false
  trace "XKB binding released", bindingId = binding.id()

proc on_xkb_stop_repeat(data: pointer; binding: ptr river_xkb.RiverXkbBindingV1) =
  let id = binding.id()
  xkbStopRepeatCount[id] = xkbStopRepeatCount.getOrDefault(id, 0'u32) + 1'u32
  trace "XKB binding stop-repeat", bindingId = id, count = xkbStopRepeatCount[id]

xkb_binding_listener = river_xkb.RiverXkbBindingV1Listener(
  pressed: on_xkb_pressed,
  released: on_xkb_released,
  stopRepeat: on_xkb_stop_repeat
)

proc on_xkb_seat_ate_unbound_key(data: pointer;
    seat: ptr river_xkb.RiverXkbBindingsSeatV1) =
  let id = seat.id()
  xkbSeatAteUnbound[id] = xkbSeatAteUnbound.getOrDefault(id, 0'u32) + 1'u32
  trace "XKB seat ate unbound key", xkbSeatId = id, count = xkbSeatAteUnbound[id]

proc on_xkb_seat_modifiers_update(data: pointer;
    seat: ptr river_xkb.RiverXkbBindingsSeatV1; old: uint32; new: uint32) =
  trace "XKB modifiers updated", xkbSeatId = seat.id(), old = old, new = new
  msgQueue.add(Msg(kind: MsgKind.WlModifiersChanged, oldModifiers: old,
      newModifiers: new))

xkb_seat_listener = river_xkb.RiverXkbBindingsSeatV1Listener(
  ateUnboundKey: on_xkb_seat_ate_unbound_key,
  modifiersUpdate: on_xkb_seat_modifiers_update
)

proc on_pointer_binding_pressed(data: pointer;
    binding: ptr RiverPointerBindingV1) =
  let id = binding.id()
  pointerBindingPressed[id] = true
  if not pointerBindingSeats.hasKey(id):
    return
  let seat = pointerBindingSeats[id]
  let focused = currentModel.activeFocusRiverId()
  let target =
    if currentModel.overviewActive:
      overviewWindowAtPointer(seat)
    else:
      pointerWindowBySeat.getOrDefault(seat.id(), focused)
  if pointerBindingKinds.hasKey(id):
    if currentModel.overviewActive:
      return
    if target == 0:
      return
    case pointerBindingKinds[id]
    of PointerOpKind.OpMove:
      msgQueue.add(Msg(kind: MsgKind.WlPointerMoveRequested, moveWinId: target,
          moveSeat: seat))
    of PointerOpKind.OpResize:
      msgQueue.add(Msg(kind: MsgKind.WlPointerResizeRequested,
          resizeWinId: target, resizeSeat: seat,
          resizeEdges: RiverEdgeBottom or RiverEdgeRight))
    else:
      discard
  elif pointerBindings.hasKey(id):
    let msg = pointerBindings[id]
    case msg.kind
    of MsgKind.CmdCloseWindow:
      if target != 0:
        msgQueue.add(Msg(kind: MsgKind.CmdCloseWindowById,
          closeWindowId: target))
      elif not currentModel.overviewActive:
        msgQueue.add(msg)
    of MsgKind.CmdCloseWindowById:
      if target != 0 and currentModel.overviewActive:
        msgQueue.add(Msg(kind: MsgKind.CmdCloseWindowById,
          closeWindowId: target))
      else:
        msgQueue.add(msg)
    of MsgKind.CmdSelectWindow:
      if currentModel.overviewActive and target != 0:
        queueWindowFocus(target)
        msgQueue.add(msg)
      elif not currentModel.overviewActive:
        msgQueue.add(msg)
    of MsgKind.CmdToggleFloating, MsgKind.CmdToggleFullscreen,
        MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize,
        MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
        MsgKind.CmdMoveFloating, MsgKind.CmdResizeFloating:
      if target != 0:
        queueWindowFocus(target)
        msgQueue.add(msg)
      elif not currentModel.overviewActive:
        msgQueue.add(msg)
    else:
      msgQueue.add(msg)

proc on_pointer_binding_released(data: pointer;
    binding: ptr RiverPointerBindingV1) =
  pointerBindingPressed[binding.id()] = false
  trace "Pointer binding released", bindingId = binding.id()

pointer_binding_listener = RiverPointerBindingV1Listener(
  pressed: on_pointer_binding_pressed,
  released: on_pointer_binding_released
)

proc on_layer_output_non_exclusive(
    data: pointer;
    layerOutput: ptr river_layer.RiverLayerShellOutputV1;
    x: int32;
    y: int32;
    width: int32;
    height: int32) =
  let layerId = layerOutput.id()
  if layerOutputOwners.hasKey(layerId):
    let outputId = layerOutputOwners[layerId]
    msgQueue.add(Msg(kind: MsgKind.WlOutputUsable, usableOutputId: outputId,
        usableX: x, usableY: y, usableW: width, usableH: height))

layer_output_listener = river_layer.RiverLayerShellOutputV1Listener(
  nonExclusiveArea: on_layer_output_non_exclusive
)

proc on_layer_seat_focus_exclusive(data: pointer;
    seat: ptr river_layer.RiverLayerShellSeatV1) =
  trace "Layer shell focus exclusive"
  msgQueue.add(Msg(kind: MsgKind.WlLayerFocusExclusive))

proc on_layer_seat_focus_non_exclusive(data: pointer;
    seat: ptr river_layer.RiverLayerShellSeatV1) =
  trace "Layer shell focus non-exclusive"
  msgQueue.add(Msg(kind: MsgKind.WlLayerFocusNonExclusive))

proc on_layer_seat_focus_none(data: pointer;
    seat: ptr river_layer.RiverLayerShellSeatV1) =
  msgQueue.add(Msg(kind: MsgKind.WlLayerFocusNone))
  requestManage("layer focus none")

layer_seat_listener = river_layer.RiverLayerShellSeatV1Listener(
  focusExclusive: on_layer_seat_focus_exclusive,
  focusNonExclusive: on_layer_seat_focus_non_exclusive,
  focusNone: on_layer_seat_focus_none
)

# --- Effects Execution ---

proc requestManage(reason: string) =
  if river_manager == nil:
    return
  if manageRequestPending:
    trace "Coalescing River manage request", reason = reason,
      pendingReason = manageRequestReason
    return
  manageRequestPending = true
  manageRequestReason = reason
  trace "Queued River manage sequence", reason = reason

proc flushManageRequest() =
  if not manageRequestPending or river_manager == nil or
      riverPhase != RiverPhase.RiverIdle:
    return
  let reason = manageRequestReason
  manageRequestPending = false
  manageRequestReason = ""
  trace "Requesting River manage sequence", reason = reason
  river_manager.manageDirty()

proc executeManageEffect(eff: Effect) =
  case eff.kind
  of EffectKind.EffOpStartPointer:
    if eff.opSeat != nil:
      lastPointerOpSeat = eff.opSeat
      cast[ptr RiverSeatV1](eff.opSeat).opStartPointer()
  of EffectKind.EffOpEnd:
    if eff.endSeat != nil:
      cast[ptr RiverSeatV1](eff.endSeat).opEnd()
      if lastPointerOpSeat == eff.endSeat:
        lastPointerOpSeat = nil
  of EffectKind.EffSetPosition:
    if windowPointers.hasKey(eff.windowId):
      windowPointers[eff.windowId].proposeDimensions(max(0'i32, eff.w), max(
          0'i32, eff.h))
  of EffectKind.EffFocusWindow:
    if not currentModel.sessionLocked and windowPointers.hasKey(eff.focusId):
      let win = windowPointers[eff.focusId]
      for seat in seatPointers:
        seat.focusWindow(win)
  of EffectKind.EffFocusShellSurface:
    if not currentModel.sessionLocked and shellSurfacePointers.hasKey(
        eff.focusShellSurfaceId):
      let shellSurface = shellSurfacePointers[eff.focusShellSurfaceId]
      for seat in seatPointers:
        seat.focusShellSurface(shellSurface)
  of EffectKind.EffCloseWindow:
    if windowPointers.hasKey(eff.closeId):
      windowPointers[eff.closeId].close()
  of EffectKind.EffInformResizeStart:
    if windowPointers.hasKey(eff.resizeLifecycleWinId):
      windowPointers[eff.resizeLifecycleWinId].informResizeStart()
  of EffectKind.EffInformResizeEnd:
    if windowPointers.hasKey(eff.resizeLifecycleWinId):
      windowPointers[eff.resizeLifecycleWinId].informResizeEnd()
  of EffectKind.EffSetFullscreen:
    if windowPointers.hasKey(eff.fsWinId):
      let win = windowPointers[eff.fsWinId]
      if eff.isFullscreen:
        var output: ptr RiverOutputV1 = nil
        if eff.fsOutputId != 0 and outputPointers.hasKey(eff.fsOutputId):
          output = outputPointers[eff.fsOutputId]
        else:
          let primaryOutput = currentModel.primaryOutputRiverId()
          if primaryOutput != 0 and outputPointers.hasKey(primaryOutput):
            output = outputPointers[primaryOutput]
        if output == nil and outputPointers.len > 0:
          for p in outputPointers.values:
            output = p
            break
        if output != nil:
          win.fullscreen(output)
          win.informFullscreen()
      else:
        win.exitFullscreen()
        win.informNotFullscreen()
  of EffectKind.EffSetMaximized:
    if windowPointers.hasKey(eff.maxWinId):
      if eff.isMaximized:
        windowPointers[eff.maxWinId].informMaximized()
      else:
        windowPointers[eff.maxWinId].informUnmaximized()
  else:
    discard

proc queueManageEffect(eff: Effect) =
  if riverPhase == RiverPhase.RiverManage:
    executeManageEffect(eff)
  else:
    pendingManageEffects.add(eff)
    requestManage($eff.kind)

proc flushPendingManageEffects() =
  if pendingManageEffects.len == 0:
    return
  let effects = pendingManageEffects
  pendingManageEffects = @[]
  for eff in effects:
    executeManageEffect(eff)

proc placementHonorsMinimums(id: WindowId): bool =
  if currentModel.overviewActive:
    return false
  let winOpt = currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return true
  let win = winOpt.get()
  let scratchpad = currentModel.isScratchpadVisible and
    currentModel.visibleScratchpadRiverId() == id
  win.isFloating or win.isFullscreen or scratchpad

proc placementNeedsCellClip(id: WindowId; geom: Rect): bool =
  let winOpt = currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if not currentModel.overviewActive:
    let scratchpad = currentModel.isScratchpadVisible and
      currentModel.visibleScratchpadRiverId() == id
    if win.isFloating or win.isFullscreen or scratchpad:
      return false
  win.needsCellClip(geom.w, geom.h)

proc recordDesiredPlacement(instr: RenderInstruction) =
  if desiredPlacements.hasKey(instr.windowId):
    let existingIdx = desiredPlacementOrder.find(instr.windowId)
    if existingIdx != -1:
      desiredPlacementOrder.delete(existingIdx)
  desiredPlacementOrder.add(instr.windowId)
  desiredPlacements[instr.windowId] = instr.geom

proc recordDesiredPlacements(instructions: seq[RenderInstruction]) =
  desiredPlacements.clear()
  desiredPlacementOrder.setLen(0)
  for instr in instructions:
    recordDesiredPlacement(instr)

proc proposeDesiredDimensions(instructions: seq[RenderInstruction]) =
  recordDesiredPlacements(instructions)
  for instr in instructions:
    if windowPointers.hasKey(instr.windowId):
      var geom = instr.geom
      let proposal = currentModel.proposalDimensionsForRiverId(
        instr.windowId,
        geom.w,
        geom.h,
        placementHonorsMinimums(instr.windowId))
      geom.w = proposal.w
      geom.h = proposal.h
      windowPointers[instr.windowId].proposeDimensions(max(0'i32, geom.w), max(
          0'i32, geom.h))

proc applyVisibility(
    win: ptr RiverWindowV1; visibility: RenderVisibility; forceClip: bool;
    borderWidth: int32) =
  if visibility.visible:
    win.show()
    if visibility.clipped or forceClip:
      let clips = visibility.renderClipBoxes(borderWidth)
      win.setClipBox(clips.windowX, clips.windowY, clips.windowW,
          clips.windowH)
      win.setContentClipBox(clips.contentX, clips.contentY,
          clips.contentW, clips.contentH)
    else:
      win.setClipBox(0, 0, 0, 0)
      win.setContentClipBox(0, 0, 0, 0)
  else:
    win.hide()

proc renderDesiredPlacements() =
  let screen = currentModel.primaryScreen()
  if currentModel.hasPresentationPreference():
    let mode = currentModel.configuredPresentationMode()
    for output in outputPointers.values:
      output.setPresentationMode(mode)
  let ids = orderedDesiredIds()

  var visible = initTable[WindowId, bool]()
  var lastNode: ptr RiverNodeV1 = nil
  var firstNode: ptr RiverNodeV1 = nil
  let highlighted = currentModel.highlightRiverId()
  for id in ids:
    if windowNodes.hasKey(id):
      let node = windowNodes[id]
      let geom = desiredPlacements[id]
      visible[id] = true
      node.setPosition(geom.x, geom.y)
      if firstNode == nil:
        firstNode = node
      if lastNode != nil:
        node.placeAbove(lastNode)
      lastNode = node
      if windowPointers.hasKey(id):
        let visibility = renderVisibility(geom, screen, max(
            currentModel.borderWidth * 2, 4'i32))
        windowPointers[id].applyVisibility(
          visibility,
          placementNeedsCellClip(id, geom),
          currentModel.borderWidth)
        windowPointers[id].applyBorder(
          id == highlighted, visibility.borderEdges)

  for id, win in windowPointers.pairs:
    if not visible.hasKey(id):
      win.hide()

  let maxSupported = currentModel.activeLayoutSupportsMaximize()
  for id in ids:
    if windowNodes.hasKey(id):
      let visibleScratchpad = currentModel.visibleScratchpadRiverId()
      let isScratchpad = currentModel.isScratchpadVisible and
        visibleScratchpad == id
      let winOpt = currentModel.windowDataForRiverId(id)
      let isFloating = winOpt.isSome and winOpt.get().isFloating
      let isFullscreen = winOpt.isSome and winOpt.get().isFullscreen
      let isMaximized = winOpt.isSome and winOpt.get().isMaximized
      if not isFloating and not isScratchpad and
          (isFullscreen or (isMaximized and maxSupported) or
            id == highlighted):
        windowNodes[id].placeTop()

  for id in ids:
    if windowNodes.hasKey(id):
      let visibleScratchpad = currentModel.visibleScratchpadRiverId()
      let isScratchpad = currentModel.isScratchpadVisible and
        visibleScratchpad == id
      let winOpt = currentModel.windowDataForRiverId(id)
      let isFloating = winOpt.isSome and winOpt.get().isFloating
      if isFloating or isScratchpad or id == highlighted:
        windowNodes[id].placeTop()

  if ownedShellSurfaceId != 0 and surfaceTable.hasKey(ownedShellSurfaceId):
    daemon.syncOwnedShellSurface(screen)
    var shell = surfaceTable[ownedShellSurfaceId]
    if shell.node != nil:
      shell.node.setPosition(screen.x, screen.y)
      if currentModel.overviewActive:
        shell.node.placeTop()
      else:
        shell.node.placeBottom()
        if firstNode != nil:
          shell.node.placeBelow(firstNode)
    surfaceTable[ownedShellSurfaceId] = shell

  daemon.syncHotkeyOverlaySurface(screen)

proc executeEffect(eff: Effect) =
  case eff.kind
  of EffectKind.EffLog:
    info "log", msg = eff.msg
  of EffectKind.EffManageFinish:
    if river_manager != nil and riverPhase == RiverPhase.RiverManage:
      river_manager.manageFinish()
      commitPendingLiveRestore()
  of EffectKind.EffRenderFinish:
    if river_manager != nil and riverPhase == RiverPhase.RiverRender:
      river_manager.renderFinish()
  of EffectKind.EffManageDirty:
    requestManage("effect")
  of EffectKind.EffBroadcastJson:
    asyncCheck broadcastJson(eff.jsonPayload)
  of EffectKind.EffBroadcastTriadJson:
    asyncCheck broadcastTriadJson(eff.jsonPayload, eff.triadEventName)
  of EffectKind.EffSpawnScreenLock:
    spawnScreenLock(eff.screenLockCommand)
  of EffectKind.EffSpawnWindowMenu:
    spawnWindowMenu(eff.windowMenuCommand, eff.windowMenuId, eff.windowMenuX,
        eff.windowMenuY)
  of EffectKind.EffSpawn:
    spawnCommand(eff.spawnCommand)
  of EffectKind.EffPointerWarp:
    for seat in seatPointers:
      seat.pointerWarp(eff.warpX, eff.warpY)
  of EffectKind.EffEnsureNextKeyEaten:
    for xkbSeat in xkbSeatPointers.values:
      xkbSeat.ensureNextKeyEaten()
  of EffectKind.EffCancelEnsureNextKeyEaten:
    for xkbSeat in xkbSeatPointers.values:
      xkbSeat.cancelEnsureNextKeyEaten()
  of EffectKind.EffStopManager:
    quickshellState.spawnPending = false
    quickshellState.releaseTrackedQuickshell("manager stop")
    if river_manager != nil:
      river_manager.stop()
  of EffectKind.EffTriadReload:
    let restore = writeCurrentLiveRestoreState()
    if not restore.ok:
      warn "Triad reload rejected; live restore snapshot could not be written",
        path = restore.path,
        error = restore.error
      return
    quickshellState.spawnPending = false
    quickshellState.releaseTrackedQuickshell("triad reload")
    if river_manager != nil:
      river_manager.stop()
  of EffectKind.EffExitSession:
    if river_manager != nil and currentModel.allowExitSession:
      river_manager.exitSession()
  of EffectKind.EffFocusShellUi:
    daemon.ensureOwnedShellSurface()
    if ownedShellSurfaceId != 0:
      queueManageEffect(Effect(kind: EffectKind.EffFocusShellSurface,
          focusShellSurfaceId: ownedShellSurfaceId))
  of EffectKind.EffScreenshot:
    asyncCheck runScreenshotCapture(
        addr daemon, eff.screenshotKind, eff.screenshotPath,
        eff.screenshotPointerMode, eff.screenshotWriteToDisk,
        eff.screenshotCopyToClipboard)
  of EffectKind.EffOpStartPointer, EffectKind.EffOpEnd,
      EffectKind.EffFocusWindow, EffectKind.EffFocusShellSurface,
      EffectKind.EffCloseWindow, EffectKind.EffSetFullscreen,
      EffectKind.EffSetMaximized, EffectKind.EffInformResizeStart,
      EffectKind.EffInformResizeEnd:
    queueManageEffect(eff)
  of EffectKind.EffSetPosition:
    if riverPhase == RiverPhase.RiverRender and windowNodes.hasKey(eff.windowId):
      let node = windowNodes[eff.windowId]
      node.setPosition(eff.x, eff.y)

      let winOpt = currentModel.windowDataForRiverId(eff.windowId)
      if winOpt.isSome and winOpt.get().isFloating:
        node.placeTop()
    else:
      recordDesiredPlacement(RenderInstruction(
        windowId: eff.windowId,
        geom: Rect(x: eff.x, y: eff.y, w: eff.w, h: eff.h)))
      queueManageEffect(eff)
  else:
    discard

# --- Wayland Callbacks ---

proc cleanupRiverObjects() =
  manageRequestPending = false
  manageRequestReason = ""

  daemon.destroyAllProtocolSurfaces()

  var winIds: seq[WindowId] = @[]
  for id in windowPointers.keys:
    winIds.add(id)
  for id in winIds:
    daemon.forgetWindow(id)

  var outputIds: seq[uint32] = @[]
  for id in outputPointers.keys:
    outputIds.add(id)
  for id in outputIds:
    if layerOutputPointers.hasKey(id):
      let layerOutput = layerOutputPointers[id]
      layerOutputOwners.del(layerOutput.id())
      layerOutputPointers.del(id)
      layerOutput.destroy()
    let output = outputPointers[id]
    outputPointers.del(id)
    output.destroy()
  outputWlNames.clear()

  for seat in layerSeatPointers:
    seat.destroy()
  layerSeatPointers = @[]

  destroyBindings()
  destroyXkbSeats()
  xkbSeatAteUnbound.clear()

  let seats = seatPointers
  seatPointers = @[]
  for seat in seats:
    seat.destroy()
  seatWlNames.clear()
  pointerWindowBySeat.clear()
  pointerPositionBySeat.clear()

  if river_xkb_bindings != nil:
    river_xkb_bindings.destroy()
    river_xkb_bindings = nil
  if river_layer_shell != nil:
    river_layer_shell.destroy()
    river_layer_shell = nil

proc on_manager_unavailable(data: pointer; mgr: ptr RiverWindowManagerV1) =
  fatal "River window manager interface is unavailable"
  quit 1

proc on_manager_finished(data: pointer; mgr: ptr RiverWindowManagerV1) =
  warn "River window manager interface finished"
  cleanupRiverObjects()
  if river_manager != nil:
    river_manager.destroy()
    river_manager = nil
  shouldExit = true

proc on_session_locked(data: pointer; mgr: ptr RiverWindowManagerV1) =
  info "River session locked"
  msgQueue.add(Msg(kind: MsgKind.WlSessionLocked))

proc on_session_unlocked(data: pointer; mgr: ptr RiverWindowManagerV1) =
  info "River session unlocked"
  msgQueue.add(Msg(kind: MsgKind.WlSessionUnlocked))

proc on_manage_start(data: pointer; mgr: ptr RiverWindowManagerV1) =
  debug "River manage start", pendingWindows = pendingWindows.len
  applyPendingLiveRestore("manage start")
  # Queue all creations first so parent metadata can resolve against any other
  # window discovered in this manage batch.
  for id, data in pendingWindows:
    msgQueue.add(Msg(kind: MsgKind.WlWindowCreated, windowId: id,
        createdParentWindowId: data.parentId,
        appId: data.appId, title: data.title,
        createdIdentifier: data.identifier,
        deferAdmission: data.parentId == 0))

  for id, data in pendingWindows:
    if data.actualW > 0 or data.actualH > 0:
      msgQueue.add(Msg(kind: MsgKind.WlWindowDimensions, dimensionsWindowId: id,
          actualWidth: data.actualW, actualHeight: data.actualH))
    if data.minWidth > 0 or data.minHeight > 0 or data.maxWidth > 0 or
        data.maxHeight > 0:
      msgQueue.add(Msg(
        kind: MsgKind.WlWindowDimensionsHint,
        hintWindowId: id,
        minWidth: data.minWidth,
        minHeight: data.minHeight,
        maxWidth: data.maxWidth,
        maxHeight: data.maxHeight))
    if data.hasDecorationHint:
      msgQueue.add(Msg(kind: MsgKind.WlWindowDecorationHint,
          decorationWindowId: id, decorationHint: data.decorationHint))
    if data.hasPresentationHint:
      msgQueue.add(Msg(kind: MsgKind.WlWindowPresentationHint,
          presentationWindowId: id, presentationHint: data.presentationHint))
    if data.parentId != 0:
      msgQueue.add(Msg(kind: MsgKind.WlWindowParent, childWindowId: id,
          parentWindowId: data.parentId))
    if data.isFullscreen:
      msgQueue.add(Msg(kind: MsgKind.WlWindowFullscreenRequested,
          fullscreenRequestId: id, fullscreenOutputId: data.fullscreenOutput))
    if data.isMaximized:
      msgQueue.add(Msg(kind: MsgKind.WlWindowMaximizeRequested,
          maximizeRequestId: id))
    if data.isMinimized:
      msgQueue.add(Msg(kind: MsgKind.WlWindowMinimizeRequested,
          minimizeRequestId: id))
  pendingWindows.clear()
  msgQueue.add(Msg(kind: MsgKind.WlManageStart))

proc on_render_start(data: pointer; mgr: ptr RiverWindowManagerV1) =
  trace "River render start"
  msgQueue.add(Msg(kind: MsgKind.WlRenderStart))

proc on_window(data: pointer; mgr: ptr RiverWindowManagerV1;
    win: ptr RiverWindowV1) =
  daemon.trackWindow(win)

proc on_output_dimensions(data: pointer; output: ptr RiverOutputV1;
    width: int32; height: int32) =
  info "Output dimensions changed", outputId = output.id(), width = width,
      height = height
  msgQueue.add(Msg(kind: MsgKind.WlOutputDimensions, outputId: output.id(),
      width: width, height: height))

proc on_output_removed(data: pointer; output: ptr RiverOutputV1) =
  let id = output.id()
  info "Output removed", outputId = id
  if layerOutputPointers.hasKey(id):
    let layerOutput = layerOutputPointers[id]
    layerOutputOwners.del(layerOutput.id())
    layerOutputPointers.del(id)
    layerOutput.destroy()
  outputPointers.del(id)
  if outputWlNames.hasKey(id):
    outputGlobalOwners.del(outputWlNames[id])
    outputWlNames.del(id)
  msgQueue.add(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: id))
  output.destroy()

proc on_output_wl_output(data: pointer; output: ptr RiverOutputV1;
    name: uint32) =
  let outputId = output.id()
  outputWlNames[outputId] = name
  outputGlobalOwners[name] = outputId
  trace "Output wl_output received", outputId = outputId, name = name
  if outputGlobalNames.hasKey(name):
    msgQueue.add(Msg(kind: MsgKind.WlOutputName, nameOutputId: outputId,
        outputName: outputGlobalNames[name]))

proc on_wl_output_geometry(
  data: pointer;
  output: ptr Output;
  x: int32;
  y: int32;
  physicalWidth: int32;
  physicalHeight: int32;
  subpixel: int32;
  make: cstring;
  model: cstring;
  transform: int32
) =
  discard

proc on_wl_output_mode(
  data: pointer;
  output: ptr Output;
  flags: uint32;
  width: int32;
  height: int32;
  refresh: int32
) =
  discard

proc on_wl_output_done(data: pointer; output: ptr Output) =
  discard

proc on_wl_output_scale(data: pointer; output: ptr Output; factor: int32) =
  discard

proc on_wl_output_name(data: pointer; output: ptr Output; name: cstring) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output name without daemon context"
    return
  let globalName = listenerData.globalName
  let outputName = $name
  outputGlobalNames[globalName] = outputName
  trace "wl_output name received", globalName = globalName,
      outputName = outputName
  if outputGlobalOwners.hasKey(globalName):
    msgQueue.add(Msg(kind: MsgKind.WlOutputName,
        nameOutputId: outputGlobalOwners[globalName], outputName: outputName))

proc on_wl_output_description(data: pointer; output: ptr Output;
    description: cstring) =
  discard

proc on_output_position(data: pointer; output: ptr RiverOutputV1; x: int32; y: int32) =
  info "Output position changed", outputId = output.id(), x = x, y = y
  msgQueue.add(Msg(kind: MsgKind.WlOutputPosition,
      positionOutputId: output.id(), outputX: x, outputY: y))

# Listener setup
var
  manager_listener: RiverWindowManagerV1Listener
  output_listener: RiverOutputV1Listener
  wl_output_listener: wl_core.OutputListener

proc on_output(data: pointer; mgr: ptr RiverWindowManagerV1;
    output: ptr RiverOutputV1) =
  let id = output.id()
  info "Output discovered", outputId = id
  outputPointers[id] = output
  discard output.addListener(output_listener.addr, daemonData(daemon))
  attachLayerOutput(id)

proc on_seat(data: pointer; mgr: ptr RiverWindowManagerV1;
    seat: ptr RiverSeatV1) =
  info "Seat discovered", seatIndex = seatPointers.len
  seatPointers.add(seat)
  discard seat.addListener(seat_listener.addr, daemonData(daemon))
  attachLayerSeat(seat)
  bindingsConfigured = false
  requestManage("seat discovered")

# --- Registry Callbacks ---

proc registry_handle_global(data: pointer; registry: ptr Registry; name: uint32;
    interface_name: cstring; version: uint32) =
  let interfaceName = $interface_name
  debug "Wayland global advertised", name = name, interfaceName = interfaceName,
      version = version
  # Bind to the river_window_manager_v1 interface
  if interfaceName == "river_window_manager_v1":
    if version < 4'u32:
      fatal "river_window_manager_v1 v4 is required",
          advertisedVersion = version
      quit 1
    river_manager = cast[ptr RiverWindowManagerV1](registry.`bind`(name,
        river_window_manager_v1_interface.addr, 4'u32))
    discard river_manager.addListener(manager_listener.addr, daemonData(daemon))
    info "Bound to river_window_manager_v1", name = name,
        advertisedVersion = version, boundVersion = 4
    daemon.ensureOwnedShellSurface()
  elif interfaceName == "wl_compositor":
    compositor = cast[ptr Compositor](registry.`bind`(name,
        wl_compositor_interface.addr, min(version, 6'u32)))
    info "Bound to wl_compositor", name = name, advertisedVersion = version
    daemon.ensureOwnedShellSurface()
  elif interfaceName == "wl_shm":
    shm = cast[ptr Shm](registry.`bind`(name,
        wl_core.wl_shm_interface.addr, min(version, 1'u32)))
    info "Bound to wl_shm", name = name, advertisedVersion = version
  elif interfaceName == "wl_output":
    let wlOutput = cast[ptr Output](registry.`bind`(name,
        wl_core.wl_output_interface.addr, min(version, 4'u32)))
    wlOutputPointers[name] = wlOutput
    let listenerData = WlOutputListenerData(
      daemon: daemonFromData(daemonData(daemon)),
      globalName: name)
    wlOutputListenerData[name] = new(WlOutputListenerData)
    wlOutputListenerData[name][] = listenerData
    discard wlOutput.addListener(
      wl_output_listener.addr,
      cast[pointer](wlOutputListenerData[name]))
    debug "Bound to wl_output", name = name, advertisedVersion = version,
        boundVersion = min(version, 4'u32)
  elif interfaceName == "river_layer_shell_v1":
    river_layer_shell = cast[ptr river_layer.RiverLayerShellV1](registry.`bind`(
        name, river_layer.river_layer_shell_v1_interface.addr, min(version, 1'u32)))
    for outputId in outputPointers.keys:
      attachLayerOutput(outputId)
    for seat in seatPointers:
      attachLayerSeat(seat)
    info "Bound to river_layer_shell_v1", name = name,
        advertisedVersion = version
  elif interfaceName == "river_xkb_bindings_v1":
    river_xkb_bindings = cast[ptr river_xkb.RiverXkbBindingsV1](registry.`bind`(
        name, river_xkb.river_xkb_bindings_v1_interface.addr, min(version, 3'u32)))
    bindingsConfigured = false
    requestManage("xkb bindings discovered")
    info "Bound to river_xkb_bindings_v1", name = name,
        advertisedVersion = version
  elif interfaceName == "wp_single_pixel_buffer_manager_v1":
    singlePixelManager = cast[ptr singlepixel.WpSinglePixelBufferManagerV1](
        registry.`bind`(name,
        singlepixel.wp_single_pixel_buffer_manager_v1_interface.addr, min(
        version, 1'u32)))
    info "Bound to wp_single_pixel_buffer_manager_v1", name = name,
        advertisedVersion = version


proc registry_handle_global_remove(data: pointer; registry: ptr Registry;
    name: uint32) =
  debug "Wayland global removed", name = name
  if wlOutputPointers.hasKey(name):
    wlOutputPointers[name].release()
    wlOutputPointers.del(name)
  wlOutputListenerData.del(name)
  outputGlobalNames.del(name)
  if outputGlobalOwners.hasKey(name):
    let outputId = outputGlobalOwners[name]
    outputGlobalOwners.del(name)
    msgQueue.add(Msg(kind: MsgKind.WlOutputName, nameOutputId: outputId,
        outputName: ""))

var registry_listener = RegistryListener(
  global: registry_handle_global,
  globalRemove: registry_handle_global_remove
)

proc startAnimationLoop() {.async.} =
  while true:
    {.cast(gcsafe).}:
      msgQueue.add(Msg(kind: MsgKind.CmdTick))
    await sleepAsync(16) # ~60fps

proc processQueuedMessages(configPath, niriSocketPath: string) =
  while msgQueue.len > 0:
    let msg = msgQueue[0]
    msgQueue.delete(0)

    if msg.kind == MsgKind.WlPointerRelease:
      if currentModel.pointerOp.kind != PointerOpKind.OpNone:
        if lastPointerOpSeat != nil:
          executeEffect(Effect(kind: EffectKind.EffOpEnd,
              endSeat: lastPointerOpSeat))

    if msg.kind == MsgKind.CmdSpawnTerminal:
      spawnTerminal(currentModel)
      continue

    if msg.kind == MsgKind.CmdConfigReload:
      discard applyConfigReload(configPath, niriSocketPath)
      continue

    let previousOverview = currentModel.overviewActive
    let previousShortcutsInhibited = currentModel.keyboardShortcutsInhibited()
    let effects = syncRuntimeUpdate("message", msg)
    if previousOverview != currentModel.overviewActive or
        previousShortcutsInhibited != currentModel.keyboardShortcutsInhibited():
      destroyBindings()
      requestManage("binding profile changed")

    if msg.kind == MsgKind.WlManageStart:
      riverPhase = RiverPhase.RiverManage
      let instructions = syncRuntimeLayoutProjection("manage layout", msg)
      proposeDesiredDimensions(instructions)
      applyManageState()
      flushPendingManageEffects()
      for eff in effects:
        if eff.kind != EffectKind.EffManageDirty:
          executeEffect(eff)
      executeEffect(Effect(kind: EffectKind.EffManageFinish))
      riverPhase = RiverPhase.RiverIdle
      if not initialManageComplete:
        initialManageComplete = true
        info "Initial manage completed",
          outputs = outputPointers.len,
          windows = windowPointers.len,
          seats = seatPointers.len
      spawnPendingStartupCommands(currentModel, "initial manage")
      continue

    if msg.kind == MsgKind.WlRenderStart:
      riverPhase = RiverPhase.RiverRender
      let instructions = syncRuntimeLayoutProjection("render layout", msg)
      recordDesiredPlacements(instructions)
      renderDesiredPlacements()
      for windowId in runtimeState.pendingAdmissionWindowIds():
        msgQueue.add(Msg(
          kind: MsgKind.WlWindowAdmissionSettled,
          admissionWindowId: windowId))
      executeEffect(Effect(kind: EffectKind.EffRenderFinish))
      riverPhase = RiverPhase.RiverIdle
      continue

    for eff in effects:
      executeEffect(eff)

proc hasInitialRiverState(): bool =
  outputPointers.len > 0 or seatPointers.len > 0

proc waitForInitialRiverState(timeoutMs: int): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while not hasInitialRiverState() and epochTime() < deadline:
    if not dispatchPendingWayland(display):
      return false
    if hasInitialRiverState():
      return true
    if not prepareWaylandRead(display):
      return false
    if hasInitialRiverState():
      display.cancel_read()
      return true

    discard display.flush()
    let remainingMs = max(1, min(16,
      int((deadline - epochTime()) * 1000.0)))
    if waitForWaylandEvents(display, remainingMs):
      if display.read_events() == -1:
        return false
    else:
      display.cancel_read()

  hasInitialRiverState()

# --- Main Loop ---

proc main() =
  configureLogging()

  if paramCount() >= 2 and paramStr(1) == "msg":
    let cmdPart = paramStr(2)
    if cmdPart == "event-stream":
      # Subscription client
      let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      try:
        waitFor client.connectUnix(triadSocketPath())
        waitFor client.send("event-stream\L")
        while not client.isClosed:
          let line = waitFor client.recvLine()
          if line != "": echo line
      except CatchableError as e:
        if not client.isClosed:
          client.close()
        failCli("event stream failed: " & e.msg)
      return

    var cmd = ""
    for i in 2 .. paramCount():
      if i > 2: cmd.add(" ")
      cmd.add(paramStr(i))
    try:
      if cmd == "dump-live-restore-state":
        let reply = waitFor sendIpcRequest(triadSocketPath(), cmd)
        stdout.writeLine(reply)
      else:
        waitFor sendIpcMsg(triadSocketPath(), cmd)
    except CatchableError as e:
      failCli("socket request failed: " & e.msg)
    return

  info "Triad process starting",
    pid = getCurrentProcessId(),
    runtimeDir = runtimeDir(),
    waylandDisplay = getEnv("WAYLAND_DISPLAY", "")

  pendingLiveRestorePath = defaultLiveRestorePath()
  let hadRestoreSnapshot = fileExists(pendingLiveRestorePath)
  if hadRestoreSnapshot and getEnv("TRIAD_BEHAVIOR_LOG", "").len == 0 and
      not liveRestoreStateApplied(pendingLiveRestorePath):
    putEnv("TRIAD_BEHAVIOR_LOG", "1")

  let sessionProblem = currentWaylandSessionProblem()
  if sessionProblem.len > 0:
    fatal "Refusing to start outside a Wayland session", reason = sessionProblem
    quit 1

  display = connectDisplay(nil)
  if display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  registry = display.getRegistry()
  discard registry.addListener(registry_listener.addr, daemonData(daemon))

  let roundtripResult = display.roundtrip()
  debug "Wayland registry roundtrip finished", result = roundtripResult

  if river_manager == nil:
    fatal "river_window_manager_v1 not advertised; Triad must run inside River 0.4+"
    quit 1

  let managerRoundtripResult = display.roundtrip()
  debug "River manager roundtrip finished",
    result = managerRoundtripResult,
    outputs = outputPointers.len,
    pendingWindows = pendingWindows.len,
    seats = seatPointers.len
  if managerRoundtripResult == -1:
    fatal "Failed during River manager initialization roundtrip"
    quit 1

  # Setup and Load Config
  setupConfig()
  let initialConfig = loadConfig(configPath)
  runtimeState = initRuntimeStateFromConfig(initialConfig)
  info "Initial config loaded", path = configPath

  pendingLiveRestore = loadLiveRestoreState(pendingLiveRestorePath)
  if pendingLiveRestore.isSome:
    let state = pendingLiveRestore.get()
    info "Live restore snapshot loaded",
      path = pendingLiveRestorePath,
      activeTag = state.activeTag,
      windows = state.tagByWindow.len
    writeLiveRestoreBehaviorEvent(
      "live_restore_loaded",
      pendingLiveRestorePath,
      "startup",
      state)
  elif hadRestoreSnapshot and liveRestoreStateApplied(pendingLiveRestorePath):
    info "Applied live restore snapshot retained",
      path = pendingLiveRestorePath
  elif hadRestoreSnapshot:
    if quarantineLiveRestoreState(pendingLiveRestorePath):
      warn "Invalid live restore snapshot quarantined",
          path = pendingLiveRestorePath
    else:
      warn "Invalid live restore snapshot could not be quarantined",
          path = pendingLiveRestorePath

  if pendingLiveRestore.isSome and not hasInitialRiverState():
    info "Live restore handoff waiting for initial River state",
      path = pendingLiveRestorePath
    if not waitForInitialRiverState(250):
      warn "Live restore handoff has no initial River state; retrying startup",
        path = pendingLiveRestorePath
      quit 0

  info "Triad connected to River", outputs = outputPointers.len,
      seats = seatPointers.len

  applyPendingLiveRestore("startup")

  # Setup Watcher
  watcher = initWatcher()
  proc onConfigChange(events: seq[PathEvent]) {.gcsafe.} =
    {.cast(gcsafe).}:
      configReloadDebouncer.schedule(int64(epochTime() * 1000.0))

  watcher.register(configPath, onConfigChange)

  # Start IPC Server
  proc queueMsg(msg: Msg) {.gcsafe.} =
    {.cast(gcsafe).}:
      msgQueue.add(msg)

  proc snapshotModel(): ShellSnapshot {.gcsafe.} =
    {.cast(gcsafe).}:
      readModelSnapshot()

  proc snapshotLiveRestoreJson(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      readLiveRestoreJson()

  let triadSocket = triadSocketPath()
  let niriSocketPath = chooseNiriCompatSocketPath(triadSocket)
  var ipcStarted = false

  proc startIpcServers() =
    if ipcStarted:
      return
    ipcStarted = true
    info "Starting Triad IPC server", path = triadSocket
    writeBehaviorEvent("triad_ipc_server_starting", %*{
      "path": triadSocket
    })
    asyncCheck startIpcServer(
      triadSocket, queueMsg, snapshotModel, snapshotLiveRestoreJson)

    if niriSocketPath.len > 0 and niriSocketPath != triadSocket:
      info "Starting Niri-compatible IPC server", path = niriSocketPath
      writeBehaviorEvent("niri_compat_ipc_server_starting", %*{
        "path": niriSocketPath
      })
      asyncCheck startIpcServer(
        niriSocketPath, queueMsg, snapshotModel, snapshotLiveRestoreJson)

  # Start Animation Loop
  asyncCheck startAnimationLoop()

  # Spawn startup commands after River accepts the initial manage pass.
  scheduleStartupCommands(currentModel)
  quickshellState.scheduleQuickshellSpawn(currentModel)

  var running = true
  while running:
    if not dispatchPendingWayland(display):
      break

    # Poll watcher (non-blocking)
    watcher.poll(0)

    # Poll async (IPC)
    asyncdispatch.poll(16)

    if configReloadDebouncer.takeDue(int64(epochTime() * 1000.0)):
      msgQueue.add(Msg(kind: MsgKind.CmdConfigReload))

    # Process Message Queue
    processQueuedMessages(configPath, niriSocketPath)
    if shouldExit:
      running = false
      continue

    if initialManageComplete:
      startIpcServers()
      quickshellState.spawnPendingQuickshell(
        currentModel, niriSocketPath, "initial manage")

    flushManageRequest()

    if not prepareWaylandRead(display):
      break

    discard display.flush()
    if waitForWaylandEvents(display, 16):
      if display.read_events() == -1:
        running = false
    else:
      display.cancel_read()

if isMainModule:
  # Initialize listeners
  manager_listener = RiverWindowManagerV1Listener(
    unavailable: on_manager_unavailable,
    finished: on_manager_finished,
    manageStart: on_manage_start,
    renderStart: on_render_start,
    sessionLocked: on_session_locked,
    sessionUnlocked: on_session_unlocked,
    window: on_window,
    output: on_output,
    seat: on_seat
  )
  output_listener = RiverOutputV1Listener(
    removed: on_output_removed,
    output: on_output_wl_output,
    position: on_output_position,
    dimensions: on_output_dimensions
  )
  wl_output_listener = wl_core.OutputListener(
    geometry: on_wl_output_geometry,
    mode: on_wl_output_mode,
    done: on_wl_output_done,
    scale: on_wl_output_scale,
    name: on_wl_output_name,
    description: on_wl_output_description
  )

  main()
