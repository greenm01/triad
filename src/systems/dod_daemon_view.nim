import options
import ../state/engine
from ../types/runtime_values import nil

proc runtimeWindowId*(model: DodModel; winId: WindowId):
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
    model: DodModel; winId: runtime_values.WindowId): WindowId =
  model.windowForExternal(winId.externalWindowId())

proc outputForRiverId*(model: DodModel; outputId: uint32): OutputId =
  model.outputForExternal(outputId.externalOutputId())

proc riverIdForWindow*(
    model: DodModel; winId: WindowId): runtime_values.WindowId =
  model.runtimeWindowId(winId)

proc riverIdForOutput*(model: DodModel; outputId: OutputId): uint32 =
  if outputId == NullOutputId:
    return 0
  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    return uint32(outputOpt.get().externalId)
  0

proc activeFocusRiverId*(model: DodModel): runtime_values.WindowId =
  if model.isScratchpadVisible:
    if model.visibleScratchpad != NullWindowId:
      return model.riverIdForWindow(model.visibleScratchpad)
    if model.scratchpadWindows.len > 0:
      return model.riverIdForWindow(model.scratchpadWindows[^1])
  if model.activeTag == NullTagId:
    return 0'u32
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return model.riverIdForWindow(tagOpt.get().focusedWindow)
  0'u32

proc primaryOutputRiverId*(model: DodModel): uint32 =
  model.riverIdForOutput(model.primaryOutput)

proc visibleScratchpadRiverId*(model: DodModel): runtime_values.WindowId =
  if model.visibleScratchpad != NullWindowId:
    return model.riverIdForWindow(model.visibleScratchpad)
  if model.scratchpadWindows.len > 0:
    return model.riverIdForWindow(model.scratchpadWindows[^1])
  0'u32

proc windowDataForRiverId*(
    model: DodModel; winId: runtime_values.WindowId): Option[WindowData] =
  let logicalId = model.windowForRiverId(winId)
  if logicalId == NullWindowId:
    return none(WindowData)
  model.windowData(logicalId)

proc hasRiverWindow*(model: DodModel; winId: runtime_values.WindowId): bool =
  model.windowForRiverId(winId) != NullWindowId

proc boundedDimensions*(win: WindowData; w, h: int32):
    tuple[w, h: int32] =
  result.w = max(0'i32, w)
  result.h = max(0'i32, h)
  if win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if win.minHeight > 0:
    result.h = max(result.h, win.minHeight)
  if win.maxWidth > 0:
    result.w = min(result.w, win.maxWidth)
  if win.maxHeight > 0:
    result.h = min(result.h, win.maxHeight)

proc boundedDimensionsForRiverId*(
    model: DodModel; winId: runtime_values.WindowId; w, h: int32):
    tuple[w, h: int32] =
  let winOpt = model.windowDataForRiverId(winId)
  if winOpt.isSome:
    return winOpt.get().boundedDimensions(w, h)
  (w: max(0'i32, w), h: max(0'i32, h))
