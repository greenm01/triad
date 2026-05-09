import sets, tables
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
    if not model.tagBySlot.hasKey(tag.slot) or model.tagBySlot[tag.slot] != tag.id:
      result.addError("tag slot index mismatch: " & $tag.id)
    if tag.focusedWindow != NullWindowId and not model.windows.hasEntity(tag.focusedWindow):
      result.addError("tag focused window is missing: " & $tag.id)

  for column in model.columns.entities:
    if not model.tags.hasEntity(column.tagId):
      result.addError("column tag is missing: " & $column.id)

  for win in model.windows.entities:
    if win.externalId != NullExternalWindowId:
      if not model.externalWindowIds.hasKey(win.externalId) or model.externalWindowIds[win.externalId] != win.id:
        result.addError("external window index mismatch: " & $win.id)
    if not model.windowTags.hasKey(win.id):
      result.addError("window tag mask is missing: " & $win.id)

  for tagId, columns in model.columnsByTag.pairs:
    if not model.tags.hasEntity(tagId):
      result.addError("columnsByTag references missing tag: " & $tagId)
    var seen = initHashSet[ColumnId]()
    for columnId in columns:
      if seen.contains(columnId):
        result.addError("duplicate column in tag: " & $columnId)
      seen.incl(columnId)
      if not model.columns.hasEntity(columnId):
        result.addError("columnsByTag references missing column: " & $columnId)
      elif model.columns.getEntity(columnId).tagId != tagId:
        result.addError("columnsByTag column belongs to another tag: " & $columnId)

  for tagId, windows in model.windowsByTag.pairs:
    if not model.tags.hasEntity(tagId):
      result.addError("windowsByTag references missing tag: " & $tagId)
      continue
    var seen = initHashSet[WindowId]()
    let bit = model.tags.getEntity(tagId).bit
    for winId in windows:
      if seen.contains(winId):
        result.addError("duplicate window in tag: " & $winId)
      seen.incl(winId)
      if not model.windows.hasEntity(winId):
        result.addError("windowsByTag references missing window: " & $winId)
      elif not model.windowTags.getOrDefault(winId, EmptyTagMask).contains(bit):
        result.addError("window tag mask misses tag membership: " & $winId)

  for columnId, windows in model.windowsByColumn.pairs:
    if not model.columns.hasEntity(columnId):
      result.addError("windowsByColumn references missing column: " & $columnId)
      continue
    let tagId = model.columns.getEntity(columnId).tagId
    for idx, winId in windows:
      if not model.windows.hasEntity(winId):
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
    if not model.tags.hasEntity(tagId):
      result.addError("placement references missing tag: " & $tagId)
    if not model.windows.hasEntity(winId):
      result.addError("placement references missing window: " & $winId)
    if not model.columns.hasEntity(placement.columnId):
      result.addError("placement references missing column: " & $placement.columnId)
    elif model.columns.getEntity(placement.columnId).tagId != tagId:
      result.addError("placement column belongs to another tag: " & $winId)
    if model.windowsByTag.getOrDefault(tagId, @[]).find(winId) == -1:
      result.addError("placement missing windowsByTag row: " & $winId)
    if model.windowsByColumn.getOrDefault(placement.columnId, @[]).find(winId) == -1:
      result.addError("placement missing windowsByColumn row: " & $winId)
