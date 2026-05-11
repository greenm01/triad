import std/[options, tables]
import ../state/entity_manager
import ../types/[core, model]

proc addScratchpadRef*(model: var Model; winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  if model.scratchpadWindows.find(winId) == -1:
    model.scratchpadWindows.add(winId)
    return true
  false

proc removeNamedScratchpadRefs*(model: var Model; winId: WindowId): bool =
  var deadNames: seq[string] = @[]
  for name, namedWin in model.namedScratchpads.pairs:
    if namedWin == winId:
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)
    result = true

proc removeScratchpadRef*(model: var Model; winId: WindowId): bool =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.scratchpadWindows[i] == winId:
      model.scratchpadWindows.delete(i)
      result = true
    else:
      inc i

  if model.removeNamedScratchpadRefs(winId):
    result = true

  if model.visibleScratchpad == winId:
    model.visibleScratchpad = NullWindowId
    model.isScratchpadVisible = false
    result = true

proc setNamedScratchpadRef*(
    model: var Model; name: string; winId: WindowId): bool =
  if name.len == 0 or winId == NullWindowId or
      model.windows.entity(winId).isNone:
    return false
  result = model.addScratchpadRef(winId)
  if not model.namedScratchpads.hasKey(name) or
      model.namedScratchpads[name] != winId:
    model.namedScratchpads[name] = winId
    return true

proc showScratchpadRef*(model: var Model; winId: WindowId): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  discard model.addScratchpadRef(winId)
  model.visibleScratchpad = winId
  model.isScratchpadVisible = true
  true

proc hideScratchpadRef*(model: var Model): bool =
  let changed =
    model.visibleScratchpad != NullWindowId or model.isScratchpadVisible
  model.visibleScratchpad = NullWindowId
  model.isScratchpadVisible = false
  changed

proc setVisibleScratchpadRef*(
    model: var Model; winId: WindowId; visible: bool): bool =
  if winId == NullWindowId or model.windows.entity(winId).isNone:
    return false
  if visible:
    discard model.addScratchpadRef(winId)
  model.visibleScratchpad = winId
  model.isScratchpadVisible = visible
  true

proc pruneScratchpadRefs*(model: var Model): bool =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.windows.entity(model.scratchpadWindows[i]).isSome:
      inc i
    else:
      model.scratchpadWindows.delete(i)
      result = true

  var deadNames: seq[string] = @[]
  for name, winId in model.namedScratchpads.pairs:
    if model.windows.entity(winId).isNone:
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)
    result = true

  if model.visibleScratchpad != NullWindowId and
      model.windows.entity(model.visibleScratchpad).isNone:
    model.visibleScratchpad = NullWindowId
    model.isScratchpadVisible = false
    result = true
