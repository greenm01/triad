import options, strutils
import ../state/engine

proc syncPrimaryOutput*(model: var DodModel) =
  if model.outputsCount() == 0:
    model.primaryOutput = NullOutputId
    return

  if model.primaryOutput == NullOutputId or not model.hasOutput(
      model.primaryOutput):
    model.primaryOutput = model.sortedOutputIdsByExternal()[0]

  let primary = model.output(model.primaryOutput)
  if primary.isSome and primary.get().w > 0 and primary.get().h > 0:
    model.screenWidth = primary.get().w
    model.screenHeight = primary.get().h

proc syncPrimaryOutputTag*(model: var DodModel) =
  if model.primaryOutput != NullOutputId and model.activeTag != NullTagId:
    discard model.setOutputTag(model.primaryOutput, model.activeTag)

proc upsertOutputForExternal*(
    model: var DodModel; externalId: ExternalOutputId): OutputId =
  if externalId == NullExternalOutputId:
    return NullOutputId
  result = model.outputForExternal(externalId)
  if result == NullOutputId:
    result = model.addOutput(externalId)

proc setOutputDimensionsForExternal*(
    model: var DodModel; externalId: ExternalOutputId; w, h: int32): bool =
  if externalId == NullExternalOutputId:
    model.screenWidth = max(0'i32, w)
    model.screenHeight = max(0'i32, h)
    return true

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputDimensions(outputId, w, h)
  model.syncPrimaryOutput()
  model.syncPrimaryOutputTag()

proc setOutputNameForExternal*(
    model: var DodModel; externalId: ExternalOutputId; name: string): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputName(outputId, name.strip())
  model.syncPrimaryOutput()
  model.syncPrimaryOutputTag()

proc setOutputPositionForExternal*(
    model: var DodModel; externalId: ExternalOutputId; x, y: int32): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputPosition(outputId, x, y)
  model.syncPrimaryOutput()
  model.syncPrimaryOutputTag()

proc setOutputUsableForExternal*(model: var DodModel;
    externalId: ExternalOutputId; x, y, w, h: int32): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputUsable(outputId, x, y, w, h)
  model.syncPrimaryOutput()
  model.syncPrimaryOutputTag()

proc removeOutputForExternal*(
    model: var DodModel; externalId: ExternalOutputId): seq[WindowId] =
  if externalId == NullExternalOutputId:
    return
  let outputId = model.outputForExternal(externalId)
  if outputId == NullOutputId:
    return

  discard model.destroyOutput(outputId)
  model.syncPrimaryOutput()
  model.syncPrimaryOutputTag()

  for winId, win in model.windowsWithId():
    if win.isFullscreen and win.fullscreenOutput == externalId:
      discard model.setWindowFullscreen(winId, false)
      result.add(winId)
