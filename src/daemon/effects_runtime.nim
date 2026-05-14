import std/[asyncdispatch, options, tables]
import chronicles
import protocols/river/client as river
import protocols/river_xkb_bindings/client as riverXkb
import ../core/effects
import ../ipc/socket
import ../systems/daemon_view
import ../types/runtime_values
import
  idle_inhibit_runtime, live_restore_runtime, manage_requests, process_runner,
  protocol_surface_runtime, quickshell_runner, render_runtime, screenshot_runner, state

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
      daemon.expectMaximizedAck(eff.maxWinId, eff.isMaximized)
      if eff.isMaximized:
        daemon.windowPointers[eff.maxWinId].informMaximized()
      else:
        daemon.windowPointers[eff.maxWinId].informUnmaximized()
  of EffectKind.EffSetIdleInhibit:
    daemon.setIdleInhibit(eff.idleInhibitActive)
  else:
    discard

proc queueManageEffect*(daemon: var TriadDaemon, eff: Effect) =
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
    spawnScreenLock(daemon.runtimeState.model, eff.screenLockCommand)
  of EffectKind.EffSpawnWindowMenu:
    spawnWindowMenu(
      daemon.runtimeState.model, eff.windowMenuCommand, eff.windowMenuId,
      eff.windowMenuX, eff.windowMenuY,
    )
  of EffectKind.EffSpawn:
    spawnCommand(daemon.runtimeState.model, eff.spawnCommand)
  of EffectKind.EffPointerWarp:
    for seat in daemon.seatPointers:
      seat.pointerWarp(eff.warpX, eff.warpY)
  of EffectKind.EffEnsureNextKeyEaten:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.ensureNextKeyEaten()
  of EffectKind.EffCancelEnsureNextKeyEaten:
    for xkbSeat in daemon.xkbSeatPointers.values:
      xkbSeat.cancelEnsureNextKeyEaten()
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
    daemon.quickshellState.spawnPending = false
    daemon.quickshellState.releaseTrackedQuickshell("triad reload")
    if daemon.riverManager != nil:
      daemon.riverManager.stop()
  of EffectKind.EffExitSession:
    if daemon.riverManager != nil and daemon.runtimeState.model.allowExitSession:
      daemon.riverManager.exitSession()
  of EffectKind.EffFocusShellUi:
    daemon.ensureOwnedShellSurface()
    let surfaceId = daemon.protocolSurfaceRuntime.ownedShellSurfaceId
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
