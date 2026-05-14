import std/[math, options, strutils, tables]
import ../state/engine
import ../types/core as core_types
import ../types/runtime_values as rv

const RecentTickMs = 16'i32
const RecentPreviewGap = 16'i32
const RecentPreviewStrut = 192'i32
const RecentPreviewMinSize = 16'i32

type RecentWindowPreview* = object
  winId*: core_types.WindowId
  riverId*: rv.WindowId
  geom*: rv.Rect
  title*: string
  appId*: string
  selected*: bool

proc recentWindowPreviews*(model: Model, screen: rv.Rect): seq[RecentWindowPreview]

proc recentPrimaryScreen(model: Model): rv.Rect =
  if model.primaryOutput != NullOutputId:
    let outputOpt = model.outputData(model.primaryOutput)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return rv.Rect(
          x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH
        )
      return rv.Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  rv.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc recentWindowsVisible*(model: Model): bool =
  model.recentWindowsActive and
    model.recentWindowsOpenElapsedMs >= model.recentWindows.openDelayMs

proc recentCurrentFocus(model: Model): core_types.WindowId =
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return scratchpad
  if model.activeTag == NullTagId:
    return NullWindowId
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().focusedWindow
  NullWindowId

proc recentTagForWindow(model: Model, winId: core_types.WindowId): core_types.TagId =
  if model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, winId).isSome:
    return model.activeTag
  let position = model.firstWindowPosition(winId)
  if position.found:
    return position.tagId
  NullTagId

proc windowOnActiveRecentOutput(model: Model, winId: core_types.WindowId): bool =
  let targetOutput =
    if model.activeOutput != NullOutputId: model.activeOutput else: model.primaryOutput
  if targetOutput == NullOutputId:
    return true
  for tagId, candidate, _ in model.placementsWithId():
    if candidate == winId and
        model.tagOutputs.getOrDefault(tagId, NullOutputId) == targetOutput:
      return true
  false

proc recentWindowFocusable(model: Model, winId: core_types.WindowId): bool =
  let winOpt = model.windowData(winId)
  winOpt.isSome and not winOpt.get().isUnmanagedGlobal and not winOpt.get().isMinimized and
    winOpt.get().windowAdmitted() and model.recentTagForWindow(winId) != NullTagId

proc recentMatchesScope(
    model: Model, winId: core_types.WindowId, scope: RecentWindowScope
): bool =
  case scope
  of RecentWindowScope.All:
    true
  of RecentWindowScope.Workspace:
    model.activeTag != NullTagId and
      model.placementForWindowOnTag(model.activeTag, winId).isSome
  of RecentWindowScope.Output:
    model.windowOnActiveRecentOutput(winId)

proc recentMatchesFilter(
    model: Model, winId: core_types.WindowId, filter: RecentWindowFilter, appId: string
): bool =
  if filter == RecentWindowFilter.All:
    return true
  if appId.len == 0:
    return false
  let winOpt = model.windowData(winId)
  winOpt.isSome and winOpt.get().appId == appId

proc recentWindowCandidates*(
    model: Model,
    scope = RecentWindowScope.All,
    filter = RecentWindowFilter.All,
    appId = "",
): seq[core_types.WindowId] =
  var seen: seq[core_types.WindowId] = @[]
  for i in countdown(model.recentWindowHistory.len - 1, 0):
    let winId = model.recentWindowHistory[i]
    if seen.find(winId) == -1 and model.recentWindowFocusable(winId) and
        model.recentMatchesScope(winId, scope) and
        model.recentMatchesFilter(winId, filter, appId):
      result.add(winId)
      seen.add(winId)
  for winId, _ in model.windowsWithId():
    if seen.find(winId) == -1 and model.recentWindowFocusable(winId) and
        model.recentMatchesScope(winId, scope) and
        model.recentMatchesFilter(winId, filter, appId):
      result.add(winId)
      seen.add(winId)

proc currentRecentCandidates*(model: Model): seq[core_types.WindowId] =
  model.recentWindowCandidates(
    model.recentWindowsScope, model.recentWindowsFilter, model.recentWindowsAppIdFilter
  )

proc selectedRecentWindow*(model: Model): core_types.WindowId =
  let candidates = model.currentRecentCandidates()
  if candidates.find(model.recentWindowsSelectedWindow) != -1:
    return model.recentWindowsSelectedWindow
  if candidates.len > 0:
    return candidates[0]
  NullWindowId

proc appIdForWindow(model: Model, winId: core_types.WindowId): string =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return winOpt.get().appId
  ""

proc setRecentFilterFromCommand(
    model: var Model, filter: RecentWindowFilter, filterSet: bool
): bool =
  if not filterSet:
    return false
  let appId =
    if filter == RecentWindowFilter.AppId:
      model.appIdForWindow(model.selectedRecentWindow())
    else:
      ""
  model.setRecentWindowsFilter(filter, appId)

