import std/[options, strutils]
import ../state/engine

proc syncPrimaryOutput*(model: var Model) =
  if model.outputsCount() == 0:
    model.primaryOutput = NullOutputId
    return

  if model.primaryOutput == NullOutputId or not model.hasOutput(model.primaryOutput):
    model.primaryOutput = model.sortedOutputIdsByExternal()[0]

  let primary = model.output(model.primaryOutput)
  if primary.isSome and primary.get().w > 0 and primary.get().h > 0:
    discard model.setScreenSize(primary.get().w, primary.get().h)

proc upsertOutputForExternal*(
    model: var Model, externalId: ExternalOutputId
): OutputId =
  if externalId == NullExternalOutputId:
    return NullOutputId
  result = model.outputForExternal(externalId)
  if result == NullOutputId:
    result = model.addOutput(externalId)

proc setOutputDimensionsForExternal*(
    model: var Model, externalId: ExternalOutputId, w, h: int32
): bool =
  if externalId == NullExternalOutputId:
    return model.setScreenSize(w, h)

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputDimensions(outputId, w, h)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc setOutputNameForExternal*(
    model: var Model, externalId: ExternalOutputId, name: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputName(outputId, name.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc setOutputIdentityForExternal*(
    model: var Model, externalId: ExternalOutputId, make, modelName: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputIdentity(outputId, make.strip(), modelName.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc setOutputDescriptionForExternal*(
    model: var Model, externalId: ExternalOutputId, description: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputDescription(outputId, description.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc setOutputPositionForExternal*(
    model: var Model, externalId: ExternalOutputId, x, y: int32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputPosition(outputId, x, y)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc setOutputUsableForExternal*(
    model: var Model, externalId: ExternalOutputId, x, y, w, h: int32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputUsable(outputId, x, y, w, h)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

proc removeOutputForExternal*(
    model: var Model, externalId: ExternalOutputId
): seq[WindowId] =
  if externalId == NullExternalOutputId:
    return
  let outputId = model.outputForExternal(externalId)
  if outputId == NullOutputId:
    return

  discard model.destroyOutput(outputId)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()

  for winId, win in model.windowsWithId():
    if win.isFullscreen and win.fullscreenOutput == externalId:
      discard model.setWindowFullscreen(winId, false)
      result.add(winId)
