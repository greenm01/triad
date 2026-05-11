import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as river_layer
import protocols/river_xkb_bindings/client as river_xkb
import wayland/protocols/wayland/client as wl_core
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import core/[effects, msg, niri_state, restore_state]
import systems/[daemon_view, runtime, runtime_facade]
import types/[model, shell_snapshot]
import config/[defaults, parser, reload_policy]
import daemon/[bindings_runtime, manage_requests, process_runner,
  protocol_surfaces, protocol_surface_runtime, quickshell_runner,
  render_runtime, river_windows, screenshot_runner, state]
import ipc/[quickshell_compat, socket]
import utils/[behavior_log, runtime_log, session_env, wayland_runtime]
from types/runtime_values import nil, BindingMode, KeyBindingConfig,
  PointerBindingConfig, PointerOpKind, PresentationMode,
  ProtocolSurfacesConfig, QuickshellConfig, Rect, RenderInstruction,
  TerminalConfig, WindowId
import std/[asyncdispatch, asyncnet, json, nativesockets, options, os,
  strutils, tables, times]
import fsnotify, chronicles

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


# --- Effects Execution ---

proc destroyBindings() =
  daemon.destroyBindings()

proc requestManage(reason: string) =
  daemon.requestManage(reason)

proc flushManageRequest() =
  daemon.flushManageRequest()

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
      daemon.recordDesiredPlacement(RenderInstruction(
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
  daemon.destroyXkbSeats()
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
  daemon.attachLayerOutput(id)

proc on_seat(data: pointer; mgr: ptr RiverWindowManagerV1;
    seat: ptr RiverSeatV1) =
  info "Seat discovered", seatIndex = seatPointers.len
  seatPointers.add(seat)
  discard seat.addListener(riverSeatListener.addr, daemonData(daemon))
  daemon.attachLayerSeat(seat)
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
      daemon.attachLayerOutput(outputId)
    for seat in seatPointers:
      daemon.attachLayerSeat(seat)
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
      daemon.proposeDesiredDimensions(instructions)
      daemon.applyManageState()
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
      daemon.recordDesiredPlacements(instructions)
      daemon.renderDesiredPlacements()
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
