import options, tables
import entity_manager
import ../types/core
import ../types/dod_model

iterator tagSlots*(model: DodModel): uint32 =
  for slot in model.tagBySlot.keys:
    yield slot

iterator tagsWithId*(
    model: DodModel): tuple[id: TagId, tag: TagData] =
  for tag in model.tags.entities:
    yield (tag.id, tag)

iterator windowsWithId*(
    model: DodModel): tuple[id: WindowId, window: WindowData] =
  for win in model.windows.entities:
    yield (win.id, win)

iterator outputsWithId*(
    model: DodModel): tuple[id: OutputId, output: OutputData] =
  for output in model.outputs.entities:
    yield (output.id, output)

iterator columnsWithId*(
    model: DodModel): tuple[id: ColumnId, column: ColumnData] =
  for column in model.columns.entities:
    yield (column.id, column)

iterator columnsOnTagWithId*(
    model: DodModel; tagId: TagId): tuple[id: ColumnId, column: ColumnData] =
  for columnId in model.columnsByTag.getOrDefault(tagId, @[]):
    let columnOpt = model.columns.entity(columnId)
    if columnOpt.isSome:
      yield (columnId, columnOpt.get())

iterator windowsOnColumnWithId*(
    model: DodModel;
    columnId: ColumnId): tuple[id: WindowId, window: WindowData] =
  for winId in model.windowsByColumn.getOrDefault(columnId, @[]):
    let winOpt = model.windows.entity(winId)
    if winOpt.isSome:
      yield (winId, winOpt.get())

iterator windowsOnTagWithId*(
    model: DodModel; tagId: TagId): tuple[id: WindowId, window: WindowData] =
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    let winOpt = model.windows.entity(winId)
    if winOpt.isSome:
      yield (winId, winOpt.get())

iterator placementsWithId*(model: DodModel):
    tuple[tagId: TagId, windowId: WindowId, placement: WindowPlacement] =
  for key, placement in model.placementByTagWindow.pairs:
    yield (key[0], key[1], placement)

iterator outputTagsWithId*(
    model: DodModel): tuple[outputId: OutputId, tagId: TagId] =
  for outputId, tagId in model.outputTags.pairs:
    yield (outputId, tagId)
