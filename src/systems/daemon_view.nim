import options
import ../state/engine
from ../types/runtime_values import nil

proc runtimeWindowId*(model: Model; winId: WindowId):
    runtime_values.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return runtime_values.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc externalWindowId*(winId: runtime_values.WindowId): ExternalWindowId =
  ExternalWindowId(uint32(winId))

proc externalOutputId*(outputId: uint32): ExternalOutputId =
  ExternalOutputId(outputId)

proc windowForRiverId*(
    model: Model; winId: runtime_values.WindowId): WindowId =
  model.windowForExternal(winId.externalWindowId())

proc outputForRiverId*(model: Model; outputId: uint32): OutputId =
  model.outputForExternal(outputId.externalOutputId())

proc riverIdForWindow*(
    model: Model; winId: WindowId): runtime_values.WindowId =
  model.runtimeWindowId(winId)

proc riverIdForOutput*(model: Model; outputId: OutputId): uint32 =
  if outputId == NullOutputId:
    return 0
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    return uint32(outputOpt.get().externalId)
  0

proc activeFocusRiverId*(model: Model): runtime_values.WindowId =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  if model.activeTag == NullTagId:
    return 0'u32
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return model.riverIdForWindow(tagOpt.get().focusedWindow)
  0'u32

proc highlightRiverId*(model: Model): runtime_values.WindowId =
  if model.overviewActive:
    return model.riverIdForWindow(model.selectedOverviewWindow())
  model.activeFocusRiverId()

proc primaryOutputRiverId*(model: Model): uint32 =
  model.riverIdForOutput(model.primaryOutput)

proc visibleScratchpadRiverId*(model: Model): runtime_values.WindowId =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return model.riverIdForWindow(scratchpad)
  0'u32

proc windowDataForRiverId*(
    model: Model; winId: runtime_values.WindowId): Option[WindowData] =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return none(WindowData)
  model.windowData(logicalId)

proc hasRiverWindow*(model: Model; winId: runtime_values.WindowId): bool =
  model.windowForRiverId(winId) != NullWindowId

proc proposalDimensions*(win: WindowData; w, h: int32;
    honorMinimums: bool): tuple[w, h: int32] =
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

proc boundedDimensions*(win: WindowData; w, h: int32):
    tuple[w, h: int32] =
  win.proposalDimensions(w, h, honorMinimums = true)

proc needsCellClip*(win: WindowData; cellW, cellH: int32): bool =
  let safeW = max(0'i32, cellW)
  let safeH = max(0'i32, cellH)
  (win.actualW > safeW and safeW > 0) or
    (win.actualH > safeH and safeH > 0) or
    (win.minWidth > safeW and safeW > 0) or
    (win.minHeight > safeH and safeH > 0)

proc boundedDimensionsForRiverId*(
    model: Model; winId: runtime_values.WindowId; w, h: int32):
    tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().boundedDimensions(w, h)
  (w: max(0'i32, w), h: max(0'i32, h))

proc proposalDimensionsForRiverId*(
    model: Model; winId: runtime_values.WindowId; w, h: int32;
    honorMinimums: bool): tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().proposalDimensions(w, h, honorMinimums)
  (w: max(0'i32, w), h: max(0'i32, h))
