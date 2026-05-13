import std/[options, tables]
import ../state/[entity_manager, id_gen]
import ../types/[core, model]

proc addOutput*(
    model: var Model,
    externalId: ExternalOutputId,
    wlName = 0'u32,
    name = "",
    x = 0'i32,
    y = 0'i32,
    w = 0'i32,
    h = 0'i32,
    usableX = 0'i32,
    usableY = 0'i32,
    usableW = 0'i32,
    usableH = 0'i32,
    hasUsable = false,
): OutputId =
  if externalId != NullExternalOutputId and model.externalOutputIds.hasKey(externalId):
    return model.externalOutputIds[externalId]

  let id = model.counters.generateOutputId()
  model.outputs.insert(
    OutputData(
      id: id,
      externalId: externalId,
      wlName: wlName,
      name: name,
      x: x,
      y: y,
      w: w,
      h: h,
      usableX: usableX,
      usableY: usableY,
      usableW: usableW,
      usableH: usableH,
      hasUsable: hasUsable,
    )
  )
  if externalId != NullExternalOutputId:
    model.externalOutputIds[externalId] = id
  id

proc setOutputDimensions*(model: var Model, outputId: OutputId, w, h: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).w = max(0'i32, w)
  model.outputs.mEntity(outputId).h = max(0'i32, h)
  true

proc setOutputName*(model: var Model, outputId: OutputId, name: string): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).name = name
  true

proc setOutputPosition*(model: var Model, outputId: OutputId, x, y: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).x = x
  model.outputs.mEntity(outputId).y = y
  true

proc setOutputUsable*(model: var Model, outputId: OutputId, x, y, w, h: int32): bool =
  if model.outputs.entity(outputId).isNone:
    return false
  model.outputs.mEntity(outputId).usableX = x
  model.outputs.mEntity(outputId).usableY = y
  model.outputs.mEntity(outputId).usableW = max(0'i32, w)
  model.outputs.mEntity(outputId).usableH = max(0'i32, h)
  model.outputs.mEntity(outputId).hasUsable = true
  true

proc setOutputTag*(model: var Model, outputId: OutputId, tagId: TagId): bool =
  if model.outputs.entity(outputId).isNone or model.tags.entity(tagId).isNone:
    return false
  model.outputTags[outputId] = tagId
  true

proc destroyOutput*(model: var Model, outputId: OutputId): bool =
  let outputOpt = model.outputs.entity(outputId)
  if outputOpt.isNone:
    return false
  let externalId = outputOpt.get().externalId
  if externalId != NullExternalOutputId:
    model.externalOutputIds.del(externalId)
  model.outputTags.del(outputId)
  if model.primaryOutput == outputId:
    model.primaryOutput = NullOutputId
  model.outputs.delete(outputId)