proc selectNearestRecent(model: var Model, candidates: seq[core_types.WindowId]): bool =
  if candidates.len == 0:
    return model.closeRecentWindows()
  if candidates.find(model.recentWindowsSelectedWindow) == -1:
    return model.setRecentWindowsSelected(candidates[0])
  false

proc advanceRecentSelection*(model: var Model, direction: RecentWindowDirection): bool =
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return model.closeRecentWindows()
  var idx = candidates.find(model.selectedRecentWindow())
  if idx == -1:
    idx = 0
  else:
    case direction
    of RecentWindowDirection.Forward:
      idx = (idx + 1) mod candidates.len
    of RecentWindowDirection.Backward:
      idx = (idx + candidates.len - 1) mod candidates.len
  model.setRecentWindowsSelected(candidates[idx])

proc openOrAdvanceRecentWindow*(
    model: var Model,
    direction: RecentWindowDirection,
    scope: RecentWindowScope,
    scopeSet: bool,
    filter: RecentWindowFilter,
    filterSet: bool,
): bool =
  if not model.recentWindows.enabled or model.sessionLocked or model.layerFocusExclusive:
    return false
  if model.pendingRecentFocusWindow != NullWindowId:
    discard model.commitRecentFocus(model.pendingRecentFocusWindow)

  if not model.recentWindowsActive:
    let nextScope =
      if scopeSet:
        scope
      elif model.recentWindowsPreviousScope != RecentWindowScope.All:
        model.recentWindowsPreviousScope
      else:
        RecentWindowScope.All
    discard model.setRecentWindowsScope(nextScope)
    let active = model.recentCurrentFocus()
    let nextFilter = if filterSet: filter else: RecentWindowFilter.All
    let appId =
      if nextFilter == RecentWindowFilter.AppId:
        model.appIdForWindow(active)
      else:
        ""
    discard model.setRecentWindowsFilter(nextFilter, appId)
    let candidates = model.currentRecentCandidates()
    if candidates.len == 0:
      return false
    discard model.setRecentWindowsSelected(candidates[0])
    model.recentWindowsOpenElapsedMs = 0
    discard model.setRecentWindowsActive(true)
    discard model.setHotkeyOverlayOpen(false)
    discard model.setOverviewActive(false)
    discard model.setOverviewWorkspacePreviewsActive(false)
    discard model.clearOverviewSelection()
    if active != NullWindowId or direction == RecentWindowDirection.Backward:
      discard model.advanceRecentSelection(direction)
    return true

  result = model.setRecentFilterFromCommand(filter, filterSet)
  if scopeSet:
    result = model.setRecentWindowsScope(scope) or result
    result = model.selectNearestRecent(model.currentRecentCandidates()) or result
  result = model.advanceRecentSelection(direction) or result

proc confirmedRecentWindow*(model: var Model): core_types.WindowId =
  if not model.recentWindowsActive:
    return NullWindowId
  result = model.selectedRecentWindow()
  discard model.closeRecentWindows()

proc cancelRecentWindows*(model: var Model): bool =
  model.closeRecentWindows()

proc selectFirstRecentWindow*(model: var Model): bool =
  if not model.recentWindowsActive:
    return false
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return model.closeRecentWindows()
  model.setRecentWindowsSelected(candidates[0])

proc selectLastRecentWindow*(model: var Model): bool =
  if not model.recentWindowsActive:
    return false
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return model.closeRecentWindows()
  model.setRecentWindowsSelected(candidates[^1])

proc cycleRecentWindowScope*(model: var Model): bool =
  if not model.recentWindowsActive:
    return false
  let next =
    case model.recentWindowsScope
    of RecentWindowScope.All: RecentWindowScope.Workspace
    of RecentWindowScope.Workspace: RecentWindowScope.Output
    of RecentWindowScope.Output: RecentWindowScope.All
  result = model.setRecentWindowsScope(next)
  result = model.selectNearestRecent(model.currentRecentCandidates()) or result

proc setRecentWindowScopeCommand*(model: var Model, scope: RecentWindowScope): bool =
  if not model.recentWindowsActive:
    return false
  result = model.setRecentWindowsScope(scope)
  result = model.selectNearestRecent(model.currentRecentCandidates()) or result

proc recentWindowAt*(model: Model, x, y: int32): core_types.WindowId =
  if not model.recentWindowsVisible():
    return NullWindowId
  for preview in model.recentWindowPreviews(model.recentPrimaryScreen()):
    if x >= preview.geom.x and y >= preview.geom.y and
        x < preview.geom.x + preview.geom.w and y < preview.geom.y + preview.geom.h:
      return preview.winId
  NullWindowId

