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
import ipc/commands
import ipc/socket
import ipc/quickshell_compat
import utils/terminal
import utils/runtime_log
import utils/screenshot_capture
import utils/session_env
import utils/wayland_runtime
from types/runtime_values import nil
from types/runtime_values import BindingMode, KeyBindingConfig,
  PointerBindingConfig, PointerOpKind, PresentationMode,
  ProtocolSurfacesConfig, QuickshellConfig, Rect, RenderInstruction,
  ScreenshotConfig, TerminalConfig, WindowId
import tables, os, fsnotify, asyncdispatch, chronicles, algorithm, asyncnet,
    nativesockets, osproc, strutils, options, times, json

type
  RiverPhase {.pure.} = enum
    RiverIdle,
    RiverManage,
    RiverRender

  ProtocolSurfaceKind {.pure.} = enum
    PskShell,
    PskDecorationAbove,
    PskDecorationBelow

  OwnedProtocolSurface = object
    surface: ptr Surface
    buffer: ptr Buffer
    shellSurface: ptr RiverShellSurfaceV1
    decoration: ptr RiverDecorationV1
    node: ptr RiverNodeV1
    windowId: WindowId
    kind: ProtocolSurfaceKind
    offsetX: int32
    offsetY: int32
    syncPending: bool

# --- Global Engine State ---
var
  display: ptr Display
  registry: ptr Registry
  river_manager: ptr RiverWindowManagerV1
  river_layer_shell: ptr river_layer.RiverLayerShellV1
  river_xkb_bindings: ptr river_xkb.RiverXkbBindingsV1
  compositor: ptr Compositor
  singlePixelManager: ptr singlepixel.WpSinglePixelBufferManagerV1
  riverPhase = RiverPhase.RiverIdle
  bindingsConfigured = false
  manageRequestPending = false
  manageRequestReason = ""
  screenshotCaptureActive = false

  # Runtime State
  runtimeState: TriadRuntimeState
  msgQueue: seq[Msg] = @[]
  pendingManageEffects: seq[Effect] = @[]
  desiredPlacements: Table[WindowId, Rect]
  lastPointerOpSeat: pointer

  # Mapping from logical IDs to Wayland pointers
  windowPointers: Table[WindowId, ptr RiverWindowV1]
  windowNodes: Table[WindowId, ptr RiverNodeV1]
  outputPointers: Table[uint32, ptr RiverOutputV1]
  layerOutputPointers: Table[uint32, ptr river_layer.RiverLayerShellOutputV1]
  layerOutputOwners: Table[uint32, uint32]
  seatPointers: seq[ptr RiverSeatV1] = @[]
  layerSeatPointers: seq[ptr river_layer.RiverLayerShellSeatV1] = @[]
  xkbBindings: Table[uint32, Msg]
  xkbBindingPointers: seq[ptr river_xkb.RiverXkbBindingV1] = @[]
  xkbSeatPointers: Table[uint32, ptr river_xkb.RiverXkbBindingsSeatV1]
  xkbSeatAteUnbound: Table[uint32, uint32]
  xkbBindingPressed: Table[uint32, bool]
  xkbBindingModes: Table[uint32, BindingMode]
  xkbStopRepeatCount: Table[uint32, uint32]
  pointerBindings: Table[uint32, Msg]
  pointerBindingKinds: Table[uint32, PointerOpKind]
  pointerBindingSeats: Table[uint32, ptr RiverSeatV1]
  pointerBindingPointers: seq[ptr RiverPointerBindingV1] = @[]
  pointerBindingPressed: Table[uint32, bool]
  shellSurfacePointers: Table[uint32, ptr RiverShellSurfaceV1]
  ownedShellSurfaceId: uint32
  protocolSurfaces: Table[uint32, OwnedProtocolSurface]
  windowDecorationAbove: Table[WindowId, uint32]
  windowDecorationBelow: Table[WindowId, uint32]
  outputWlNames: Table[uint32, uint32]
  outputGlobalOwners: Table[uint32, uint32]
  outputGlobalNames: Table[uint32, string]
  wlOutputPointers: Table[uint32, ptr Output]
  seatWlNames: Table[uint32, uint32]
  pointerWindowBySeat: Table[uint32, WindowId]
  pointerPositionBySeat: Table[uint32, Rect]
  windowUnreliablePids: Table[WindowId, int32]

  # Config Watcher
  configPath: string
  watcher: Watcher
  configReloadDebouncer: ConfigReloadDebouncer
  shouldExit = false
  quickshellProcess: Process
  quickshellSpawnPending = false
  startupCommandsPending = false
  initialManageComplete = false
  pendingLiveRestorePath: string
  pendingLiveRestore: Option[LiveRestoreState]
  liveRestoreCommitPending = false

template currentModel: untyped =
  runtimeState.model

proc id(p: pointer): uint32 =
  get_id(cast[ptr Proxy](p))

proc failCli(message: string) =
  stderr.writeLine("triad: " & message)
  quit 1

proc cstringOrEmpty(value: cstring): string =
  if value == nil:
    ""
  else:
    $value

