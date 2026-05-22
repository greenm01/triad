import std/[asyncdispatch, json, options, osproc, tables]
import chronicles
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import protocols/river_xkb_config/client as riverXkbConfig
import ../core/effects
import ../ipc/socket
import ../systems/daemon_view
from ../types/core import OutputId
import ../types/projection_values
import ../utils/behavior_log
import
  child_process_runtime, idle_inhibit_runtime, live_restore_runtime, manage_requests,
  output_management_runtime, process_runner, protocol_surface_runtime,
  quickshell_runner, render_runtime, screenshot_runner, spawn_context, state

proc setLayerShellDefaultOutputForSpawn(daemon: var TriadDaemon, outputId: OutputId) =
  var riverOutputId = 0'u32
  if uint32(outputId) != 0:
    riverOutputId = daemon.runtimeState.model.riverIdForOutput(outputId)
  if riverOutputId == 0:
    riverOutputId = daemon.runtimeState.model.activeLayerDefaultOutputRiverId()
  if riverOutputId != 0 and daemon.layerOutputPointers.hasKey(riverOutputId):
    daemon.layerOutputPointers[riverOutputId].setDefault()

proc executeManageEffect*(daemon: var TriadDaemon, eff: Effect) =
  case eff.kind
  of EffectKind.EffOpStartPointer:
    if eff.opSeat != nil:
      daemon.lastPointerOpSeat = eff.opSeat
      cast[ptr RiverSeatV1](eff.opSeat).opStartPointer()
  of EffectKind.EffOpEnd:
    if eff.endSeat != nil:
      cast[ptr RiverSeatV1](eff.endSeat).opEnd()
      if daemon.lastPointerOpSeat == eff.endSeat:
        daemon.lastPointerOpSeat = nil
  of EffectKind.EffSetPosition:
    if daemon.windowPointers.hasKey(eff.windowId):
      daemon.windowPointers[eff.windowId].proposeDimensions(
        max(0'i32, eff.w), max(0'i32, eff.h)
      )
  of EffectKind.EffFocusWindow:
    if not daemon.runtimeState.model.sessionLocked and
        not daemon.runtimeState.model.layerFocusExclusive and
        daemon.windowPointers.hasKey(eff.focusId):
      let win = daemon.windowPointers[eff.focusId]
      for seat in daemon.seatPointers:
        seat.focusWindow(win)
  of EffectKind.EffFocusShellSurface:
    if not daemon.runtimeState.model.sessionLocked and
        not daemon.runtimeState.model.layerFocusExclusive and
        daemon.shellSurfacePointers.hasKey(eff.focusShellSurfaceId):
      let shellSurface = daemon.shellSurfacePointers[eff.focusShellSurfaceId]
      for seat in daemon.seatPointers:
        seat.focusShellSurface(shellSurface)
  of EffectKind.EffCloseWindow:
    writeBehaviorEvent(
      "close_window_effect_executed",
      %*{
        "window_id": eff.closeId,
        "known_window": daemon.windowPointers.hasKey(eff.closeId),
      },
    )
    if daemon.windowPointers.hasKey(eff.closeId):
      daemon.windowPointers[eff.closeId].close()
  of EffectKind.EffInformResizeStart:
    if daemon.windowPointers.hasKey(eff.resizeLifecycleWinId):
      daemon.windowPointers[eff.resizeLifecycleWinId].informResizeStart()
  of EffectKind.EffInformResizeEnd:
    if daemon.windowPointers.hasKey(eff.resizeLifecycleWinId):
      daemon.windowPointers[eff.resizeLifecycleWinId].informResizeEnd()
  of EffectKind.EffSetFullscreen:
    if daemon.windowPointers.hasKey(eff.fsWinId):
      let nextState =
        FullscreenRequestState(active: eff.isFullscreen, outputId: eff.fsOutputId)
      if daemon.lastFullscreenRequests.hasKey(eff.fsWinId) and
          daemon.lastFullscreenRequests[eff.fsWinId] == nextState:
        return
      daemon.lastFullscreenRequests[eff.fsWinId] = nextState
      let win = daemon.windowPointers[eff.fsWinId]
      if eff.isFullscreen:
        var output: ptr RiverOutputV1 = nil
        if eff.fsOutputId != 0 and daemon.outputPointers.hasKey(eff.fsOutputId):
          output = daemon.outputPointers[eff.fsOutputId]
        else:
          let primaryOutput = daemon.runtimeState.model.primaryOutputRiverId()
          if primaryOutput != 0 and daemon.outputPointers.hasKey(primaryOutput):
            output = daemon.outputPointers[primaryOutput]
        if output == nil and daemon.outputPointers.len > 0:
          for p in daemon.outputPointers.values:
            output = p
            break
        if output != nil:
          win.fullscreen(output)
          win.informFullscreen()
      else:
        win.exitFullscreen()
        win.informNotFullscreen()
  of EffectKind.EffSetMaximized:
    if daemon.windowPointers.hasKey(eff.maxWinId):
      if daemon.lastMaximizedRequests.hasKey(eff.maxWinId) and
          daemon.lastMaximizedRequests[eff.maxWinId] == eff.isMaximized:
        return
      daemon.lastMaximizedRequests[eff.maxWinId] = eff.isMaximized
      daemon.expectMaximizedAck(eff.maxWinId, eff.isMaximized)
      if eff.isMaximized:
        daemon.windowPointers[eff.maxWinId].informMaximized()
      else:
        daemon.windowPointers[eff.maxWinId].informUnmaximized()
  of EffectKind.EffSetIdleInhibit:
    daemon.setIdleInhibit(eff.idleInhibitActive)
  of EffectKind.EffEnsureNextKeyEaten:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.ensureNextKeyEaten()
  of EffectKind.EffCancelEnsureNextKeyEaten:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.cancelEnsureNextKeyEaten()
  else:
    discard

