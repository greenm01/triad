import std/[options, tables]
import entity_manager
import ../types/[core, model]

iterator tagSlots*(model: Model): uint32 =
  for slot in model.tagBySlot.keys:
    yield slot

iterator tagsWithId*(model: Model): tuple[id: TagId, tag: TagData] =
  for tag in model.tags.entities:
    yield (tag.id, tag)

iterator windowsWithId*(model: Model): tuple[id: WindowId, window: WindowData] =
  for win in model.windows.entities:
    yield (win.id, win)

iterator outputsWithId*(model: Model): tuple[id: OutputId, output: OutputData] =
  for output in model.outputs.entities:
    yield (output.id, output)

iterator groupsWithId*(model: Model): tuple[id: GroupId, group: GroupData] =
  for group in model.groups.entities:
    yield (group.id, group)

iterator columnsWithId*(model: Model): tuple[id: ColumnId, column: ColumnData] =
  for column in model.columns.entities:
    yield (column.id, column)

iterator framesWithId*(model: Model): tuple[id: FrameId, frame: FrameData] =
  for frame in model.frames.entities:
    yield (frame.id, frame)

iterator bspNodesWithId*(model: Model): tuple[id: BspNodeId, node: BspNodeData] =
  for node in model.bspNodes.entities:
    yield (node.id, node)

iterator splitNodesWithId*(model: Model): tuple[id: SplitNodeId, node: SplitNodeData] =
  for node in model.splitNodes.entities:
    yield (node.id, node)

iterator framesOnTagWithId*(
    model: Model, tagId: TagId
): tuple[id: FrameId, frame: FrameData] =
  for frame in model.frames.entities:
    if frame.tagId == tagId:
      yield (frame.id, frame)

iterator bspNodesOnTagWithId*(
    model: Model, tagId: TagId
): tuple[id: BspNodeId, node: BspNodeData] =
  for node in model.bspNodes.entities:
    if node.tagId == tagId:
      yield (node.id, node)

iterator splitNodesOnTagWithId*(
    model: Model, tagId: TagId
): tuple[id: SplitNodeId, node: SplitNodeData] =
  for node in model.splitNodes.entities:
    if node.tagId == tagId:
      yield (node.id, node)

iterator columnsOnTagWithId*(
    model: Model, tagId: TagId
): tuple[id: ColumnId, column: ColumnData] =
  for columnId in model.columnsByTag.getOrDefault(tagId, @[]):
    let columnOpt = model.columns.entity(columnId)
    if columnOpt.isSome:
      yield (columnId, columnOpt.get())

iterator windowsOnColumnWithId*(
    model: Model, columnId: ColumnId
): tuple[id: WindowId, window: WindowData] =
  for winId in model.windowsByColumn.getOrDefault(columnId, @[]):
    let winOpt = model.windows.entity(winId)
    if winOpt.isSome:
      yield (winId, winOpt.get())

iterator windowsOnTagWithId*(
    model: Model, tagId: TagId
): tuple[id: WindowId, window: WindowData] =
  for winId in model.windowsByTag.getOrDefault(tagId, @[]):
    let winOpt = model.windows.entity(winId)
    if winOpt.isSome:
      yield (winId, winOpt.get())

iterator placementsWithId*(
    model: Model
): tuple[tagId: TagId, windowId: WindowId, placement: WindowPlacement] =
  for key, placement in model.placementByTagWindow.pairs:
    yield (key[0], key[1], placement)

iterator outputTagsWithId*(model: Model): tuple[outputId: OutputId, tagId: TagId] =
  for outputId, output in model.outputsWithId():
    if output.currentTag != NullTagId:
      yield (outputId, output.currentTag)

iterator scratchpadWindowIds*(model: Model): WindowId =
  for winId in model.scratchpadWindows:
    yield winId

iterator namedScratchpadsWithId*(model: Model): tuple[name: string, winId: WindowId] =
  for name, winId in model.namedScratchpads.pairs:
    yield (name, winId)

iterator scratchpadRestoreTagsWithId*(
    model: Model
): tuple[winId: WindowId, mask: TagMask] =
  for winId, mask in model.scratchpadRestoreTags.pairs:
    yield (winId, mask)

iterator focusHistoryIds*(model: Model): WindowId =
  for winId in model.focusHistory:
    yield winId

iterator focusHistoryIdsReverse*(model: Model): WindowId =
  for i in countdown(model.focusHistory.len - 1, 0):
    yield model.focusHistory[i]

iterator workspaceHistoryIds*(model: Model): TagId =
  for tagId in model.workspaceHistory:
    yield tagId

iterator restoreFocusHistoryIds*(model: Model): ExternalWindowId =
  for externalId in model.restoreFocusHistory:
    yield externalId

iterator restoreWorkspaceHistorySlots*(model: Model): uint32 =
  for slot in model.restoreWorkspaceHistory:
    yield slot

iterator restoreOutputTagsWithId*(
    model: Model
): tuple[externalId: ExternalOutputId, slot: uint32] =
  for externalId, slot in model.restoreOutputTags.pairs:
    yield (externalId, slot)

iterator restoreNamedScratchpadsWithId*(
    model: Model
): tuple[name: string, externalId: ExternalWindowId] =
  for name, externalId in model.restoreNamedScratchpads.pairs:
    yield (name, externalId)

iterator restoreWindowsWithId*(
    model: Model
): tuple[externalId: ExternalWindowId, window: RestoredWindowData] =
  for externalId, restored in model.restoreWindows.pairs:
    yield (externalId, restored)

iterator restoreSwallowingWithId*(
    model: Model
): tuple[hostExternalId: ExternalWindowId, childExternalId: ExternalWindowId] =
  for hostExternalId, childExternalId in model.restoreSwallowing.pairs:
    yield (hostExternalId, childExternalId)
