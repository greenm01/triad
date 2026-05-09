import options, sets, tables
import iterators
import entity_manager
import id_gen
import ../types/core
import ../types/model

type
  InvariantError* = object
    message*: string

  InvariantReport* = object
    ok*: bool
    errors*: seq[InvariantError]

proc addError(report: var InvariantReport; message: string) =
  report.ok = false
  report.errors.add(InvariantError(message: message))

proc validateInvariants*(model: Model): InvariantReport =
  result.ok = true

  for _, tag in model.tagsWithId():
    if tag.slot == 0:
      result.addError("tag has zero slot: " & $tag.id)
    if not model.tagBySlot.hasKey(tag.slot) or
        model.tagBySlot[tag.slot] != tag.id:
      result.addError("tag slot index mismatch: " & $tag.id)
    if tag.focusedWindow != NullWindowId and
        model.windows.entity(tag.focusedWindow).isNone:
      result.addError("tag focused window is missing: " & $tag.id)

  if model.activeTag != NullTagId:
    let activeOpt = model.tags.entity(model.activeTag)
    if activeOpt.isNone:
      result.addError("active tag is missing: " & $model.activeTag)
    elif model.activeSlot != 0 and model.activeSlot != activeOpt.get().slot:
      result.addError("active slot does not match active tag")
  elif model.activeSlot != 0 and not model.tagBySlot.hasKey(model.activeSlot):
    result.addError("active slot has no tag: " & $model.activeSlot)

  for _, column in model.columnsWithId():
    if model.tags.entity(column.tagId).isNone:
      result.addError("column tag is missing: " & $column.id)

  for _, win in model.windowsWithId():
    if win.externalId != NullExternalWindowId:
      if not model.externalWindowIds.hasKey(win.externalId) or
          model.externalWindowIds[win.externalId] != win.id:
        result.addError("external window index mismatch: " & $win.id)
    if not model.windowTags.hasKey(win.id):
      result.addError("window tag mask is missing: " & $win.id)

  for groupId, group in model.groupsWithId():
    if group.windows.len == 0:
      result.addError("group has no members: " & $groupId)
    if group.id != groupId:
      result.addError("group id index mismatch: " & $groupId)
    if group.activeWindow == NullWindowId or
        group.windows.find(group.activeWindow) == -1:
      result.addError("group active window is not a member: " & $groupId)

    var seen = initHashSet[WindowId]()
    for winId in group.windows:
      if seen.contains(winId):
        result.addError("duplicate window in group: " & $winId)
      seen.incl(winId)
      if model.windows.entity(winId).isNone:
        result.addError("group references missing window: " & $winId)
      if model.groupByWindow.getOrDefault(winId, NullGroupId) != groupId:
        result.addError("group window index mismatch: " & $winId)

  for winId, groupId in model.groupByWindow.pairs:
    let groupOpt = model.groups.entity(groupId)
    if groupOpt.isNone:
      result.addError("groupByWindow references missing group: " & $winId)
    elif groupOpt.get().windows.find(winId) == -1:
      result.addError("groupByWindow missing group member: " & $winId)
    if model.windows.entity(winId).isNone:
      result.addError("groupByWindow references missing window: " & $winId)

  for winId in model.scratchpadWindows:
    if model.windows.entity(winId).isNone:
      result.addError("scratchpad references missing window: " & $winId)
    if model.windowTags.getOrDefault(winId, EmptyTagMask) != EmptyTagMask:
      result.addError("scratchpad window is still tagged: " & $winId)

  for name, winId in model.namedScratchpads.pairs:
    if model.windows.entity(winId).isNone:
      result.addError("named scratchpad references missing window: " & name)

  if model.visibleScratchpad != NullWindowId and
      model.windows.entity(model.visibleScratchpad).isNone:
    result.addError(
      "visible scratchpad references missing window: " &
      $model.visibleScratchpad)

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

  for tagId, winId, placement in model.placementsWithId():
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
