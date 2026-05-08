import algorithm, tables
import defaults
import model

proc clampProportion*(value: float32; lo = 0.05'f32; hi = 1.0'f32): float32 =
  clamp(value, lo, hi)

proc defaultColumnWidth*(model: Model): float32 =
  if model.defaultColumnWidth > 0:
    clampProportion(model.defaultColumnWidth)
  else:
    DefaultColumnWidth

proc defaultWindowWidth*(model: Model): float32 =
  if model.defaultWindowWidth > 0:
    clampProportion(model.defaultWindowWidth)
  else:
    DefaultWindowWidth

proc defaultWindowHeight*(model: Model): float32 =
  if model.defaultWindowHeight > 0:
    clampProportion(model.defaultWindowHeight)
  else:
    DefaultWindowHeight

proc defaultMasterCount*(model: Model): int =
  if model.defaultMasterCount > 0:
    max(1, model.defaultMasterCount)
  else:
    DefaultMasterCount

proc defaultMasterRatio*(model: Model): float32 =
  if model.defaultMasterRatio > 0:
    clamp(model.defaultMasterRatio, 0.05'f32, 0.95'f32)
  else:
    DefaultMasterRatio

proc floatingMinWidth*(model: Model): int32 =
  if model.floating.minWidth > 0: model.floating.minWidth else: DefaultFloatingMinWidth

proc floatingMinHeight*(model: Model): int32 =
  if model.floating.minHeight > 0: model.floating.minHeight else: DefaultFloatingMinHeight

proc safeLayoutMode*(stored: int; fallback = Scroller): LayoutMode =
  if stored >= ord(low(LayoutMode)) + 1 and stored <= ord(high(LayoutMode)) + 1:
    LayoutMode(stored - 1)
  else:
    fallback

proc initTagState*(tagId: uint32; layoutMode = Scroller; name = "";
    masterCount = DefaultMasterCount; masterSplitRatio = DefaultMasterRatio): TagState =
  TagState(
    tagId: tagId,
    name: name,
    layoutMode: layoutMode,
    masterCount: max(1, masterCount),
    masterSplitRatio: clamp(masterSplitRatio, 0.05'f32, 0.95'f32)
  )

proc initTagStateForModel*(model: Model; tagId: uint32; layoutMode = Scroller; name = ""): TagState =
  initTagState(tagId, layoutMode, name, model.defaultMasterCount(), model.defaultMasterRatio())

proc defaultColumn*(model: Model; windows: seq[WindowId] = @[]): Column =
  Column(windows: windows, widthProportion: model.defaultColumnWidth())

proc defaultFloatingGeom*(model: Model): Rect =
  let screenW = max(0'i32, model.screenWidth)
  let screenH = max(0'i32, model.screenHeight)
  let xRatio = if model.floating.xRatio > 0: model.floating.xRatio else: DefaultFloatingXRatio
  let yRatio = if model.floating.yRatio > 0: model.floating.yRatio else: DefaultFloatingYRatio
  let widthRatio = if model.floating.widthRatio > 0: model.floating.widthRatio else: DefaultFloatingWidthRatio
  let heightRatio = if model.floating.heightRatio > 0: model.floating.heightRatio else: DefaultFloatingHeightRatio
  let minWidth = model.floatingMinWidth()
  let minHeight = model.floatingMinHeight()
  Rect(
    x: int32(float32(screenW) * clamp(xRatio, 0.0'f32, 1.0'f32)),
    y: int32(float32(screenH) * clamp(yRatio, 0.0'f32, 1.0'f32)),
    w: max(minWidth, int32(float32(screenW) * clampProportion(widthRatio))),
    h: max(minHeight, int32(float32(screenH) * clampProportion(heightRatio)))
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
    model.tags[tagId] = model.initTagStateForModel(tagId, layoutMode)
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
    if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow) and
        (not model.windows.hasKey(tag.focusedWindow) or not model.windows[tag.focusedWindow].isMinimized):
      return tag.focusedWindow
  0

proc recomputeVisibleFocus*(tag: var TagState; model: Model) =
  if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow) and
      model.windows.hasKey(tag.focusedWindow) and not model.windows[tag.focusedWindow].isMinimized:
    return

  tag.focusedWindow = 0
  for col in tag.columns:
    for win in col.windows:
      if not model.windows.hasKey(win) or not model.windows[win].isMinimized:
        tag.focusedWindow = win
        return

proc boundedDimensions*(win: WindowData; w, h: int32): tuple[w, h: int32] =
  result.w = max(0'i32, w)
  result.h = max(0'i32, h)
  if win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if win.minHeight > 0:
    result.h = max(result.h, win.minHeight)
  if win.maxWidth > 0:
    result.w = min(result.w, win.maxWidth)
  if win.maxHeight > 0:
    result.h = min(result.h, win.maxHeight)

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
