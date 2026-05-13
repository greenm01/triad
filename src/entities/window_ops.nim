import std/[options, tables]
import group_ops, history_ops, placement_ops, scratchpad_ops
import ../state/[entity_manager, id_gen, iterators]
import ../types/core except Rect
import ../types/model
from ../types/runtime_values import Rect

proc addWindow*(model: var Model; externalId: ExternalWindowId; title = "";
    appId = ""; widthProportion = 1.0'f32; heightProportion = 1.0'f32;
    isFloating = false; isFullscreen = false; isMaximized = false;
    isMinimized = false; fullscreenOutput = NullExternalOutputId;
    parentExternalId = NullExternalWindowId; identifier = ""; actualW = 0'i32;
    actualH = 0'i32; minWidth = 0'i32; minHeight = 0'i32; maxWidth = 0'i32;
    maxHeight = 0'i32; hasDecorationHint = false; decorationHint = 0'u32;
    hasPresentationHint = false; presentationHint = 0'u32;
    floatingGeom = Rect(); parentAutoFloating = false;
    admissionState = WindowAdmissionState.Admitted;
    focusAfterAdmission = false;
    keyboardShortcutsInhibit = false;
    keyboardShortcutsInhibitBypass = false): WindowId =
  if externalId != NullExternalWindowId and
      model.externalWindowIds.hasKey(externalId):
    return model.externalWindowIds[externalId]

  let id = model.counters.generateWindowId()
  model.windows.insert(WindowData(
    id: id,
    externalId: externalId,
    title: title,
    appId: appId,
    widthProportion: widthProportion,
    heightProportion: heightProportion,
    isFloating: isFloating,
    isFullscreen: isFullscreen,
    isMaximized: isMaximized,
    isMinimized: isMinimized,
    fullscreenOutput: fullscreenOutput,
    parentExternalId: parentExternalId,
    identifier: identifier,
    actualW: actualW,
    actualH: actualH,
    minWidth: minWidth,
    minHeight: minHeight,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    hasDecorationHint: hasDecorationHint,
    decorationHint: decorationHint,
    hasPresentationHint: hasPresentationHint,
    presentationHint: presentationHint,
    floatingGeom: floatingGeom,
    parentAutoFloating: parentAutoFloating,
    admissionState: admissionState,
    focusAfterAdmission: focusAfterAdmission,
    keyboardShortcutsInhibit: keyboardShortcutsInhibit,
    keyboardShortcutsInhibitBypass: keyboardShortcutsInhibitBypass
  ))
  if externalId != NullExternalWindowId:
    model.externalWindowIds[externalId] = id
  model.windowTags[id] = EmptyTagMask
  id

proc pendingDialogFocusContains*(
    model: Model; winId: WindowId): bool =
  for pending in model.pendingDialogFocusWindows:
    if pending == winId:
      return true
  false

