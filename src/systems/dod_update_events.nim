import options
import ../core/effects
import ../core/msg
import ../state/engine
import dod_focus
import dod_outputs
import dod_runtime
import dod_update_effects
import dod_window_lifecycle
import dod_window_state

proc setExternalFocus(model: var DodModel;
    externalId: ExternalWindowId): bool =
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  if externalId == NullExternalWindowId:
    return model.setTagFocus(tagId, NullWindowId)
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or
      model.placementForWindowOnTag(tagId, winId).isNone:
    return false
  discard model.setTagFocus(tagId, winId)
  model.recordWorkspace(tagId)
  model.recordFocus(winId)
  true

proc applyDodEvent*(model: var DodModel; msg: Msg): DodUpdateStep =
  case msg.kind
  of WlManageStart:
    let focused = model.focusedWindow()
    if focused != NullWindowId:
      model.recordWorkspace(model.activeTag)
      model.recordFocus(focused)
      let externalId = model.legacyWindowId(focused)
      result.effects.add(broadcastWindowFocusChanged(externalId))
      if not model.sessionLocked and not model.layerFocusExclusive:
        result.effects.add(Effect(kind: EffFocusWindow, focusId: externalId))
    result.dirty = true

  of WlOutputDimensions:
    result.dirty = model.setOutputDimensionsForExternal(
      msg.outputId.externalOutputId(), msg.width, msg.height)
  of WlOutputName:
    result.dirty = model.setOutputNameForExternal(
      msg.nameOutputId.externalOutputId(), msg.outputName)
  of WlOutputPosition:
    result.dirty = model.setOutputPositionForExternal(
      msg.positionOutputId.externalOutputId(), msg.outputX, msg.outputY)
  of WlOutputUsable:
    result.dirty = model.setOutputUsableForExternal(
      msg.usableOutputId.externalOutputId(),
      msg.usableX,
      msg.usableY,
      msg.usableW,
      msg.usableH)
  of WlOutputRemoved:
    for winId in model.removeOutputForExternal(
        msg.removedOutputId.externalOutputId()):
      result.dirty = true
      result.effects.addSetFullscreenEffect(model.legacyWindowId(winId), false)

  of WlWindowCreated:
    let winId = model.createWindowForExternal(
      msg.windowId.externalWindowId(),
      msg.appId,
      msg.title,
      msg.createdIdentifier)
    result.dirty = winId != NullWindowId
    if result.dirty:
      let win = model.windowData(winId).get()
      if win.isFullscreen:
        result.effects.addSetFullscreenEffect(
          msg.windowId, true, uint32(win.fullscreenOutput))
      if win.isMaximized:
        result.effects.addSetMaximizedEffect(msg.windowId, true)

  of WlWindowDestroyed:
    result.dirty = model.destroyWindowForExternal(
      msg.destroyedId.externalWindowId())
    if result.dirty:
      result.effects.add(broadcastWindowClosed(msg.destroyedId))

  of WlWindowDimensions:
    result.dirty = model.updateWindowDimensionsForExternal(
      msg.dimensionsWindowId.externalWindowId(),
      msg.actualWidth,
      msg.actualHeight)
  of WlWindowDecorationHint:
    result.dirty = model.updateWindowDecorationHintForExternal(
      msg.decorationWindowId.externalWindowId(), msg.decorationHint)
  of WlWindowPresentationHint:
    result.dirty = model.updateWindowPresentationHintForExternal(
      msg.presentationWindowId.externalWindowId(), msg.presentationHint)
  of WlWindowParent:
    result.dirty = model.updateWindowParentForExternal(
      msg.childWindowId.externalWindowId(),
      msg.parentWindowId.externalWindowId())
  of WlWindowIdentifier:
    result.dirty = model.updateWindowIdentifierAndRestoreForExternal(
      msg.identifierWindowId.externalWindowId(), msg.identifier)
  of WlWindowAppId:
    result.dirty = model.updateWindowAppIdForExternal(
      msg.appIdWindowId.externalWindowId(), msg.updatedAppId)
  of WlWindowTitle:
    result.dirty = model.updateWindowTitleForExternal(
      msg.titleWindowId.externalWindowId(), msg.updatedTitle)
  of WlWindowDimensionsHint:
    result.dirty = model.updateWindowDimensionsHintForExternal(
      msg.hintWindowId.externalWindowId(),
      msg.minWidth,
      msg.minHeight,
      msg.maxWidth,
      msg.maxHeight)

  of WlWindowMenuRequested:
    if model.windowMenuCommand.len > 0 and
        model.windowForExternal(msg.menuWindowId.externalWindowId()) !=
        NullWindowId:
      result.effects.add(Effect(
        kind: EffSpawnWindowMenu,
        windowMenuCommand: model.windowMenuCommand,
        windowMenuId: msg.menuWindowId,
        windowMenuX: msg.menuX,
        windowMenuY: msg.menuY))
  of WlShellSurfaceInteraction:
    if msg.shellSurfaceId != 0 and not model.sessionLocked and
        not model.layerFocusExclusive:
      result.effects.add(Effect(
        kind: EffFocusShellSurface,
        focusShellSurfaceId: msg.shellSurfaceId))
  of WlModifiersChanged:
    discard model.setActiveModifiers(msg.newModifiers)
  of WlLayerFocusExclusive:
    result.dirty = model.setLayerFocusExclusive(true)
  of WlLayerFocusNonExclusive, WlLayerFocusNone:
    result.dirty = model.setLayerFocusExclusive(false)
  of WlSessionLocked:
    result.dirty = model.setSessionLocked(true)
  of WlSessionUnlocked:
    result.dirty = model.setSessionLocked(false)
    let focused = model.focusedWindow()
    if focused != NullWindowId:
      let externalId = model.legacyWindowId(focused)
      result.effects.add(broadcastWindowFocusChanged(externalId))
      result.effects.add(Effect(kind: EffFocusWindow, focusId: externalId))
  of WlPointerMoveRequested:
    if model.beginPointerMove(msg.moveWinId.externalWindowId()):
      result.effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.moveSeat))
  of WlPointerResizeRequested:
    if model.beginPointerResize(
        msg.resizeWinId.externalWindowId(), msg.resizeEdges):
      result.effects.add(Effect(
        kind: EffInformResizeStart,
        resizeLifecycleWinId: msg.resizeWinId))
      result.effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.resizeSeat))
  of WlPointerDelta:
    result.dirty = model.applyPointerDelta(msg.dx, msg.dy)
  of WlPointerRelease:
    let resized = model.finishPointerOp()
    if resized != NullWindowId:
      result.effects.add(Effect(
        kind: EffInformResizeEnd,
        resizeLifecycleWinId: model.legacyWindowId(resized)))

  of WlFocusChanged:
    result.dirty = model.setExternalFocus(msg.newFocusedId.externalWindowId())
  of WlWindowFullscreenRequested:
    result.dirty = model.requestFullscreenForExternal(
      msg.fullscreenRequestId.externalWindowId(),
      msg.fullscreenOutputId.externalOutputId())
    if result.dirty:
      let winId = model.windowForExternal(msg.fullscreenRequestId.externalWindowId())
      let win = model.windowData(winId).get()
      result.effects.addSetFullscreenEffect(
        msg.fullscreenRequestId, true, uint32(win.fullscreenOutput))
  of WlWindowExitFullscreenRequested:
    result.dirty = model.exitFullscreenForExternal(
      msg.exitFullscreenRequestId.externalWindowId())
    if result.dirty:
      result.effects.addSetFullscreenEffect(msg.exitFullscreenRequestId, false)
  of WlWindowMaximizeRequested:
    result.dirty = model.requestMaximizeForExternal(
      msg.maximizeRequestId.externalWindowId())
    if result.dirty:
      result.effects.addSetMaximizedEffect(msg.maximizeRequestId, true)
  of WlWindowUnmaximizeRequested:
    result.dirty = model.requestUnmaximizeForExternal(
      msg.unmaximizeRequestId.externalWindowId())
    if result.dirty:
      result.effects.addSetMaximizedEffect(msg.unmaximizeRequestId, false)
  of WlWindowMinimizeRequested:
    result.dirty = model.requestMinimizeForExternal(
      msg.minimizeRequestId.externalWindowId())
    if result.dirty:
      result.effects.addSetMaximizedEffect(msg.minimizeRequestId, false)
  else:
    discard