proc selectRecentWindowAt*(model: var Model, x, y: int32): bool =
  let winId = model.recentWindowAt(x, y)
  if winId == NullWindowId:
    if model.recentWindowsPointerSelectedWindow != NullWindowId:
      model.recentWindowsPointerSelectedWindow = NullWindowId
      return true
    return false
  model.recentWindowsPointerSelectedWindow = winId
  model.setRecentWindowsSelected(winId)

proc closeCurrentRecentWindow*(model: var Model): core_types.WindowId =
  if not model.recentWindowsActive:
    return NullWindowId
  result = model.selectedRecentWindow()
  if result == NullWindowId:
    return
  discard model.removeFocusHistoryRef(result)
  discard model.advanceRecentSelection(RecentWindowDirection.Forward)

proc tickRecentWindows*(model: var Model): bool =
  if model.pendingRecentFocusWindow != NullWindowId:
    model.pendingRecentFocusElapsedMs += RecentTickMs
    if model.pendingRecentFocusElapsedMs >= model.recentWindows.debounceMs:
      result = model.commitRecentFocus(model.pendingRecentFocusWindow) or result
  if model.recentWindowsActive:
    let wasVisible = model.recentWindowsVisible()
    if model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
      model.recentWindowsOpenElapsedMs = min(
        model.recentWindows.openDelayMs, model.recentWindowsOpenElapsedMs + RecentTickMs
      )
    result = (wasVisible != model.recentWindowsVisible()) or result
    result = model.selectNearestRecent(model.currentRecentCandidates()) or result

proc recentWindowPreviews*(model: Model, screen: rv.Rect): seq[RecentWindowPreview] =
  if not model.recentWindowsVisible():
    return
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return

  var widths: seq[int32] = @[]
  var heights: seq[int32] = @[]
  var totalW = 0'i32
  let maxHeight = max(RecentPreviewMinSize, model.recentWindows.previews.maxHeight)
  let maxScale = max(0.01'f32, model.recentWindows.previews.maxScale)
  for winId in candidates:
    let winOpt = model.windowData(winId)
    var sourceW = 800'i32
    var sourceH = 600'i32
    if winOpt.isSome:
      sourceW = max(RecentPreviewMinSize, winOpt.get().actualW)
      sourceH = max(RecentPreviewMinSize, winOpt.get().actualH)
    let scale = min(maxScale, float32(maxHeight) / float32(max(1'i32, sourceH)))
    let w = max(RecentPreviewMinSize, int32(round(float32(sourceW) * scale)))
    let h = max(RecentPreviewMinSize, int32(round(float32(sourceH) * scale)))
    widths.add(w)
    heights.add(h)
    totalW += w
  totalW += int32(max(0, candidates.len - 1)) * RecentPreviewGap

  let selected = model.selectedRecentWindow()
  var selectedIdx = candidates.find(selected)
  if selectedIdx == -1:
    selectedIdx = 0
  var selectedCenter = 0'i32
  for idx in 0 ..< selectedIdx:
    selectedCenter += widths[idx] + RecentPreviewGap
  selectedCenter += widths[selectedIdx] div 2

  var startX = screen.x + screen.w div 2 - selectedCenter
  if totalW > screen.w:
    startX = min(screen.x + RecentPreviewStrut, startX)
    startX = max(screen.x + screen.w - totalW - RecentPreviewStrut, startX)
  else:
    startX = screen.x + (screen.w - totalW) div 2

  var x = startX
  for idx, winId in candidates:
    let winOpt = model.windowData(winId)
    let title =
      if winOpt.isSome and winOpt.get().title.strip().len > 0:
        winOpt.get().title
      elif winOpt.isSome and winOpt.get().appId.strip().len > 0:
        winOpt.get().appId
      else:
        "Window " & $uint32(winId)
    let h = heights[idx]
    result.add(
      RecentWindowPreview(
        winId: winId,
        riverId:
          if winOpt.isSome:
            rv.WindowId(uint32(winOpt.get().externalId))
          else:
            0'u32,
        geom: rv.Rect(
          x: x, y: screen.y + max(0'i32, (screen.h - h) div 2), w: widths[idx], h: h
        ),
        title: title,
        appId:
          if winOpt.isSome:
            winOpt.get().appId
          else:
            "",
        selected: winId == selected,
      )
    )
    x += widths[idx] + RecentPreviewGap

proc recentWindowLayoutInstructions*(
    model: Model, screen: rv.Rect
): seq[rv.RenderInstruction] =
  for preview in model.recentWindowPreviews(screen):
    if preview.riverId != 0:
      result.add(rv.RenderInstruction(windowId: preview.riverId, geom: preview.geom))