proc enqueuePendingDialogFocus*(
    model: var Model; winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  if model.pendingDialogFocusContains(winId):
    return false
  model.pendingDialogFocusWindows.add(winId)
  true

proc clearPendingDialogFocus*(
    model: var Model; winId: WindowId): bool =
  if winId == NullWindowId or model.pendingDialogFocusWindows.len == 0:
    return false
  var kept: seq[WindowId] = @[]
  for pending in model.pendingDialogFocusWindows:
    if pending != winId:
      kept.add(pending)
  result = kept.len != model.pendingDialogFocusWindows.len
  if result:
    model.pendingDialogFocusWindows = kept

proc clearPendingDialogFocusRefs(
    model: var Model; winId: WindowId; externalId: ExternalWindowId): bool =
  if model.pendingDialogFocusWindows.len == 0:
    return false
  var kept: seq[WindowId] = @[]
  for pending in model.pendingDialogFocusWindows:
    let pendingOpt = model.windows.entity(pending)
    if pending == winId or pendingOpt.isNone or
        pendingOpt.get().parentExternalId == externalId:
      result = true
    else:
      kept.add(pending)
  if result:
    model.pendingDialogFocusWindows = kept

proc setWindowCreatedState*(model: var Model; winId: WindowId;
    title = ""; appId = ""; identifier = ""; widthProportion = 1.0'f32;
    heightProportion = 1.0'f32; isFloating = false;
    floatingGeom = Rect(); parentAutoFloating = false;
    admissionState = WindowAdmissionState.Admitted;
    focusAfterAdmission = false; parentExternalId = NullExternalWindowId;
    keyboardShortcutsInhibit = false;
    preserveRuntimeState = false): bool =
  let currentOpt = model.windows.entity(winId)
  if currentOpt.isNone:
    return false
  let current = currentOpt.get()
  model.windows.mEntity(winId) = WindowData(
    id: winId,
    externalId: current.externalId,
    title: title,
    appId: appId,
    identifier: identifier,
    widthProportion:
      if preserveRuntimeState: current.widthProportion
      else: widthProportion,
    heightProportion:
      if preserveRuntimeState: current.heightProportion
      else: heightProportion,
    isFloating:
      if preserveRuntimeState: current.isFloating
      else: isFloating,
    isFullscreen:
      if preserveRuntimeState: current.isFullscreen
      else: false,
    isMaximized:
      if preserveRuntimeState: current.isMaximized
      else: false,
    isMinimized:
      if preserveRuntimeState: current.isMinimized
      else: false,
    fullscreenOutput:
      if preserveRuntimeState: current.fullscreenOutput
      else: NullExternalOutputId,
    actualW:
      if preserveRuntimeState: current.actualW
      else: 0'i32,
    actualH:
      if preserveRuntimeState: current.actualH
      else: 0'i32,
    minWidth:
      if preserveRuntimeState: current.minWidth
      else: 0'i32,
    minHeight:
      if preserveRuntimeState: current.minHeight
      else: 0'i32,
    maxWidth:
      if preserveRuntimeState: current.maxWidth
      else: 0'i32,
    maxHeight:
      if preserveRuntimeState: current.maxHeight
      else: 0'i32,
    hasDecorationHint:
      if preserveRuntimeState: current.hasDecorationHint
      else: false,
    decorationHint:
      if preserveRuntimeState: current.decorationHint
      else: 0'u32,
    hasPresentationHint:
      if preserveRuntimeState: current.hasPresentationHint
      else: false,
    presentationHint:
      if preserveRuntimeState: current.presentationHint
      else: 0'u32,
    floatingGeom:
      if preserveRuntimeState: current.floatingGeom
      else: floatingGeom,
    parentAutoFloating:
      if preserveRuntimeState: current.parentAutoFloating
      else: parentAutoFloating,
    admissionState: admissionState,
    focusAfterAdmission: focusAfterAdmission,
    parentExternalId: parentExternalId,
    keyboardShortcutsInhibit: keyboardShortcutsInhibit,
    keyboardShortcutsInhibitBypass:
      if preserveRuntimeState: current.keyboardShortcutsInhibitBypass
      else: false
  )
  true

proc destroyWindow*(model: var Model; winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  discard model.clearPendingDialogFocusRefs(winId, winOpt.get().externalId)

  var tagIds: seq[TagId] = @[]
  for tagId, placementWinId, _ in model.placementsWithId():
    if placementWinId == winId:
      tagIds.add(tagId)
  for tagId in tagIds:
    discard model.removeWindowFromTag(tagId, winId)
  discard model.removeWindowFromGroups(winId)

  let externalId = winOpt.get().externalId
  if externalId != NullExternalWindowId:
    model.externalWindowIds.del(externalId)
  discard model.removeScratchpadRef(winId)
  model.windowTags.del(winId)
  discard model.removeFocusHistoryRef(winId)
  for _, tag in model.tagsWithId():
    if tag.focusedWindow == winId:
      model.tags.mEntity(tag.id).focusedWindow = NullWindowId
  model.windows.delete(winId)

proc setWindowMinimized*(
    model: var Model; winId: WindowId; minimized: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  if minimized:
    discard model.clearPendingDialogFocus(winId)
  model.windows.mEntity(winId).isMinimized = minimized
  true

proc preserveWindowRuntimeAttributes*(
    model: var Model; winId: WindowId; source: WindowData): bool =
  let currentOpt = model.windows.entity(winId)
  if currentOpt.isNone:
    return false
  let current = currentOpt.get()
  if current.widthProportion == source.widthProportion and
      current.heightProportion == source.heightProportion and
      current.isFloating == source.isFloating and
      current.isFullscreen == source.isFullscreen and
      current.isMaximized == source.isMaximized and
      current.isMinimized == source.isMinimized and
      current.fullscreenOutput == source.fullscreenOutput and
      current.actualW == source.actualW and
      current.actualH == source.actualH and
      current.minWidth == source.minWidth and
      current.minHeight == source.minHeight and
      current.maxWidth == source.maxWidth and
      current.maxHeight == source.maxHeight and
      current.hasDecorationHint == source.hasDecorationHint and
      current.decorationHint == source.decorationHint and
      current.hasPresentationHint == source.hasPresentationHint and
      current.presentationHint == source.presentationHint and
      current.floatingGeom == source.floatingGeom and
      current.parentAutoFloating == source.parentAutoFloating and
      current.parentExternalId == source.parentExternalId and
      current.keyboardShortcutsInhibit == source.keyboardShortcutsInhibit and
      current.keyboardShortcutsInhibitBypass ==
        source.keyboardShortcutsInhibitBypass:
    return false

  var win = model.windows.mEntity(winId)
  win.widthProportion = source.widthProportion
  win.heightProportion = source.heightProportion
  win.isFloating = source.isFloating
  win.isFullscreen = source.isFullscreen
  win.isMaximized = source.isMaximized
  win.isMinimized = source.isMinimized
  win.fullscreenOutput = source.fullscreenOutput
  win.actualW = source.actualW
  win.actualH = source.actualH
  win.minWidth = source.minWidth
  win.minHeight = source.minHeight
  win.maxWidth = source.maxWidth
  win.maxHeight = source.maxHeight
  win.hasDecorationHint = source.hasDecorationHint
  win.decorationHint = source.decorationHint
  win.hasPresentationHint = source.hasPresentationHint
  win.presentationHint = source.presentationHint
  win.floatingGeom = source.floatingGeom
  win.parentAutoFloating = source.parentAutoFloating
  win.parentExternalId = source.parentExternalId
  win.keyboardShortcutsInhibit = source.keyboardShortcutsInhibit
  win.keyboardShortcutsInhibitBypass = source.keyboardShortcutsInhibitBypass
  true

proc setWindowWidthProportion*(
    model: var Model; winId: WindowId; widthProportion: float32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).widthProportion =
    clamp(widthProportion, 0.05'f32, 1.0'f32)
  true

proc setWindowHeightProportion*(
    model: var Model; winId: WindowId; heightProportion: float32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).heightProportion =
    clamp(heightProportion, 0.05'f32, 1.0'f32)
  true

proc setWindowTitle*(model: var Model; winId: WindowId; title: string):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).title = title
  true

proc setWindowAppId*(model: var Model; winId: WindowId; appId: string):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).appId = appId
  true

proc setWindowIdentifier*(
    model: var Model; winId: WindowId; identifier: string): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).identifier = identifier
  true