proc syncRuntimeUpdate(context: string; msg: Msg): seq[Effect] =
  runtimeState.applyRuntimeUpdate(msg)

proc readModelSnapshot(): ShellSnapshot =
  runtimeState.readRuntimeSnapshot()

proc readLiveRestoreJson(): string =
  runtimeState.readRuntimeLiveRestoreJson()

proc writeCurrentLiveRestoreState(): LiveRestoreWriteResult =
  runtimeState.writeRuntimeLiveRestoreState()

proc syncRuntimeLayoutProjection(
    context: string; msg: Msg): seq[RenderInstruction] =
  runtimeState.applyRuntimeLayoutProjection().instructions

proc applyPendingLiveRestore(context: string) =
  if pendingLiveRestore.isNone:
    return

  let state = pendingLiveRestore.get()
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

proc spawnStartupCommands(model: Model) =
  for cmd in model.startupCommands:
    if cmd.len > 0:
      try:
        let p = startProcess(cmd[0], args = cmd[1..^1], options = {poUsePath})
        info "Spawned startup command", cmd = cmd[0], pid = p.processID
      except CatchableError as e:
        warn "Failed to spawn startup command", cmd = cmd[0], error = e.msg

proc scheduleStartupCommands(model: Model) =
  startupCommandsPending = model.startupCommands.len > 0

proc spawnPendingStartupCommands(model: Model; reason: string) =
  if not startupCommandsPending:
    return
  startupCommandsPending = false
  info "Spawning startup commands", reason = reason
  spawnStartupCommands(model)

proc stopTrackedQuickshell(reason: string) =
  if quickshellProcess == nil:
    return

  let pid = quickshellProcess.processID
  try:
    quickshellProcess.terminate()
    let code = quickshellProcess.waitForExit(1000)
    if code == -1:
      quickshellProcess.kill()
      discard quickshellProcess.waitForExit(1000)
    info "Stopped Quickshell", pid = pid, reason = reason
  except CatchableError as e:
    warn "Failed to stop Quickshell", pid = pid, reason = reason, error = e.msg

  try:
    quickshellProcess.close()
  except CatchableError:
    discard
  quickshellProcess = nil

proc releaseTrackedQuickshell(reason: string) =
  if quickshellProcess == nil:
    return

  let pid = quickshellProcess.processID
  try:
    quickshellProcess.close()
    info "Released Quickshell for manager handoff", pid = pid,
        reason = reason
  except CatchableError as e:
    warn "Failed to release Quickshell for manager handoff", pid = pid,
        reason = reason, error = e.msg
  quickshellProcess = nil

proc stopConfiguredQuickshell(model: Model; reason: string) =
  let args = quickshellKillArgs(model.quickshell)
  if args.len == 0 or model.quickshell.command.strip().len == 0:
    return

  try:
    let p = startProcess(model.quickshell.command, args = args, options = {poUsePath})
    let code = p.waitForExit(1000)
    if code == -1:
      p.kill()
      discard p.waitForExit(1000)
      warn "Timed out stopping configured Quickshell instance",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason
    elif code == 0:
      info "Stopped configured Quickshell instance",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason
    else:
      debug "Configured Quickshell instance was not running",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        reason = reason,
        exitCode = code
    p.close()
  except CatchableError as e:
    warn "Failed to stop configured Quickshell instance",
      command = model.quickshell.command,
      theme = model.quickshell.theme,
      reason = reason,
      error = e.msg

proc stopQuickshell(model: Model; reason: string; authoritative = false) =
  stopTrackedQuickshell(reason)
  if authoritative:
    stopConfiguredQuickshell(model, reason)

proc spawnQuickshell(model: Model; niriSocketPath: string) =
  if model.quickshell.enabled and model.quickshell.theme != "":
    let args = quickshellLaunchArgs(model.quickshell)

    try:
      let compat = prepareQuickshellCompatEnv(niriSocketPath)
      if compat.warning.len > 0:
        warn "Quickshell compatibility environment is incomplete",
            warning = compat.warning
      let p = startProcess(model.quickshell.command, args = args,
          env = compat.env, options = {poUsePath})
      quickshellProcess = p
      info "Spawned Quickshell",
        command = model.quickshell.command,
        theme = model.quickshell.theme,
        pid = p.processID,
        niriSocket = compat.niriSocketPath,
        shimReady = compat.shimReady,
        overlayReady = compat.overlayReady,
        xdgShare = compat.xdgSharePath
    except CatchableError as e:
      warn "Failed to spawn Quickshell", command = model.quickshell.command,
          theme = model.quickshell.theme, error = e.msg

proc restartQuickshell(model: Model; niriSocketPath, reason: string) =
  stopQuickshell(model, reason, authoritative = true)
  spawnQuickshell(model, niriSocketPath)

proc requestManage(reason: string)
proc destroyBindings()