proc queueManageEffect*(daemon: var TriadDaemon, eff: Effect) =
  if eff.kind == EffectKind.EffSetFullscreen:
    let nextState =
      FullscreenRequestState(active: eff.isFullscreen, outputId: eff.fsOutputId)
    if daemon.lastFullscreenRequests.hasKey(eff.fsWinId) and
        daemon.lastFullscreenRequests[eff.fsWinId] == nextState:
      return
  if eff.kind == EffectKind.EffSetMaximized:
    if daemon.lastMaximizedRequests.hasKey(eff.maxWinId) and
        daemon.lastMaximizedRequests[eff.maxWinId] == eff.isMaximized:
      return
  if daemon.riverPhase == RiverPhase.RiverManage:
    daemon.executeManageEffect(eff)
  else:
    daemon.pendingManageEffects.add(eff)
    daemon.requestManage($eff.kind)

proc flushPendingManageEffects*(daemon: var TriadDaemon) =
  if daemon.pendingManageEffects.len == 0:
    return
  let effects = daemon.pendingManageEffects
  daemon.pendingManageEffects = @[]
  for eff in effects:
    daemon.executeManageEffect(eff)

proc executeEffect*(daemon: var TriadDaemon, eff: Effect) =
  case eff.kind
  of EffectKind.EffLog:
    info "log", msg = eff.msg
  of EffectKind.EffManageFinish:
    if daemon.riverManager != nil and daemon.riverPhase == RiverPhase.RiverManage:
      daemon.riverManager.manageFinish()
      daemon.commitPendingLiveRestore()
  of EffectKind.EffRenderFinish:
    if daemon.riverManager != nil and daemon.riverPhase == RiverPhase.RiverRender:
      daemon.riverManager.renderFinish()
  of EffectKind.EffManageDirty:
    daemon.requestManage("effect")
  of EffectKind.EffBroadcastJson:
    asyncCheck broadcastJson(eff.jsonPayload)
  of EffectKind.EffBroadcastTriadJson:
    asyncCheck broadcastTriadJson(eff.jsonPayload, eff.triadEventName)
  of EffectKind.EffSpawnScreenLock:
    daemon.trackChildProcess(
      spawnScreenLock(daemon.runtimeState.model, eff.screenLockCommand)
    )
  of EffectKind.EffSpawnWindowMenu:
    daemon.trackChildProcess(
      spawnWindowMenu(
        daemon.runtimeState.model, eff.windowMenuCommand, eff.windowMenuId,
        eff.windowMenuX, eff.windowMenuY,
      )
    )
  of EffectKind.EffSpawn:
    daemon.setLayerShellDefaultOutputForSpawn(OutputId(eff.spawnContextOutputId))
    let process = spawnCommand(daemon.runtimeState.model, eff.spawnCommand)
    if process != nil:
      daemon.rememberSpawnPlacementForPid(
        int32(process.processID),
        eff.spawnContextOutputId,
        eff.spawnContextSlot,
        $eff.spawnContextOutputId,
        if eff.spawnCommand.len > 0:
          eff.spawnCommand[0]
        else:
          "",
      )
    daemon.trackChildProcess(process)
  of EffectKind.EffPointerWarp:
    for seat in daemon.seatPointers:
      seat.pointerWarp(eff.warpX, eff.warpY)
  of EffectKind.EffSetKeyboardLayout:
    for runtime in daemon.xkbConfigKeyboards.values:
      let keyboard = cast[ptr riverXkbConfig.RiverXkbKeyboardV1](runtime.pointer)
      if keyboard != nil:
        keyboard.setLayoutByIndex(int32(eff.keyboardLayoutIndex))
  of EffectKind.EffSetMonitorPower:
    daemon.applyMonitorPower(eff.monitorPowerEnabled, eff.monitorPowerTarget)
  of EffectKind.EffEnsureNextKeyEaten, EffectKind.EffCancelEnsureNextKeyEaten:
    daemon.queueManageEffect(eff)
  of EffectKind.EffStopManager:
    daemon.quickshellState.spawnPending = false
    daemon.quickshellState.releaseTrackedQuickshell("manager stop")
    if daemon.riverManager != nil:
      daemon.riverManager.stop()
  of EffectKind.EffTriadReload:
    let restore = daemon.writeCurrentLiveRestoreState()
    if not restore.ok:
      warn "Triad reload rejected; live restore snapshot could not be written",
        path = restore.path, error = restore.error
      return
    if devModeEnabled() and not markLiveReloadDevMode():
      warn "Triad reload could not preserve dev mode"
    daemon.quickshellState.spawnPending = false
    daemon.quickshellState.releaseTrackedQuickshell("triad reload")
    if daemon.riverManager != nil:
      daemon.riverManager.stop()
  of EffectKind.EffExitSession:
    if daemon.riverManager != nil and daemon.runtimeState.model.allowExitSession:
      daemon.riverManager.exitSession()
  of EffectKind.EffFocusShellUi:
    if daemon.runtimeState.model.overviewActive:
      daemon.requestManage("focus overview shell ui")
    else:
      daemon.ensureOwnedShellSurface()
    let surfaceId =
      if daemon.runtimeState.model.overviewActive:
        daemon.overviewFocusShellSurfaceId()
      else:
        daemon.protocolSurfaceRuntime.ownedShellSurfaceId
    if surfaceId != 0:
      daemon.queueManageEffect(
        Effect(kind: EffectKind.EffFocusShellSurface, focusShellSurfaceId: surfaceId)
      )
  of EffectKind.EffScreenshot:
    asyncCheck runScreenshotCapture(
      addr daemon,
      eff.screenshotKind,
      eff.screenshotPath,
      eff.screenshotPointerMode,
      eff.screenshotWriteToDisk,
      eff.screenshotCopyToClipboard,
    )
  of EffectKind.EffOpStartPointer, EffectKind.EffOpEnd, EffectKind.EffFocusWindow,
      EffectKind.EffFocusShellSurface, EffectKind.EffCloseWindow,
      EffectKind.EffSetFullscreen, EffectKind.EffSetMaximized,
      EffectKind.EffInformResizeStart, EffectKind.EffInformResizeEnd:
    daemon.queueManageEffect(eff)
  of EffectKind.EffSetIdleInhibit:
    daemon.setIdleInhibit(eff.idleInhibitActive)
  of EffectKind.EffSetPosition:
    if daemon.riverPhase == RiverPhase.RiverRender and
        daemon.windowNodes.hasKey(eff.windowId):
      let node = daemon.windowNodes[eff.windowId]
      node.setPosition(eff.x, eff.y)

      let winOpt = daemon.runtimeState.model.windowDataForRiverId(eff.windowId)
      if winOpt.isSome and winOpt.get().isFloating:
        node.placeTop()
    else:
      daemon.recordDesiredPlacement(
        RenderInstruction(
          windowId: eff.windowId, geom: Rect(x: eff.x, y: eff.y, w: eff.w, h: eff.h)
        )
      )
      daemon.queueManageEffect(eff)
  else:
    discard
