import std/[algorithm, options, tables]
import ../state/engine
import daemon_view

type StackBand {.pure.} = enum
  Tiled
  TiledRaised
  TiledFocused
  Floating
  Scratchpad
  FocusedFullscreen
  Overlay
  Global
  Highlight
  Dragged

const MaxParentDepth = 64

proc parentRiverId(model: Model, id: uint32): uint32 =
  let winOpt = model.windowDataForRiverId(id)
  if winOpt.isNone:
    return 0'u32
  uint32(winOpt.get().parentExternalId)

proc isDescendantRiverWindow*(model: Model, child, ancestor: uint32): bool =
  if child == 0 or ancestor == 0 or child == ancestor:
    return false
  var current = child
  var depth = 0
  while current != 0 and depth < MaxParentDepth:
    let parent = model.parentRiverId(current)
    if parent == 0:
      return false
    if parent == ancestor:
      return true
    current = parent
    inc depth
  false

proc windowOrAncestorStackLayer*(model: Model, id: uint32): int =
  if id == 0:
    return 0
  var current = id
  var depth = 0
  while current != 0 and depth < MaxParentDepth:
    let winOpt = model.windowDataForRiverId(current)
    if winOpt.isNone:
      return 0
    let win = winOpt.get()
    if win.isUnmanagedGlobal:
      return 2
    if win.isOverlay:
      result = max(result, 1)
    current = uint32(win.parentExternalId)
    inc depth

proc logicalWindowSortKey(model: Model, id: uint32): uint32 =
  let logicalId = model.windowForRiverId(id)
  if uint32(logicalId) != 0:
    return uint32(logicalId)
  id

proc stackCmp(model: Model, a, b: uint32): int =
  if model.isDescendantRiverWindow(a, b):
    return 1
  if model.isDescendantRiverWindow(b, a):
    return -1
  let aLayer = model.windowOrAncestorStackLayer(a)
  let bLayer = model.windowOrAncestorStackLayer(b)
  if aLayer != bLayer:
    return cmp(aLayer, bLayer)
  cmp(model.logicalWindowSortKey(a), model.logicalWindowSortKey(b))

proc sortStackIds*(model: Model, ids: var seq[uint32]) =
  ## Sorts by stack layer, then window age, keeping children above parents.
  if ids.len < 2:
    return
  for idx in 1 ..< ids.len:
    let item = ids[idx]
    var pos = idx
    while pos > 0 and model.stackCmp(item, ids[pos - 1]) < 0:
      ids[pos] = ids[pos - 1]
      dec pos
    ids[pos] = item

proc ownStackBand(
    model: Model, id, focused, highlighted, dragged, scratchpad: uint32
): StackBand =
  if id == dragged:
    return StackBand.Dragged
  if id == highlighted:
    return StackBand.Highlight
  let layer = model.windowOrAncestorStackLayer(id)
  if layer >= 2:
    return StackBand.Global
  if layer == 1:
    return StackBand.Overlay
  # A window holding focus through one of its children counts as focused.
  let inFocusedTree = id == focused or model.isDescendantRiverWindow(focused, id)
  let winOpt = model.windowDataForRiverId(id)
  let isFullscreen = winOpt.isSome and winOpt.get().isFullscreen
  if isFullscreen and inFocusedTree:
    return StackBand.FocusedFullscreen
  if id == scratchpad:
    return StackBand.Scratchpad
  if winOpt.isSome and winOpt.get().isFloating:
    return StackBand.Floating
  if inFocusedTree:
    return StackBand.TiledFocused
  if isFullscreen or model.effectivelyMaximizedForRiverId(id):
    return StackBand.TiledRaised
  StackBand.Tiled

proc stackOrder*(model: Model, ids: openArray[uint32]): seq[uint32] =
  ## Bottom-to-top stacking for `ids`, which must already be sorted by
  ## `sortStackIds`. Floating windows stay above tiled ones whatever has focus;
  ## among them the most recently focused is on top. A focused child keeps its
  ## parent focused for stacking, so a fullscreen app stays above other floating
  ## windows while its dialog has focus. A child window stays above its parent
  ## and is never placed in a lower band than it.
  let overlayActive = model.overviewActive or model.recentWindowsActive
  let highlighted =
    if overlayActive:
      model.highlightRiverId()
    else:
      0'u32
  let focused = model.activeFocusRiverId()
  let dragged = model.draggedPointerRiverId()
  let scratchpad =
    if model.scratchpadVisible():
      model.visibleScratchpadRiverId()
    else:
      0'u32

  var focusRank = initTable[uint32, int]()
  var rank = 0
  for winId in model.focusHistoryIds():
    inc rank
    focusRank[model.riverIdForWindow(winId)] = rank

  var position = initTable[uint32, int]()
  for idx, id in ids:
    position[id] = idx

  var bands = newSeq[StackBand](ids.len)
  var roots = newSeq[uint32](ids.len)
  var groupRank = initTable[uint32, int]()
  for idx, id in ids:
    bands[idx] = model.ownStackBand(id, focused, highlighted, dragged, scratchpad)
    roots[idx] = id
    let parent = model.parentRiverId(id)
    if parent != 0 and position.hasKey(parent):
      let parentIdx = position[parent]
      if parentIdx < idx:
        bands[idx] = max(bands[idx], bands[parentIdx])
        roots[idx] = roots[parentIdx]
    groupRank[roots[idx]] =
      max(groupRank.getOrDefault(roots[idx]), focusRank.getOrDefault(id))

  var order = newSeq[int](ids.len)
  for idx in 0 ..< ids.len:
    order[idx] = idx
  order.sort(
    proc(a, b: int): int =
      result = cmp(bands[a], bands[b])
      if result == 0 and bands[a] == StackBand.Floating:
        result = cmp(groupRank[roots[a]], groupRank[roots[b]])
      if result == 0:
        result = cmp(a, b)
  )
  for idx in order:
    result.add(ids[idx])
