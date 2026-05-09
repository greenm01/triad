import options, tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/dod_model

proc syncGroupCounter(model: var DodModel; groupId: GroupId) =
  let rawId = uint32(groupId)
  model.nextGroupId = max(model.nextGroupId, rawId)
  model.counters.nextGroupId = max(model.counters.nextGroupId, rawId)

proc allocateGroupId(model: var DodModel): GroupId =
  model.counters.nextGroupId = max(
    model.counters.nextGroupId,
    model.nextGroupId)
  result = model.counters.generateGroupId()
  model.syncGroupCounter(result)

proc normalizedGroupMembers(
    model: DodModel; windows: openArray[WindowId]): seq[WindowId] =
  for winId in windows:
    if winId == NullWindowId or model.windows.entity(winId).isNone:
      continue
    if result.find(winId) == -1:
      result.add(winId)

proc removeWindowFromGroup*(
    model: var DodModel; groupId: GroupId; winId: WindowId): bool =
  let groupOpt = model.groups.entity(groupId)
  if groupOpt.isNone:
    return false

  var group = groupOpt.get()
  var idx = 0
  while idx < group.windows.len:
    if group.windows[idx] == winId:
      group.windows.delete(idx)
      result = true
    else:
      inc idx

  if not result:
    return false

  if model.groupByWindow.getOrDefault(winId, NullGroupId) == groupId:
    model.groupByWindow.del(winId)

  if group.windows.len == 0:
    discard model.groups.delete(groupId)
    return true

  if group.activeWindow == winId or group.windows.find(group.activeWindow) == -1:
    group.activeWindow = group.windows[0]
  model.groups.mEntity(groupId) = group

proc removeWindowFromGroups*(model: var DodModel; winId: WindowId): bool =
  let indexedGroup = model.groupByWindow.getOrDefault(winId, NullGroupId)
  if indexedGroup != NullGroupId:
    result = model.removeWindowFromGroup(indexedGroup, winId)

  var groupIds: seq[GroupId]
  for group in model.groups.entities:
    if group.windows.find(winId) != -1:
      groupIds.add(group.id)
  for groupId in groupIds:
    if model.removeWindowFromGroup(groupId, winId):
      result = true

proc addGroupWithId*(model: var DodModel; groupId: GroupId;
    windows: openArray[WindowId]; activeWindow = NullWindowId): GroupId =
  let members = model.normalizedGroupMembers(windows)
  if members.len == 0:
    return NullGroupId

  result =
    if groupId == NullGroupId: model.allocateGroupId()
    else: groupId

  if model.groups.entity(result).isSome:
    let existing = model.groups.entity(result).get()
    for winId in existing.windows:
      if model.groupByWindow.getOrDefault(winId, NullGroupId) == result:
        model.groupByWindow.del(winId)

  for winId in members:
    let oldGroup = model.groupByWindow.getOrDefault(winId, NullGroupId)
    if oldGroup != NullGroupId and oldGroup != result:
      discard model.removeWindowFromGroup(oldGroup, winId)

  var active = activeWindow
  if active == NullWindowId or members.find(active) == -1:
    active = members[0]

  let group = GroupData(
    id: result,
    windows: members,
    activeWindow: active)
  if model.groups.entity(result).isSome:
    model.groups.mEntity(result) = group
  else:
    model.groups.insert(group)

  for winId in members:
    model.groupByWindow[winId] = result

  model.syncGroupCounter(result)

proc addGroup*(model: var DodModel; windows: openArray[WindowId];
    activeWindow = NullWindowId): GroupId =
  model.addGroupWithId(NullGroupId, windows, activeWindow)