proc sameQuickshellConfig(a, b: QuickshellConfig): bool =
  a.enabled == b.enabled and
    a.command == b.command and
    a.theme == b.theme and
    a.args == b.args

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
  quickshellSpawnPending = false

  if not sameQuickshellConfig(previousModel.quickshell,
      currentModel.quickshell):
    stopQuickshell(previousModel, "config reload", authoritative = true)
    if currentModel.quickshell.enabled:
      spawnQuickshell(currentModel, niriSocketPath)

  destroyBindings()
  info "Config reloaded", path = configPath
  requestManage("config reload")
  broadcastNiriSnapshot(readModelSnapshot())
  true

proc scheduleQuickshellSpawn(model: Model) =
  quickshellSpawnPending = model.quickshell.enabled and
      model.quickshell.theme.strip().len > 0

proc spawnPendingQuickshell(
    model: Model; niriSocketPath, reason: string) =
  if not quickshellSpawnPending:
    return
  quickshellSpawnPending = false
  restartQuickshell(model, niriSocketPath, reason)

proc spawnScreenLock(command: seq[string]) =
  if command.len == 0:
    warn "Screen lock command is not configured"
    return

  var args: seq[string] = @[]
  if command.len > 1:
    args = command[1..^1]

  try:
    let p = startProcess(command[0], args = args, options = {poUsePath})
    info "Spawned screen lock", cmd = command[0], pid = p.processID
  except CatchableError as e:
    warn "Failed to spawn screen lock", cmd = command[0], error = e.msg

proc spawnWindowMenu(command: seq[string]; windowId: WindowId; x, y: int32) =
  if command.len == 0:
    warn "Window menu command is not configured"
    return

  var args: seq[string] = @[]
  if command.len > 1:
    args = command[1..^1]

  try:
    let p = startProcess(command[0], args = args, options = {poUsePath})
    info "Spawned window menu", cmd = command[0], pid = p.processID,
        windowId = windowId, x = x, y = y
  except CatchableError as e:
    warn "Failed to spawn window menu", cmd = command[0], windowId = windowId, error = e.msg

proc spawnTerminal(model: Model) =
  for command in terminalCandidates(model.terminal.command):
    if command.len == 0 or not commandExists(command[0]):
      continue
    var args: seq[string] = @[]
    if command.len > 1:
      args = command[1..^1]
    try:
      let p = startProcess(command[0], args = args, options = {poUsePath})
      info "Spawned terminal", terminal = command[0], pid = p.processID
      return
    except CatchableError as e:
      trace "Terminal candidate failed", terminal = command[0], error = e.msg

  warn "No terminal command could be spawned"

proc spawnCommand(command: seq[string]) =
  if command.len == 0:
    warn "Spawn command is empty"
    return

  var args: seq[string] = @[]
  if command.len > 1:
    args = command[1..^1]

  try:
    let p = startProcess(command[0], args = args, options = {poUsePath})
    info "Spawned command", cmd = command[0], pid = p.processID
  except CatchableError as e:
    warn "Failed to spawn command", cmd = command[0], error = e.msg

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