proc setWindowParent*(
    model: var Model; winId: WindowId; parentExternalId: ExternalWindowId):
    bool =
  if model.windows.entity(winId).isNone:
    return false
  discard model.clearPendingDialogFocus(winId)
  model.windows.mEntity(winId).parentExternalId = parentExternalId
  true

proc setWindowDimensions*(
    model: var Model; winId: WindowId; actualW, actualH: int32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).actualW = max(0'i32, actualW)
  model.windows.mEntity(winId).actualH = max(0'i32, actualH)
  true

proc setWindowRestoredState*(
    model: var Model; winId: WindowId; restored: RestoredWindowData): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).widthProportion = restored.widthProportion
  model.windows.mEntity(winId).heightProportion = restored.heightProportion
  model.windows.mEntity(winId).isFloating = restored.isFloating
  model.windows.mEntity(winId).parentAutoFloating = false
  model.windows.mEntity(winId).admissionState = WindowAdmissionState.Admitted
  model.windows.mEntity(winId).focusAfterAdmission = false
  model.windows.mEntity(winId).isFullscreen = restored.isFullscreen
  model.windows.mEntity(winId).isMaximized = restored.isMaximized
  model.windows.mEntity(winId).isMinimized = restored.isMinimized
  model.windows.mEntity(winId).fullscreenOutput = restored.fullscreenOutput
  model.windows.mEntity(winId).floatingGeom = restored.floatingGeom
  if restored.parentExternalId != NullExternalWindowId:
    model.windows.mEntity(winId).parentExternalId = restored.parentExternalId
  model.windows.mEntity(winId).actualW = restored.actualW
  model.windows.mEntity(winId).actualH = restored.actualH
  true

proc setWindowDimensionsHint*(model: var Model; winId: WindowId;
    minWidth, minHeight, maxWidth, maxHeight: int32): bool =
  if model.windows.entity(winId).isNone:
    return false

  var maxW = max(0'i32, maxWidth)
  var maxH = max(0'i32, maxHeight)
  let minW = max(0'i32, minWidth)
  let minH = max(0'i32, minHeight)
  if maxW > 0 and maxW < minW:
    maxW = minW
  if maxH > 0 and maxH < minH:
    maxH = minH

  model.windows.mEntity(winId).minWidth = minW
  model.windows.mEntity(winId).minHeight = minH
  model.windows.mEntity(winId).maxWidth = maxW
  model.windows.mEntity(winId).maxHeight = maxH
  true

proc setWindowDecorationHint*(
    model: var Model; winId: WindowId; hint: uint32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).hasDecorationHint = true
  model.windows.mEntity(winId).decorationHint = hint
  true

proc setWindowPresentationHint*(
    model: var Model; winId: WindowId; hint: uint32): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).hasPresentationHint = true
  model.windows.mEntity(winId).presentationHint = hint
  true

proc setWindowFloating*(model: var Model; winId: WindowId;
    floating: bool; floatingGeom = Rect(); parentAutoFloating = false): bool =
  if model.windows.entity(winId).isNone:
    return false
  if not floating:
    discard model.clearPendingDialogFocus(winId)
  model.windows.mEntity(winId).isFloating = floating
  model.windows.mEntity(winId).parentAutoFloating =
    floating and parentAutoFloating
  if floating:
    model.windows.mEntity(winId).floatingGeom = floatingGeom
  true

proc setWindowFloatingGeom*(
    model: var Model; winId: WindowId; floatingGeom: Rect): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).floatingGeom = floatingGeom
  model.windows.mEntity(winId).parentAutoFloating = false
  true

proc setWindowAdmission*(model: var Model; winId: WindowId;
    admissionState: WindowAdmissionState; focusAfterAdmission = false): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).admissionState = admissionState
  model.windows.mEntity(winId).focusAfterAdmission =
    admissionState == WindowAdmissionState.PendingAdmission and
    focusAfterAdmission
  true

proc setWindowFullscreen*(model: var Model; winId: WindowId;
    fullscreen: bool; outputId = NullExternalOutputId): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isFullscreen = fullscreen
  model.windows.mEntity(winId).fullscreenOutput =
    if fullscreen: outputId else: NullExternalOutputId
  true

proc setWindowMaximized*(
    model: var Model; winId: WindowId; maximized: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).isMaximized = maximized
  if maximized:
    model.windows.mEntity(winId).isMinimized = false
  true

proc setWindowKeyboardShortcutsInhibit*(model: var Model;
    winId: WindowId; inhibited: bool; bypass: bool): bool =
  if model.windows.entity(winId).isNone:
    return false
  model.windows.mEntity(winId).keyboardShortcutsInhibit = inhibited
  model.windows.mEntity(winId).keyboardShortcutsInhibitBypass =
    inhibited and bypass
  true

proc toggleWindowKeyboardShortcutsInhibit*(
    model: var Model; winId: WindowId): bool =
  let winOpt = model.windows.entity(winId)
  if winOpt.isNone:
    return false
  if winOpt.get().keyboardShortcutsInhibit:
    model.windows.mEntity(winId).keyboardShortcutsInhibitBypass =
      not winOpt.get().keyboardShortcutsInhibitBypass
  else:
    model.windows.mEntity(winId).keyboardShortcutsInhibit = true
    model.windows.mEntity(winId).keyboardShortcutsInhibitBypass = false
  true
