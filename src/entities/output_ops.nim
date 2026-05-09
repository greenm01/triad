import tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/dod_model

proc addOutput*(
    model: var DodModel; externalId: ExternalOutputId; wlName = 0'u32;
    name = ""; x = 0'i32; y = 0'i32; w = 0'i32; h = 0'i32;
    usableX = 0'i32; usableY = 0'i32; usableW = 0'i32; usableH = 0'i32;
    hasUsable = false): OutputId =
  if externalId != NullExternalOutputId and
      model.externalOutputIds.hasKey(externalId):
    return model.externalOutputIds[externalId]

  let id = model.counters.generateOutputId()
  model.outputs.insert(OutputData(
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
    hasUsable: hasUsable
  ))
  if externalId != NullExternalOutputId:
    model.externalOutputIds[externalId] = id
  id