proc premulColor(value: uint32): tuple[r, g, b, a: uint32] =
  let r8 = (value shr 24) and 0xff
  let g8 = (value shr 16) and 0xff
  let b8 = (value shr 8) and 0xff
  let a8 = value and 0xff
  let max32 = uint64(high(uint32))
  let a32 = uint32((uint64(a8) * max32) div 255)
  result.r = uint32((uint64(r8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.g = uint32((uint64(g8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.b = uint32((uint64(b8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.a = a32

proc createProtocolBuffer(kind: ProtocolSurfaceKind): ptr Buffer =
  if singlePixelManager == nil:
    return nil
  let alpha = if currentModel.protocolSurfaces.visibleDebug: 0x80000000'u32 else: 0'u32
  let color = case kind
    of ProtocolSurfaceKind.PskShell: 0x3aa5ff00'u32 or alpha
    of ProtocolSurfaceKind.PskDecorationAbove: 0xffcc0000'u32 or alpha
    of ProtocolSurfaceKind.PskDecorationBelow: 0x2233cc00'u32 or alpha
  let rgba = premulColor(color)
  singlePixelManager.createU32RgbaBuffer(rgba.r, rgba.g, rgba.b, rgba.a)

proc createProtocolWlSurface(kind: ProtocolSurfaceKind): OwnedProtocolSurface =
  result.kind = kind
  if compositor == nil:
    return
  result.surface = compositor.createSurface()
  if result.surface == nil:
    return
  result.buffer = createProtocolBuffer(kind)

proc commitProtocolSurface(surf: var OwnedProtocolSurface) =
  if surf.surface == nil:
    return
  if surf.shellSurface != nil:
    surf.shellSurface.syncNextCommit()
  if surf.decoration != nil:
    surf.decoration.syncNextCommit()
  if compositor != nil:
    let input = compositor.createRegion()
    if input != nil:
      surf.surface.setInputRegion(input)
      input.destroy()
  if surf.buffer != nil:
    surf.surface.attach(surf.buffer, 0, 0)
    surf.surface.damage(0, 0, 1, 1)
  surf.surface.commit()
  surf.syncPending = false

proc destroyProtocolSurface(surf: var OwnedProtocolSurface) =
  if surf.node != nil:
    surf.node.destroy()
    surf.node = nil
  if surf.decoration != nil:
    surf.decoration.destroy()
    surf.decoration = nil
  if surf.shellSurface != nil:
    shellSurfacePointers.del(surf.shellSurface.id())
    surf.shellSurface.destroy()
    surf.shellSurface = nil
  if surf.surface != nil:
    surf.surface.attach(nil, 0, 0)
    surf.surface.commit()
    surf.surface.destroy()
    surf.surface = nil
  if surf.buffer != nil:
    surf.buffer.destroy()
    surf.buffer = nil

proc ensureOwnedShellSurface() =
  if not currentModel.protocolSurfaces.enabled:
    return
  if ownedShellSurfaceId != 0 and protocolSurfaces.hasKey(ownedShellSurfaceId):
    return
  if river_manager == nil or compositor == nil:
    return
  var surf = createProtocolWlSurface(ProtocolSurfaceKind.PskShell)
  if surf.surface == nil:
    warn "Unable to create protocol shell wl_surface"
    return
  surf.shellSurface = river_manager.getShellSurface(surf.surface)
  if surf.shellSurface == nil:
    warn "Unable to create River shell surface"
    destroyProtocolSurface(surf)
    return
  surf.node = surf.shellSurface.getNode()
  ownedShellSurfaceId = surf.shellSurface.id()
  shellSurfacePointers[ownedShellSurfaceId] = surf.shellSurface
  commitProtocolSurface(surf)
  protocolSurfaces[ownedShellSurfaceId] = surf
  debug "Created protocol shell surface", shellSurfaceId = ownedShellSurfaceId

proc ensureDecorationSurface(windowId: WindowId;
    kind: ProtocolSurfaceKind): uint32 =
  if not currentModel.protocolSurfaces.enabled:
    return 0
  if not windowPointers.hasKey(windowId) or compositor == nil:
    return 0
  if kind == ProtocolSurfaceKind.PskDecorationAbove and
      windowDecorationAbove.hasKey(windowId):
    return windowDecorationAbove[windowId]
  if kind == ProtocolSurfaceKind.PskDecorationBelow and
      windowDecorationBelow.hasKey(windowId):
    return windowDecorationBelow[windowId]

  var surf = createProtocolWlSurface(kind)
  if surf.surface == nil:
    return 0
  surf.windowId = windowId
  case kind
  of ProtocolSurfaceKind.PskDecorationAbove:
    surf.decoration = windowPointers[windowId].getDecorationAbove(surf.surface)
  of ProtocolSurfaceKind.PskDecorationBelow:
    surf.decoration = windowPointers[windowId].getDecorationBelow(surf.surface)
  else:
    discard
  if surf.decoration == nil:
    destroyProtocolSurface(surf)
    return 0
  surf.decoration.setOffset(0, 0)
  commitProtocolSurface(surf)
  let id = surf.decoration.id()
  protocolSurfaces[id] = surf
  if kind == ProtocolSurfaceKind.PskDecorationAbove:
    windowDecorationAbove[windowId] = id
  elif kind == ProtocolSurfaceKind.PskDecorationBelow:
    windowDecorationBelow[windowId] = id
  let kindText = $kind
  debug "Created protocol decoration surface", windowId = windowId,
      decorationId = id, kind = kindText
  id

proc destroyWindowProtocolSurfaces(windowId: WindowId) =
  if windowDecorationAbove.hasKey(windowId):
    let id = windowDecorationAbove[windowId]
    windowDecorationAbove.del(windowId)
    if protocolSurfaces.hasKey(id):
      var surf = protocolSurfaces[id]
      protocolSurfaces.del(id)
      destroyProtocolSurface(surf)
  if windowDecorationBelow.hasKey(windowId):
    let id = windowDecorationBelow[windowId]
    windowDecorationBelow.del(windowId)
    if protocolSurfaces.hasKey(id):
      var surf = protocolSurfaces[id]
      protocolSurfaces.del(id)
      destroyProtocolSurface(surf)

proc destroyAllProtocolSurfaces() =
  var ids: seq[uint32] = @[]
  for id in protocolSurfaces.keys:
    ids.add(id)
  for id in ids:
    var surf = protocolSurfaces[id]
    protocolSurfaces.del(id)
    destroyProtocolSurface(surf)
  ownedShellSurfaceId = 0
  windowDecorationAbove.clear()
  windowDecorationBelow.clear()

proc applyBorder(win: ptr RiverWindowV1; focused: bool; edges: uint32) =
  let color = premulColor(if focused: currentModel.focusedBorderColor else: currentModel.unfocusedBorderColor)
  win.setBorders(edges, currentModel.borderWidth, color.r, color.g, color.b, color.a)

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

proc outputIdForPointer(output: ptr RiverOutputV1): uint32 =
  if output == nil:
    return 0
  let id = output.id()
  if outputPointers.hasKey(id):
    id
  else:
    0

proc attachLayerOutput(outputId: uint32) =
  if river_layer_shell == nil or not outputPointers.hasKey(outputId) or
      layerOutputPointers.hasKey(outputId):
    return
  let layerOutput = river_layer_shell.getOutput(outputPointers[outputId])
  layerOutputPointers[outputId] = layerOutput
  layerOutputOwners[layerOutput.id()] = outputId
  discard layerOutput.addListener(layer_output_listener.addr, nil)

proc attachLayerSeat(seat: ptr RiverSeatV1) =
  if river_layer_shell == nil or seat == nil:
    return
  let layerSeat = river_layer_shell.getSeat(seat)
  layerSeatPointers.add(layerSeat)
  discard layerSeat.addListener(layer_seat_listener.addr, nil)

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
  discard xkbSeat.addListener(xkb_seat_listener.addr, nil)
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
  discard binding.addListener(xkb_binding_listener.addr, nil)
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
  discard binding.addListener(pointer_binding_listener.addr, nil)
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

  bindingsConfigured = true

proc applyManageState() =
  setupDefaultBindings()
  if currentModel.protocolSurfaces.enabled:
    ensureOwnedShellSurface()
  else:
    destroyAllProtocolSurfaces()

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
      discard ensureDecorationSurface(id,
          ProtocolSurfaceKind.PskDecorationBelow)
      discard ensureDecorationSurface(id,
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
  queueWindowFocus(target)
  if currentModel.overviewActive and target != 0:
    msgQueue.add(Msg(kind: MsgKind.CmdSelectWindow))

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
    msgQueue.add(xkbBindings[id])

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
  let target = pointerWindowBySeat.getOrDefault(seat.id(), focused)
  if pointerBindingKinds.hasKey(id):
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
      else:
        msgQueue.add(msg)
    of MsgKind.CmdSelectWindow:
      if currentModel.overviewActive and target != 0:
        queueWindowFocus(target)
      msgQueue.add(msg)
    of MsgKind.CmdToggleFloating, MsgKind.CmdToggleFullscreen,
        MsgKind.CmdToggleMaximized, MsgKind.CmdMinimize,
        MsgKind.CmdMoveToScratchpad, MsgKind.CmdMoveToNamedScratchpad,
        MsgKind.CmdMoveFloating, MsgKind.CmdResizeFloating:
      queueWindowFocus(target)
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

proc proposeDesiredDimensions(instructions: seq[RenderInstruction]) =
  desiredPlacements.clear()
  for instr in instructions:
    desiredPlacements[instr.windowId] = instr.geom
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
  var ids: seq[WindowId] = @[]
  for id in desiredPlacements.keys:
    ids.add(id)
  ids.sort()

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

  for id in ids:
    if windowNodes.hasKey(id):
      let visibleScratchpad = currentModel.visibleScratchpadRiverId()
      let isScratchpad = currentModel.isScratchpadVisible and
        visibleScratchpad == id
      let winOpt = currentModel.windowDataForRiverId(id)
      let isFloating = winOpt.isSome and winOpt.get().isFloating
      let isFullscreen = winOpt.isSome and winOpt.get().isFullscreen
      if isFloating or isScratchpad or isFullscreen or id == highlighted:
        windowNodes[id].placeTop()

  if ownedShellSurfaceId != 0 and protocolSurfaces.hasKey(ownedShellSurfaceId):
    var shell = protocolSurfaces[ownedShellSurfaceId]
    if shell.node != nil:
      shell.node.setPosition(screen.x, screen.y)
      shell.node.placeBottom()
      if firstNode != nil:
        shell.node.placeBelow(firstNode)
    protocolSurfaces[ownedShellSurfaceId] = shell

proc focusedWindowGeometry(): Rect =
  let focused = currentModel.activeFocusRiverId()
  if focused != 0 and desiredPlacements.hasKey(focused):
    return desiredPlacements[focused]
  let winOpt = currentModel.windowDataForRiverId(focused)
  if focused != 0 and winOpt.isSome:
    let win = winOpt.get()
    if win.isFloating and win.floatingGeom.w > 0 and win.floatingGeom.h > 0:
      return win.floatingGeom
  currentModel.primaryScreen()

proc runScreenshotCapture(kind: ScreenshotKind; requestedPath: string;
    pointerMode: ScreenshotPointerMode; writeToDisk,
    copyToClipboard: bool) {.async.} =
  if screenshotCaptureActive:
    warn "Screenshot capture skipped; capture already running"
    return

  screenshotCaptureActive = true
  var path = ""
  try:
    let screenshotConfig = currentModel.screenshot
    path =
      if writeToDisk:
        screenshotPathOrDefault(requestedPath, screenshotConfig)
      else:
        screenshotTempPath(screenshotConfig)
    let dir = path.splitFile().dir
    if dir.len > 0:
      try:
        createDir(dir)
      except CatchableError as e:
        warn "Failed to create screenshot directory", path = dir, error = e.msg
        return

    let command = screenshotCaptureCommand(kind, path, screenshotConfig,
        currentModel.primaryScreen(), focusedWindowGeometry(), pointerMode)
    info "Screenshot capture started", path = path, screenshotKind = $kind

    let code = await runShellCommandAsync(command)
    if code != 0:
      warn "Screenshot capture failed", path = path, exitCode = code
      return

    var clipboardOk = true
    if copyToClipboard:
      let copyCode = await runShellCommandAsync(
        screenshotClipboardCommand(path, screenshotConfig))
      if copyCode != 0:
        warn "Screenshot clipboard copy failed", path = path,
          exitCode = copyCode
        clipboardOk = false
    if not writeToDisk and not clipboardOk:
      return

    info "Screenshot captured", path = path
    let event =
      if writeToDisk:
        %*{"ScreenshotCaptured": {"path": path}}
      else:
        %*{"ScreenshotCaptured": {}}
    asyncCheck broadcastJson($event)
  except CatchableError as e:
    warn "Screenshot capture failed", path = path, error = e.msg
  finally:
    screenshotCaptureActive = false
    if path.len > 0 and not writeToDisk and fileExists(path):
      try:
        removeFile(path)
      except CatchableError:
        discard

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
    quickshellSpawnPending = false
    releaseTrackedQuickshell("manager stop")
    if river_manager != nil:
      river_manager.stop()
  of EffectKind.EffTriadReload:
    let restore = writeCurrentLiveRestoreState()
    if not restore.ok:
      warn "Triad reload rejected; live restore snapshot could not be written",
        path = restore.path,
        error = restore.error
      return
    quickshellSpawnPending = false
    releaseTrackedQuickshell("triad reload")
    if river_manager != nil:
      river_manager.stop()
  of EffectKind.EffExitSession:
    if river_manager != nil and currentModel.allowExitSession:
      river_manager.exitSession()
  of EffectKind.EffFocusShellUi:
    ensureOwnedShellSurface()
    if ownedShellSurfaceId != 0:
      queueManageEffect(Effect(kind: EffectKind.EffFocusShellSurface,
          focusShellSurfaceId: ownedShellSurfaceId))
  of EffectKind.EffScreenshot:
    asyncCheck runScreenshotCapture(eff.screenshotKind, eff.screenshotPath,
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
      desiredPlacements[eff.windowId] = Rect(x: eff.x, y: eff.y, w: eff.w, h: eff.h)
      queueManageEffect(eff)
  else:
    discard

# Mapping from logical IDs to window metadata for late creation
var pendingWindows: Table[WindowId, runtime_values.WindowData]

# --- RiverWindowV1 Callbacks ---

proc forgetWindow(id: WindowId) =
  destroyWindowProtocolSurfaces(id)
  desiredPlacements.del(id)
  pendingWindows.del(id)
  windowUnreliablePids.del(id)
  if windowNodes.hasKey(id):
    let node = windowNodes[id]
    windowNodes.del(id)
    node.destroy()
  if windowPointers.hasKey(id):
    let win = windowPointers[id]
    windowPointers.del(id)
    win.destroy()

proc on_window_app_id(data: pointer; win: ptr RiverWindowV1; appId: cstring) =
  let id = win.id()
  let appIdText = cstringOrEmpty(appId)
  debug "Window app-id received", windowId = id, appId = appIdText
  if pendingWindows.hasKey(id):
    pendingWindows[id].appId = appIdText
  elif currentModel.hasRiverWindow(id):
    msgQueue.add(Msg(kind: MsgKind.WlWindowAppId, appIdWindowId: id,
        updatedAppId: appIdText))

proc on_window_title(data: pointer; win: ptr RiverWindowV1; title: cstring) =
  let id = win.id()
  let titleText = cstringOrEmpty(title)
  debug "Window title received", windowId = id, title = titleText
  if pendingWindows.hasKey(id):
    pendingWindows[id].title = titleText
  elif currentModel.hasRiverWindow(id):
    msgQueue.add(Msg(kind: MsgKind.WlWindowTitle, titleWindowId: id,
        updatedTitle: titleText))

proc on_window_closed(data: pointer; win: ptr RiverWindowV1) =
  let id = win.id()
  info "Window closed", windowId = id
  msgQueue.add(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: id))
  forgetWindow(id)

proc on_window_dimensions_hint(
    data: pointer;
    win: ptr RiverWindowV1;
    minWidth: int32;
    minHeight: int32;
    maxWidth: int32;
    maxHeight: int32) =
  trace "Window dimensions hint received",
    windowId = win.id(),
    minWidth = minWidth,
    minHeight = minHeight,
    maxWidth = maxWidth,
    maxHeight = maxHeight
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].minWidth = max(0'i32, minWidth)
    pendingWindows[win.id()].minHeight = max(0'i32, minHeight)
    pendingWindows[win.id()].maxWidth = max(0'i32, maxWidth)
    pendingWindows[win.id()].maxHeight = max(0'i32, maxHeight)
  elif currentModel.hasRiverWindow(win.id()):
    msgQueue.add(Msg(
      kind: MsgKind.WlWindowDimensionsHint,
      hintWindowId: win.id(),
      minWidth: minWidth,
      minHeight: minHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight))

proc on_window_dimensions(data: pointer; win: ptr RiverWindowV1; width: int32;
    height: int32) =
  trace "Window dimensions acknowledged", windowId = win.id(),
      width = width, height = height
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].actualW = max(0'i32, width)
    pendingWindows[win.id()].actualH = max(0'i32, height)
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: win.id(), actualWidth: width,
        actualHeight: height))

proc on_window_parent(data: pointer; win: ptr RiverWindowV1;
    parent: ptr RiverWindowV1) =
  let parentId = if parent == nil: 0'u32 else: parent.id()
  trace "Window parent received", windowId = win.id(), parentId = parentId
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].parentId = parentId
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowParent, childWindowId: win.id(),
        parentWindowId: parentId))

proc on_window_decoration_hint(data: pointer; win: ptr RiverWindowV1;
    hint: uint32) =
  trace "Window decoration hint received", windowId = win.id(), hint = hint
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].hasDecorationHint = true
    pendingWindows[win.id()].decorationHint = hint
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowDecorationHint,
        decorationWindowId: win.id(), decorationHint: hint))

proc on_window_pointer_move_requested(data: pointer; win: ptr RiverWindowV1;
    seat: ptr RiverSeatV1) =
  debug "Pointer move requested", windowId = win.id()
  msgQueue.add(Msg(kind: MsgKind.WlPointerMoveRequested, moveWinId: win.id(),
      moveSeat: seat))

proc on_window_pointer_resize_requested(data: pointer; win: ptr RiverWindowV1;
    seat: ptr RiverSeatV1; edges: uint32) =
  debug "Pointer resize requested", windowId = win.id(), edges = edges
  msgQueue.add(Msg(kind: MsgKind.WlPointerResizeRequested,
      resizeWinId: win.id(), resizeSeat: seat, resizeEdges: edges))

proc on_window_show_menu_requested(data: pointer; win: ptr RiverWindowV1;
    x: int32; y: int32) =
  debug "Window menu requested", windowId = win.id(), x = x, y = y
  msgQueue.add(Msg(kind: MsgKind.WlWindowMenuRequested,
      menuWindowId: win.id(), menuX: x, menuY: y))

proc on_window_maximize_requested(data: pointer; win: ptr RiverWindowV1) =
  debug "Window maximize requested", windowId = win.id()
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].isMaximized = true
    pendingWindows[win.id()].isMinimized = false
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowMaximizeRequested,
        maximizeRequestId: win.id()))

proc on_window_unmaximize_requested(data: pointer; win: ptr RiverWindowV1) =
  debug "Window unmaximize requested", windowId = win.id()
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].isMaximized = false
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowUnmaximizeRequested,
        unmaximizeRequestId: win.id()))

