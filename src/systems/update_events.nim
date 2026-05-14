import std/options
import ../core/[effects, msg]
import ../state/engine
from ../types/runtime_values import PointerOpKind
import focus
import outputs
import recent_windows
import runtime
import update_effects
import window_lifecycle
import window_state

proc setExternalFocus(model: var Model, externalId: ExternalWindowId): bool =
  if model.overviewActive and externalId == NullExternalWindowId:
    return false
  if model.overviewActive:
    let winId = model.windowForExternal(externalId)
    if winId == NullWindowId or model.overviewWindowIds().find(winId) == -1:
      return false
    discard model.setOverviewActive(false)
    discard model.setOverviewWorkspacePreviewsActive(false)
    discard model.clearOverviewSelection()
    return model.focusWindow(winId, restorePopupTree = false)
  let tagId = model.activeTag
  let tagOpt = model.tagData(tagId)
  if tagOpt.isNone:
    return false
  if externalId == NullExternalWindowId:
    return model.setTagFocus(tagId, NullWindowId)
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or model.placementForWindowOnTag(tagId, winId).isNone:
    return false
  model.focusWindow(winId, restorePopupTree = false)

proc applyEvent*(model: var Model, msg: Msg): UpdateStep =
  case msg.kind
  of MsgKind.WlManageStart:
    let focused = model.focusedOnActiveTag()
    if focused != NullWindowId:
      discard model.recordWorkspace(model.activeTag)
      discard model.recordFocus(focused)
      let externalId = model.runtimeWindowId(focused)
      result.effects.add(broadcastWindowFocusChanged(externalId))
      if not model.sessionLocked and not model.layerFocusExclusive:
        result.effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: externalId))
    result.dirty = true
  of MsgKind.WlOutputDimensions:
    result.dirty = model.setOutputDimensionsForExternal(
      msg.outputId.externalOutputId(), msg.width, msg.height
    )
  of MsgKind.WlOutputName:
    result.dirty = model.setOutputNameForExternal(
      msg.nameOutputId.externalOutputId(), msg.outputName
    )
  of MsgKind.WlOutputIdentity:
    result.dirty = model.setOutputIdentityForExternal(
      msg.identityOutputId.externalOutputId(), msg.outputMake, msg.outputModel
    )
  of MsgKind.WlOutputDescription:
    result.dirty = model.setOutputDescriptionForExternal(
      msg.descriptionOutputId.externalOutputId(), msg.outputDescription
    )
  of MsgKind.WlOutputPosition:
    result.dirty = model.setOutputPositionForExternal(
      msg.positionOutputId.externalOutputId(), msg.outputX, msg.outputY
    )
  of MsgKind.WlOutputUsable:
    result.dirty = model.setOutputUsableForExternal(
      msg.usableOutputId.externalOutputId(),
      msg.usableX,
      msg.usableY,
      msg.usableW,
      msg.usableH,
    )
  of MsgKind.WlOutputRemoved:
    for winId in model.removeOutputForExternal(msg.removedOutputId.externalOutputId()):
      result.dirty = true
  of MsgKind.WlWindowCreated:
    let winId = model.createWindowForExternal(
      msg.windowId.externalWindowId(),
      msg.appId,
      msg.title,
      msg.createdIdentifier,
      msg.createdPid,
      msg.createdParentWindowId.externalWindowId(),
      msg.createdSwallowHostWindowId.externalWindowId(),
      msg.deferAdmission,
    )
    result.dirty = winId != NullWindowId
  of MsgKind.WlWindowDestroyed:
    result.dirty = model.destroyWindowForExternal(msg.destroyedId.externalWindowId())
    if result.dirty:
      result.effects.add(broadcastWindowClosed(msg.destroyedId))
  of MsgKind.WlWindowDimensions:
    if model.recentWindowsActive or model.overviewActive:
      result.dirty = false
    else:
      result.dirty = model.updateWindowDimensionsForExternal(
        msg.dimensionsWindowId.externalWindowId(), msg.actualWidth, msg.actualHeight
      )
  of MsgKind.WlWindowDecorationHint:
    result.dirty = model.updateWindowDecorationHintForExternal(
      msg.decorationWindowId.externalWindowId(), msg.decorationHint
    )
  of MsgKind.WlWindowPresentationHint:
    result.dirty = model.updateWindowPresentationHintForExternal(
      msg.presentationWindowId.externalWindowId(), msg.presentationHint
    )
  of MsgKind.WlWindowParent:
    result.dirty = model.updateWindowParentForExternal(
      msg.childWindowId.externalWindowId(), msg.parentWindowId.externalWindowId()
    )
  of MsgKind.WlWindowIdentifier:
    let externalId = msg.identifierWindowId.externalWindowId()
    result.dirty =
      model.updateWindowIdentifierAndRestoreForExternal(externalId, msg.identifier)
  of MsgKind.WlWindowPid:
    result.dirty = model.updateWindowPidForExternal(
      msg.pidWindowId.externalWindowId(), msg.windowPid
    )
  of MsgKind.WlWindowAppId:
    result.dirty = model.updateWindowAppIdForExternal(
      msg.appIdWindowId.externalWindowId(), msg.updatedAppId
    )
  of MsgKind.WlWindowTitle:
    result.dirty = model.updateWindowTitleForExternal(
      msg.titleWindowId.externalWindowId(), msg.updatedTitle
    )
  of MsgKind.WlWindowDimensionsHint:
    result.dirty = model.updateWindowDimensionsHintForExternal(
      msg.hintWindowId.externalWindowId(),
      msg.minWidth,
      msg.minHeight,
      msg.maxWidth,
      msg.maxHeight,
    )
  of MsgKind.WlWindowMenuRequested:
    if model.windowMenuCommand.len > 0 and
        model.windowForExternal(msg.menuWindowId.externalWindowId()) != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffSpawnWindowMenu,
          windowMenuCommand: model.windowMenuCommand,
          windowMenuId: msg.menuWindowId,
          windowMenuX: msg.menuX,
          windowMenuY: msg.menuY,
        )
      )
  of MsgKind.WlShellSurfaceInteraction:
    if msg.shellSurfaceId != 0 and not model.sessionLocked and
        not model.layerFocusExclusive:
      result.effects.add(
        Effect(
          kind: EffectKind.EffFocusShellSurface, focusShellSurfaceId: msg.shellSurfaceId
        )
      )
    if model.hotkeyOverlayOpen:
      result.dirty = model.setHotkeyOverlayOpen(false)
  of MsgKind.WlModifiersChanged:
    discard model.setActiveModifiers(msg.newModifiers)
    if model.recentWindowsActive and msg.newModifiers == 0:
      let selected = model.confirmedRecentWindow()
      result.dirty = selected != NullWindowId
      if selected != NullWindowId:
        result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.WlLayerFocusExclusive:
    result.dirty = model.setLayerFocusExclusive(true)
  of MsgKind.WlLayerFocusNonExclusive, MsgKind.WlLayerFocusNone:
    result.dirty = model.setLayerFocusExclusive(false)
  of MsgKind.WlSessionLocked:
    result.dirty = model.setSessionLocked(true)
  of MsgKind.WlSessionUnlocked:
    result.dirty = model.setSessionLocked(false)
    result.dirty = model.setLayerFocusExclusive(false) or result.dirty
    let focused = model.focusedOnActiveTag()
    if focused != NullWindowId:
      let externalId = model.runtimeWindowId(focused)
      result.effects.add(broadcastWindowFocusChanged(externalId))
      result.effects.add(Effect(kind: EffectKind.EffFocusWindow, focusId: externalId))
  of MsgKind.WlPointerMoveRequested:
    if model.beginPointerMove(msg.moveWinId.externalWindowId()):
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.moveSeat)
      )
  of MsgKind.WlPointerResizeRequested:
    if model.beginPointerResize(msg.resizeWinId.externalWindowId(), msg.resizeEdges):
      result.effects.add(
        Effect(
          kind: EffectKind.EffInformResizeStart, resizeLifecycleWinId: msg.resizeWinId
        )
      )
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.resizeSeat)
      )
  of MsgKind.WlOverviewPointerDragRequested:
    if model.beginOverviewDrag(
      msg.overviewDragWinId.externalWindowId(), msg.overviewDragX, msg.overviewDragY
    ):
      result.dirty = true
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.overviewDragSeat)
      )
  of MsgKind.WlOverviewPointerScrollRequested:
    if model.beginOverviewScroll(msg.overviewScrollX, msg.overviewScrollY):
      result.dirty = true
      result.effects.add(
        Effect(kind: EffectKind.EffOpStartPointer, opSeat: msg.overviewScrollSeat)
      )
  of MsgKind.WlOverviewWheel:
    result.dirty = model.handleOverviewWheel(
      msg.overviewWheelX, msg.overviewWheelY, msg.overviewWheelHorizontal,
      msg.overviewWheelVertical,
    )
  of MsgKind.WlRecentWindowPointerMotion:
    result.dirty = model.selectRecentWindowAt(msg.recentPointerX, msg.recentPointerY)
  of MsgKind.WlPointerDelta:
    result.dirty = model.applyPointerDelta(msg.dx, msg.dy)
  of MsgKind.WlPointerRelease:
    result.dirty = model.pointerOp.kind != PointerOpKind.OpNone
    let resized = model.finishPointerOp()
    if resized != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffInformResizeEnd,
          resizeLifecycleWinId: model.runtimeWindowId(resized),
        )
      )
  of MsgKind.WlFocusChanged:
    result.dirty = model.setExternalFocus(msg.newFocusedId.externalWindowId())
  of MsgKind.WlWindowFullscreenRequested:
    result.dirty = model.requestFullscreenForExternal(
      msg.fullscreenRequestId.externalWindowId(),
      msg.fullscreenOutputId.externalOutputId(),
    )
    if result.dirty:
      discard
  of MsgKind.WlWindowExitFullscreenRequested:
    result.dirty =
      model.exitFullscreenForExternal(msg.exitFullscreenRequestId.externalWindowId())
  of MsgKind.WlWindowMaximizeRequested:
    result.dirty =
      model.requestMaximizeForExternal(msg.maximizeRequestId.externalWindowId())
  of MsgKind.WlWindowUnmaximizeRequested:
    result.dirty =
      model.requestUnmaximizeForExternal(msg.unmaximizeRequestId.externalWindowId())
  of MsgKind.WlWindowMinimizeRequested:
    result.dirty =
      model.requestMinimizeForExternal(msg.minimizeRequestId.externalWindowId())
  of MsgKind.WlWindowAdmissionSettled:
    result.dirty =
      model.settleWindowAdmissionForExternal(msg.admissionWindowId.externalWindowId())
  else:
    discard
