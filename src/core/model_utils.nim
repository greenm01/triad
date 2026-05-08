import algorithm, tables
import model

const
  DefaultColumnWidth* = 0.5'f32
  DefaultWindowWidth* = 0.5'f32
  DefaultWindowHeight* = 1.0'f32
  DefaultMasterCount* = 1
  DefaultMasterRatio* = 0.55'f32

proc clampProportion*(value: float32; lo = 0.05'f32; hi = 1.0'f32): float32 =
  clamp(value, lo, hi)

proc safeLayoutMode*(stored: int; fallback = Scroller): LayoutMode =
  if stored >= ord(low(LayoutMode)) + 1 and stored <= ord(high(LayoutMode)) + 1:
    LayoutMode(stored - 1)
  else:
    fallback

proc initTagState*(tagId: uint32; layoutMode = Scroller; name = ""): TagState =
  TagState(
    tagId: tagId,
    name: name,
    layoutMode: layoutMode,
    masterCount: DefaultMasterCount,
    masterSplitRatio: DefaultMasterRatio
  )

proc flattenWindows*(tag: TagState): seq[WindowId] =
  for col in tag.columns:
    for win in col.windows:
      result.add(win)

proc findWindow*(tag: TagState; win: WindowId): tuple[found: bool, colIdx: int, winIdx: int] =
  for i, col in tag.columns:
    let j = col.windows.find(win)
    if j != -1:
      return (true, i, j)
  (false, -1, -1)

proc containsWindow*(tag: TagState; win: WindowId): bool =
  tag.findWindow(win).found

proc cleanupColumns*(tag: var TagState) =
  for i in countdown(tag.columns.len - 1, 0):
    if tag.columns[i].windows.len == 0:
      tag.columns.delete(i)

proc recomputeFocus*(tag: var TagState) =
  if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow):
    return

  tag.focusedWindow = 0
  for col in tag.columns:
    if col.windows.len > 0:
      tag.focusedWindow = col.windows[0]
      return

proc removeWindow*(tag: var TagState; win: WindowId): bool =
  for i in countdown(tag.columns.len - 1, 0):
    var j = tag.columns[i].windows.len - 1
    while j >= 0:
      if tag.columns[i].windows[j] == win:
        tag.columns[i].windows.delete(j)
        result = true
      dec j
  tag.cleanupColumns()
  if result:
    tag.recomputeFocus()

proc removeWindowFromAllTags*(model: var Model; win: WindowId): bool =
  var updates: seq[(uint32, TagState)] = @[]
  for tagId, tag in model.tags.pairs:
    var nextTag = tag
    if nextTag.removeWindow(win):
      result = true
      updates.add((tagId, nextTag))
  for item in updates:
    model.tags[item[0]] = item[1]

proc removeWindowFromScratchpad*(model: var Model; win: WindowId): bool =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.scratchpadWindows[i] == win:
      model.scratchpadWindows.delete(i)
      result = true
    else:
      inc i

proc ensureTag*(model: var Model; tagId: uint32; layoutMode = Scroller): TagState =
  if not model.tags.hasKey(tagId):
    model.tags[tagId] = initTagState(tagId, layoutMode)
  model.tags[tagId]

proc firstTagId*(model: Model): uint32 =
  if model.tags.len == 0:
    return 0
  var ids: seq[uint32] = @[]
  for id in model.tags.keys:
    ids.add(id)
  ids.sort()
  ids[0]

proc activeTagOrFallback*(model: Model): uint32 =
  if model.tags.hasKey(model.activeTag):
    model.activeTag
  else:
    model.firstTagId()

proc focusedOnActiveTag*(model: Model): WindowId =
  if model.tags.hasKey(model.activeTag):
    let tag = model.tags[model.activeTag]
    if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow):
      return tag.focusedWindow
  0

proc validateModel*(model: Model): seq[string] =
  var seen = initTable[WindowId, uint32]()

  for tagId, tag in model.tags.pairs:
    if tag.tagId != 0 and tag.tagId != tagId:
      result.add("tag table key " & $tagId & " does not match tagId " & $tag.tagId)

    for colIdx, col in tag.columns:
      if col.windows.len == 0:
        result.add("tag " & $tagId & " has empty column " & $colIdx)
      if col.widthProportion <= 0:
        result.add("tag " & $tagId & " has non-positive column width")

      for win in col.windows:
        if not model.windows.hasKey(win):
          result.add("tag " & $tagId & " references missing window " & $win)
        if seen.hasKey(win):
          result.add("window " & $win & " appears on multiple tags")
        seen[win] = tagId

    if tag.focusedWindow != 0 and not tag.containsWindow(tag.focusedWindow):
      result.add("tag " & $tagId & " focuses missing window " & $tag.focusedWindow)

  for win in model.scratchpadWindows:
    if not model.windows.hasKey(win):
      result.add("scratchpad references missing window " & $win)
    if seen.hasKey(win):
      result.add("window " & $win & " appears in scratchpad and tag " & $seen[win])