proc on_window_fullscreen_requested(data: pointer; win: ptr RiverWindowV1;
    output: ptr RiverOutputV1) =
  let requestedOutput = outputIdForPointer(output)
  debug "Window fullscreen requested", windowId = win.id(),
      outputId = requestedOutput
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].isFullscreen = true
    pendingWindows[win.id()].fullscreenOutput = requestedOutput
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowFullscreenRequested,
        fullscreenRequestId: win.id(), fullscreenOutputId: requestedOutput))

proc on_window_exit_fullscreen_requested(data: pointer;
    win: ptr RiverWindowV1) =
  debug "Window exit fullscreen requested", windowId = win.id()
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].isFullscreen = false
    pendingWindows[win.id()].fullscreenOutput = 0
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowExitFullscreenRequested,
        exitFullscreenRequestId: win.id()))

proc on_window_minimize_requested(data: pointer; win: ptr RiverWindowV1) =
  debug "Window minimize requested", windowId = win.id()
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].isMinimized = true
    pendingWindows[win.id()].isMaximized = false
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowMinimizeRequested,
        minimizeRequestId: win.id()))

proc on_window_unreliable_pid(data: pointer; win: ptr RiverWindowV1;
    unreliablePid: int32) =
  windowUnreliablePids[win.id()] = unreliablePid
  trace "Window unreliable pid received", windowId = win.id(),
      pid = unreliablePid

