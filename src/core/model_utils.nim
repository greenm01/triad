import algorithm, strutils, tables
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

proc defaultWorkspaceCount*(model: Model): uint32 =
  if model.workspaces.defaultCount == 0:
    DefaultWorkspaceCount
  else:
    min(model.workspaces.defaultCount, MaxWorkspaceCount)

proc normalizeWorkspaceCount*(count: uint32): uint32 =
  if count == 0:
    DefaultWorkspaceCount
  else:
    min(count, MaxWorkspaceCount)

proc tagRuleFor*(model: Model; tagId: uint32): tuple[found: bool, rule: TagRule] =
  for rule in model.tagRules:
    if rule.tagId == tagId:
      return (true, rule)
  (false, TagRule())

proc matchesWindowRule*(rule: WindowRule; appId, title: string): bool =
  let appIdMatches = rule.appIdMatch == "" or appId.contains(rule.appIdMatch)
  let titleMatches = rule.titleMatch == "" or title.contains(rule.titleMatch)
  appIdMatches and titleMatches

proc windowKeyboardShortcutsInhibit*(model: Model; appId, title: string): bool =
  for rule in model.windowRules:
    if rule.matchesWindowRule(appId, title):
      return rule.keyboardShortcutsInhibit
  false

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

proc initTagStateForModel*(model: Model; tagId: uint32; layoutMode = Scroller; name = "";
    applyTemplate = true): TagState =
  var effectiveLayout = layoutMode
  var effectiveName = name
  if applyTemplate:
    let tagTemplate = model.tagRuleFor(tagId)
    if tagTemplate.found:
      effectiveLayout = tagTemplate.rule.defaultLayout
      if effectiveName.len == 0:
        effectiveName = tagTemplate.rule.name
  initTagState(tagId, effectiveLayout, effectiveName, model.defaultMasterCount(), model.defaultMasterRatio())

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

proc liveWindows*(tag: TagState; model: Model): seq[WindowId] =
  for col in tag.columns:
    for win in col.windows:
      if model.windows.hasKey(win):
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

proc recomputeVisibleFocus*(tag: var TagState; model: Model) =
  if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow) and
      model.windows.hasKey(tag.focusedWindow) and not model.windows[tag.focusedWindow].isMinimized:
    return

  tag.focusedWindow = 0
  for col in tag.columns:
    for win in col.windows:
      if model.windows.hasKey(win) and not model.windows[win].isMinimized:
        tag.focusedWindow = win
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

proc ensureDefaultWorkspaces*(model: var Model) =
  for tagId in 1'u32 .. model.defaultWorkspaceCount():
    if not model.tags.hasKey(tagId):
      model.tags[tagId] = model.initTagStateForModel(tagId)
  if model.activeTag == 0:
    model.activeTag = 1

proc baseVisibleWorkspaceIds(model: Model): seq[uint32] =
  for tagId in 1'u32 .. model.defaultWorkspaceCount():
    result.add(tagId)
  for tagId in model.tags.keys:
    if tagId > model.defaultWorkspaceCount() and
        (tagId == model.activeTag or model.tags[tagId].liveWindows(model).len > 0):
      result.add(tagId)
  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

proc trailingWorkspaceId*(model: Model): uint32 =
  let ids = model.baseVisibleWorkspaceIds()
  if ids.len == 0:
    return 0
  let last = ids[^1]
  if last == high(uint32):
    return 0
  if model.tags.hasKey(last) and model.tags[last].liveWindows(model).len > 0:
    return last + 1
  0

proc visibleWorkspaceIds*(model: Model): seq[uint32] =
  result = model.baseVisibleWorkspaceIds()
  let trailing = model.trailingWorkspaceId()
  if trailing != 0 and result.find(trailing) == -1:
    result.add(trailing)
    result.sort()

proc compactWorkspaceIndexToTag*(model: Model; index: uint32): uint32 =
  if index == 0:
    return 0
  let ids = model.visibleWorkspaceIds()
  let i = int(index) - 1
  if i >= 0 and i < ids.len:
    return ids[i]
  0

proc workspaceIndexToTag*(model: Model; index: uint32): uint32 =
  if index == 0:
    return 0
  let ids = model.visibleWorkspaceIds()
  if ids.len == 0:
    return 0
  let i = min(int(index) - 1, ids.len - 1)
  ids[i]

proc nextDynamicWorkspaceId*(model: Model): uint32 =
  result = model.defaultWorkspaceCount() + 1
  for tagId in model.tags.keys:
    if tagId >= result:
      result = tagId + 1

proc pruneDynamicWorkspaces*(model: var Model): bool =
  var ids: seq[uint32] = @[]
  let trailing = model.trailingWorkspaceId()
  for tagId in model.tags.keys:
    ids.add(tagId)
  ids.sort()
  for tagId in ids:
    if tagId <= model.defaultWorkspaceCount() or tagId == model.activeTag or tagId == trailing:
      continue
    if model.tags[tagId].liveWindows(model).len > 0:
      continue
    var outputIds: seq[uint32] = @[]
    for outputId, outputTag in model.outputTags.pairs:
      if outputTag == tagId:
        outputIds.add(outputId)
    for outputId in outputIds:
      model.outputTags.del(outputId)
    model.tags.del(tagId)
    result = true

proc lowerWorkspaceFallback*(model: Model; fromTag: uint32): uint32 =
  var ids = model.visibleWorkspaceIds()
  for i in countdown(ids.len - 1, 0):
    let tagId = ids[i]
    if tagId < fromTag and tagId != fromTag:
      return tagId
  if model.defaultWorkspaceCount() > 0:
    let below = if fromTag > 1: fromTag - 1 else: 1'u32
    return min(model.defaultWorkspaceCount(), max(1'u32, below))
  1'u32

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
        model.windows.hasKey(tag.focusedWindow) and not model.windows[tag.focusedWindow].isMinimized:
      return tag.focusedWindow
  0

proc keyboardShortcutsInhibited*(model: Model): bool =
  if model.sessionLocked or model.layerFocusExclusive:
    return false
  let focused = model.focusedOnActiveTag()
  if focused == 0 or not model.windows.hasKey(focused):
    return false
  let win = model.windows[focused]
  win.keyboardShortcutsInhibit and not win.keyboardShortcutsInhibitBypass

proc cleanupStaleTagWindows*(model: var Model): bool =
  if model.windows.len == 0 and model.restoreWindows.len == 0 and model.restoreTagByWindow.len == 0:
    return false

  var updates: seq[(uint32, TagState)] = @[]
  for tagId, tag in model.tags.pairs:
    var nextTag = tag
    var changed = false
    for colIdx in countdown(nextTag.columns.len - 1, 0):
      var winIdx = nextTag.columns[colIdx].windows.len - 1
      while winIdx >= 0:
        let win = nextTag.columns[colIdx].windows[winIdx]
        if not model.windows.hasKey(win) and not model.restoreWindows.hasKey(win) and
            not model.restoreTagByWindow.hasKey(win):
          nextTag.columns[colIdx].windows.delete(winIdx)
          changed = true
        dec winIdx
    nextTag.cleanupColumns()
    let focusedPendingRestore =
      nextTag.focusedWindow != 0 and
      (model.restoreWindows.hasKey(nextTag.focusedWindow) or model.restoreTagByWindow.hasKey(nextTag.focusedWindow))
    if not focusedPendingRestore:
      nextTag.recomputeVisibleFocus(model)
    if changed or nextTag.focusedWindow != tag.focusedWindow:
      updates.add((tagId, nextTag))
      result = true
  for item in updates:
    model.tags[item[0]] = item[1]

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
