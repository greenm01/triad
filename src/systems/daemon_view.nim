import std/options
from ../core/layout_selection_codec import layoutIdString
from ../core/native_layout_codec import FrameTreeLayoutId, nativeLayoutIdString
import ../state/engine
import presentation_policy
import recent_windows

proc runtimeWindowId*(model: Model, winId: WindowId): uint32 =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return uint32(winOpt.get().externalId)
  0'u32

proc externalWindowId*(winId: uint32): ExternalWindowId =
  ExternalWindowId(uint32(winId))

proc externalOutputId*(outputId: uint32): ExternalOutputId =
  ExternalOutputId(outputId)

proc windowForRiverId*(model: Model, winId: uint32): WindowId =
  model.windowForExternal(winId.externalWindowId())

proc outputForRiverId*(model: Model, outputId: uint32): OutputId =
  model.outputForExternal(outputId.externalOutputId())

proc riverIdForWindow*(model: Model, winId: WindowId): uint32 =
  model.runtimeWindowId(winId)

proc riverIdForOutput*(model: Model, outputId: OutputId): uint32 =
  if outputId == NullOutputId:
    return 0
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    return uint32(outputOpt.get().externalId)
  0

proc activeFocusRiverId*(model: Model): uint32 =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  if model.activeTag == NullTagId:
    return 0'u32
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return model.riverIdForWindow(tagOpt.get().focusedWindow)
  0'u32

proc highlightRiverId*(model: Model): uint32 =
  if model.recentWindowsActive:
    return model.riverIdForWindow(model.selectedRecentWindow())
  if model.overviewActive:
    return model.riverIdForWindow(model.selectedOverviewWindow())
  model.activeFocusRiverId()

proc windowRenderFocused*(model: Model, winId: uint32): bool =
  if winId == 0:
    return false
  if model.recentWindowsActive or model.overviewActive:
    return winId == model.highlightRiverId()
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return false
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome and
      tagOpt.get().nativeLayoutId.nativeLayoutIdString() == FrameTreeLayoutId:
    let winOpt = model.windowData(logicalId)
    if winOpt.isSome and not winOpt.get().isFloating and
        not winOpt.get().isUnmanagedGlobal:
      let frameId = model.frameForWindowOnTag(model.activeTag, logicalId)
      return frameId != NullFrameId and frameId == tagOpt.get().focusedFrame
  winId == model.activeFocusRiverId()

proc windowRenderWorkspaceLocalFocusOnly*(model: Model, logicalId: WindowId): bool =
  if logicalId == NullWindowId or model.recentWindowsActive or model.overviewActive:
    return false
  if model.riverIdForWindow(logicalId) == model.activeFocusRiverId():
    return false
  for tagId, _ in model.tagsWithId():
    if model.tagVisibleOnOutput(tagId) and
        model.effectiveTagFocusedWindow(tagId) == logicalId:
      return true

proc primaryOutputRiverId*(model: Model): uint32 =
  model.riverIdForOutput(model.primaryOutput)

proc activeLayerDefaultOutputRiverId*(model: Model): uint32 =
  let activeOutput = model.riverIdForOutput(model.activeOutput)
  if activeOutput != 0:
    return activeOutput
  model.primaryOutputRiverId()

proc visibleScratchpadRiverId*(model: Model): uint32 =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  0'u32

proc activeLayoutSupportsMaximize*(model: Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  tagOpt.isSome and tagOpt.get().customLayoutId.layoutIdString().len == 0 and
    tagOpt.get().nativeLayoutId.nativeLayoutIdString().len == 0 and
    tagOpt.get().layoutMode.layoutSupportsMaximize()

proc effectivelyMaximizedForRiverId*(model: Model, winId: uint32): bool =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return false
  let winOpt = model.windowData(logicalId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  win.isMaximized and not win.isMinimized and not win.isFloating and
    model.activeLayoutSupportsMaximize() and
    not model.columnFullWidthForWindowOnTag(model.activeTag, logicalId)

proc windowDataForRiverId*(model: Model, winId: uint32): Option[WindowData] =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return none(WindowData)
  model.windowData(logicalId)

proc hasRiverWindow*(model: Model, winId: uint32): bool =
  model.windowForRiverId(winId) != NullWindowId

proc proposalDimensions*(
    win: WindowData, w, h: int32, honorMinimums: bool
): tuple[w, h: int32] =
  result.w = max(0'i32, w)
  result.h = max(0'i32, h)
  if honorMinimums and win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if honorMinimums and win.minHeight > 0:
    result.h = max(result.h, win.minHeight)
  if win.maxWidth > 0:
    result.w = min(result.w, win.maxWidth)
  if win.maxHeight > 0:
    result.h = min(result.h, win.maxHeight)

proc boundedDimensions*(win: WindowData, w, h: int32): tuple[w, h: int32] =
  win.proposalDimensions(w, h, honorMinimums = true)

proc needsCellClip*(win: WindowData, cellW, cellH: int32): bool =
  let safeW = max(0'i32, cellW)
  let safeH = max(0'i32, cellH)
  (win.actualW > safeW and safeW > 0) or (win.actualH > safeH and safeH > 0) or
    (win.minWidth > safeW and safeW > 0) or (win.minHeight > safeH and safeH > 0)

proc boundedDimensionsForRiverId*(
    model: Model, winId: uint32, w, h: int32
): tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().boundedDimensions(w, h)
  (w: max(0'i32, w), h: max(0'i32, h))

proc proposalDimensionsForRiverId*(
    model: Model, winId: uint32, w, h: int32, honorMinimums: bool
): tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().proposalDimensions(w, h, honorMinimums)
  (w: max(0'i32, w), h: max(0'i32, h))