proc on_window_presentation_hint(data: pointer; win: ptr RiverWindowV1;
    hint: uint32) =
  trace "Window presentation hint received", windowId = win.id(), hint = hint
  if pendingWindows.hasKey(win.id()):
    pendingWindows[win.id()].hasPresentationHint = true
    pendingWindows[win.id()].presentationHint = hint
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowPresentationHint,
        presentationWindowId: win.id(), presentationHint: hint))

proc on_window_identifier(data: pointer; win: ptr RiverWindowV1;
    identifier: cstring) =
  let text = cstringOrEmpty(identifier)
  let id = win.id()
  trace "Window identifier received", windowId = id, identifier = text
  if pendingWindows.hasKey(id):
    pendingWindows[id].identifier = text
  else:
    msgQueue.add(Msg(kind: MsgKind.WlWindowIdentifier, identifierWindowId: id,
        identifier: text))

var window_listener = RiverWindowV1Listener(
  closed: on_window_closed,
  dimensionsHint: on_window_dimensions_hint,
  dimensions: on_window_dimensions,
  appId: on_window_app_id,
  title: on_window_title,
  parent: on_window_parent,
  decorationHint: on_window_decoration_hint,
  pointerMoveRequested: on_window_pointer_move_requested,
  pointerResizeRequested: on_window_pointer_resize_requested,
  showWindowMenuRequested: on_window_show_menu_requested,
  maximizeRequested: on_window_maximize_requested,
  unmaximizeRequested: on_window_unmaximize_requested,
  fullscreenRequested: on_window_fullscreen_requested,
  exitFullscreenRequested: on_window_exit_fullscreen_requested,
  minimizeRequested: on_window_minimize_requested,
  unreliablePid: on_window_unreliable_pid,
  presentationHint: on_window_presentation_hint,
  identifier: on_window_identifier
)

