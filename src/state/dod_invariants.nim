import options, sets, tables
import entity_manager
import id_gen
import ../types/core
import ../types/dod_model

type
  DodInvariantError* = object
    message*: string

  DodInvariantReport* = object
    ok*: bool
    errors*: seq[DodInvariantError]

proc addError(report: var DodInvariantReport; message: string) =
  report.ok = false
  report.errors.add(DodInvariantError(message: message))

proc validateInvariants*(model: DodModel): DodInvariantReport =
  result.ok = true

  for tag in model.tags.entities:
    if tag.slot == 0:
      result.addError("tag has zero slot: " & $tag.id)
    if not model.tagBySlot.hasKey(tag.slot) or
        model.tagBySlot[tag.slot] != tag.id:
      result.addError("tag slot index mismatch: " & $tag.id)
    if tag.focusedWindow != NullWindowId and
        model.windows.entity(tag.focusedWindow).isNone:
      result.addError("tag focused window is missing: " & $tag.id)

  for column in model.columns.entities:
    if model.tags.entity(column.tagId).isNone:
      result.addError("column tag is missing: " & $column.id)

  for win in model.windows.entities:
    if win.externalId != NullExternalWindowId:
      if not model.externalWindowIds.hasKey(win.externalId) or
          model.externalWindowIds[win.externalId] != win.id:
        result.addError("external window index mismatch: " & $win.id)
    if not model.windowTags.hasKey(win.id):
      result.addError("window tag mask is missing: " & $win.id)

  for tagId, columns in model.columnsByTag.pairs:
    if model.tags.entity(tagId).isNone:
      result.addError("columnsByTag references missing tag: " & $tagId)
    var seen = initHashSet[ColumnId]()
    for columnId in columns:
      if seen.contains(columnId):
        result.addError("duplicate column in tag: " & $columnId)
      seen.incl(columnId)
      let columnOpt = model.columns.entity(columnId)
      if columnOpt.isNone:
        result.addError("columnsByTag references missing column: " & $columnId)
      elif columnOpt.get().tagId != tagId:
        result.addError(
          "columnsByTag column belongs to another tag: " & $columnId)

  for tagId, windows in model.windowsByTag.pairs:
    let tagOpt = model.tags.entity(tagId)
    if tagOpt.isNone:
      result.addError("windowsByTag references missing tag: " & $tagId)
      continue
    var seen = initHashSet[WindowId]()
    let bit = tagOpt.get().bit
    for winId in windows:
      if seen.contains(winId):
        result.addError("duplicate window in tag: " & $winId)
      seen.incl(winId)
      if model.windows.entity(winId).isNone:
        result.addError("windowsByTag references missing window: " & $winId)
      elif not model.windowTags.getOrDefault(winId, EmptyTagMask).contains(bit):
        result.addError("window tag mask misses tag membership: " & $winId)

  for columnId, windows in model.windowsByColumn.pairs:
    let columnOpt = model.columns.entity(columnId)
    if columnOpt.isNone:
      result.addError("windowsByColumn references missing column: " & $columnId)
      continue
    let tagId = columnOpt.get().tagId
    for idx, winId in windows:
      if model.windows.entity(winId).isNone:
        result.addError("windowsByColumn references missing window: " & $winId)
      let key = (tagId, winId)
      if not model.placementByTagWindow.hasKey(key):
        result.addError("window in column has no placement row: " & $winId)
      else:
        let placement = model.placementByTagWindow[key]
        if placement.columnId != columnId:
          result.addError("placement row points at another column: " & $winId)
        if placement.windowIdx != uint32(idx + 1):
          result.addError("placement row has stale window index: " & $winId)

  for key, placement in model.placementByTagWindow.pairs:
    let tagId = key[0]
    let winId = key[1]
    if placement.tagId != tagId or placement.windowId != winId:
      result.addError("placement key and payload mismatch")
    if model.tags.entity(tagId).isNone:
      result.addError("placement references missing tag: " & $tagId)
    if model.windows.entity(winId).isNone:
      result.addError("placement references missing window: " & $winId)
    let columnOpt = model.columns.entity(placement.columnId)
    if columnOpt.isNone:
      result.addError(
        "placement references missing column: " & $placement.columnId)
    elif columnOpt.get().tagId != tagId:
      result.addError("placement column belongs to another tag: " & $winId)
    if model.windowsByTag.getOrDefault(tagId, @[]).find(winId) == -1:
      result.addError("placement missing windowsByTag row: " & $winId)
    let columnWindows = model.windowsByColumn.getOrDefault(
      placement.columnId, @[])
    if columnWindows.find(winId) == -1:
      result.addError("placement missing windowsByColumn row: " & $winId)
