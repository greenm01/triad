import options, tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/dod_model

proc addColumn*(
    model: var DodModel; tagId: TagId; widthProportion = 1.0'f32): ColumnId =
  if model.tags.entity(tagId).isNone:
    raise newException(ValueError, "column tag does not exist: " & $tagId)

  let id = model.counters.generateColumnId()
  model.columns.insert(ColumnData(
    id: id,
    tagId: tagId,
    widthProportion: max(0.05'f32, min(1.0'f32, widthProportion))
  ))
  model.columnsByTag.mgetOrPut(tagId, @[]).add(id)
  model.windowsByColumn[id] = @[]
  id