# --- Wayland Callbacks ---

proc cleanupRiverObjects() =
  manageRequestPending = false
  manageRequestReason = ""

  destroyAllProtocolSurfaces()

  var winIds: seq[WindowId] = @[]
  for id in windowPointers.keys:
    winIds.add(id)
  for id in winIds:
    forgetWindow(id)

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
        createdIdentifier: data.identifier))

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
  let id = win.id()
  info "Window discovered", windowId = id
  windowPointers[id] = win
  windowNodes[id] = win.getNode()
  # Start tracking as pending until we get metadata or manage starts
  pendingWindows[id] = runtime_values.WindowData(
    id: id, appId: "unknown", title: "unknown")
  discard win.addListener(window_listener.addr, nil)

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
  let globalName = uint32(cast[uint](data))
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
  discard output.addListener(output_listener.addr, nil)
  attachLayerOutput(id)

proc on_seat(data: pointer; mgr: ptr RiverWindowManagerV1;
    seat: ptr RiverSeatV1) =
  info "Seat discovered", seatIndex = seatPointers.len
  seatPointers.add(seat)
  discard seat.addListener(seat_listener.addr, nil)
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
    discard river_manager.addListener(manager_listener.addr, nil)
    info "Bound to river_window_manager_v1", name = name,
        advertisedVersion = version, boundVersion = 4
    ensureOwnedShellSurface()
  elif interfaceName == "wl_compositor":
    compositor = cast[ptr Compositor](registry.`bind`(name,
        wl_compositor_interface.addr, min(version, 6'u32)))
    info "Bound to wl_compositor", name = name, advertisedVersion = version
    ensureOwnedShellSurface()
  elif interfaceName == "wl_output":
    let wlOutput = cast[ptr Output](registry.`bind`(name,
        wl_core.wl_output_interface.addr, min(version, 4'u32)))
    wlOutputPointers[name] = wlOutput
    discard wlOutput.addListener(wl_output_listener.addr, cast[pointer](uint(name)))
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
      spawnPendingQuickshell(currentModel, niriSocketPath, "initial manage")
      continue

    if msg.kind == MsgKind.WlRenderStart:
      riverPhase = RiverPhase.RiverRender
      if desiredPlacements.len == 0:
        let instructions = syncRuntimeLayoutProjection("render layout", msg)
        for instr in instructions:
          desiredPlacements[instr.windowId] = instr.geom
      renderDesiredPlacements()
      executeEffect(Effect(kind: EffectKind.EffRenderFinish))
      riverPhase = RiverPhase.RiverIdle
      continue

    for eff in effects:
      executeEffect(eff)

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

  let sessionProblem = currentWaylandSessionProblem()
  if sessionProblem.len > 0:
    fatal "Refusing to start outside a Wayland session", reason = sessionProblem
    quit 1

  display = connectDisplay(nil)
  if display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  registry = display.getRegistry()
  discard registry.addListener(registry_listener.addr, nil)

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

  if hadRestoreSnapshot and outputPointers.len == 0 and seatPointers.len == 0:
    warn "Live restore handoff has no initial River state; retrying startup",
      path = pendingLiveRestorePath
    quit 0

  info "Triad connected to River", outputs = outputPointers.len,
      seats = seatPointers.len

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
    applyPendingLiveRestore("startup")
  elif hadRestoreSnapshot:
    if quarantineLiveRestoreState(pendingLiveRestorePath):
      warn "Invalid live restore snapshot quarantined",
          path = pendingLiveRestorePath
    else:
      warn "Invalid live restore snapshot could not be quarantined",
          path = pendingLiveRestorePath

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
    asyncCheck startIpcServer(
      triadSocket, queueMsg, snapshotModel, snapshotLiveRestoreJson)

    if niriSocketPath.len > 0 and niriSocketPath != triadSocket:
      info "Starting Niri-compatible IPC server", path = niriSocketPath
      asyncCheck startIpcServer(
        niriSocketPath, queueMsg, snapshotModel, snapshotLiveRestoreJson)

  # Start Animation Loop
  asyncCheck startAnimationLoop()

  # Spawn startup commands after River accepts the initial manage pass.
  scheduleStartupCommands(currentModel)
  scheduleQuickshellSpawn(currentModel)

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
