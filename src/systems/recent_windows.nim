import std/[math, options, strutils, tables]
import ../state/engine
import ../types/core as core_types
import ../types/projection_values as rv
import ../types/system_views

export system_views

const RecentPreviewGap = 16'i32
const RecentPreviewStrut = 192'i32
const RecentPreviewMinSize = 16'i32
const RecentPreviewBorder = 2'i32
const RecentPreviewFallbackW = 800'i32
const RecentPreviewFallbackH = 600'i32

proc recentWindowPreviews*(model: Model, screen: rv.Rect): seq[RecentWindowPreview]

proc recentOutputScreen(model: Model, outputId: core_types.OutputId): rv.Rect =
  if outputId != NullOutputId:
    let outputOpt = model.outputData(outputId)
    if outputOpt.isSome:
      let output = outputOpt.get()
      if output.hasUsable and output.usableW > 0 and output.usableH > 0:
        return rv.Rect(
          x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH
        )
      if output.w > 0 and output.h > 0:
        return rv.Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  rv.Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc recentPrimaryScreen(model: Model): rv.Rect =
  if model.activeOutput != NullOutputId and model.outputData(model.activeOutput).isSome:
    return model.recentOutputScreen(model.activeOutput)
  let outputId = model.workspaceOutput(model.activeTag)
  if outputId != NullOutputId:
    return model.recentOutputScreen(outputId)
  model.recentOutputScreen(model.primaryOutput)

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

proc selectRecentStartupWindow(
    model: var Model,
    candidates: seq[core_types.WindowId],
    active: core_types.WindowId,
    direction: RecentWindowDirection,
): bool =
  var idx = 0
  if active != NullWindowId and candidates.find(active) != -1:
    idx = candidates.find(active)
    case direction
    of RecentWindowDirection.Forward:
      idx = (idx + 1) mod candidates.len
    of RecentWindowDirection.Backward:
      idx = (idx + candidates.len - 1) mod candidates.len
  else:
    if direction == RecentWindowDirection.Backward:
      idx = candidates.len - 1
  model.setRecentWindowsSelected(candidates[idx])

proc advanceRecentSelection*(model: var Model, direction: RecentWindowDirection): bool =
  result = model.unfreezeRecentWindowsView()
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
  result = model.setRecentWindowsSelected(candidates[idx]) or result

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
    discard model.unfreezeRecentWindowsView()
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
    model.recentWindowsOpenElapsedMs = 0
    discard model.setRecentWindowsActive(true)
    discard model.setHotkeyOverlayOpen(false)
    discard model.setOverviewActive(false)
    discard model.setOverviewWorkspacePreviewsActive(false)
    discard model.clearOverviewSelection()
    discard model.selectRecentStartupWindow(candidates, active, direction)
    return true

  result = model.setRecentFilterFromCommand(filter, filterSet)
  if scopeSet:
    result = model.unfreezeRecentWindowsView() or result
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
  result = model.unfreezeRecentWindowsView()
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return model.closeRecentWindows()
  result = model.setRecentWindowsSelected(candidates[0]) or result

proc selectLastRecentWindow*(model: var Model): bool =
  if not model.recentWindowsActive:
    return false
  result = model.unfreezeRecentWindowsView()
  let candidates = model.currentRecentCandidates()
  if candidates.len == 0:
    return model.closeRecentWindows()
  result = model.setRecentWindowsSelected(candidates[^1]) or result

proc cycleRecentWindowScope*(model: var Model): bool =
  if not model.recentWindowsActive:
    return false
  result = model.unfreezeRecentWindowsView()
  let next =
    case model.recentWindowsScope
    of RecentWindowScope.All: RecentWindowScope.Workspace
    of RecentWindowScope.Workspace: RecentWindowScope.Output
    of RecentWindowScope.Output: RecentWindowScope.All
  result = model.setRecentWindowsScope(next) or result
  result = model.selectNearestRecent(model.currentRecentCandidates()) or result

proc setRecentWindowScopeCommand*(model: var Model, scope: RecentWindowScope): bool =
  if not model.recentWindowsActive:
    return false
  result = model.unfreezeRecentWindowsView()
  result = model.setRecentWindowsScope(scope) or result
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
  let previews = model.recentWindowPreviews(model.recentPrimaryScreen())
  let winId = model.recentWindowAt(x, y)
  if winId == NullWindowId:
    if model.recentWindowsPointerSelectedWindow != NullWindowId:
      model.recentWindowsPointerSelectedWindow = NullWindowId
      return true
    return false
  if not model.recentWindowsViewFrozen and previews.len > 0:
    result = model.freezeRecentWindowsView(previews[0].geom.x) or result
  model.recentWindowsPointerSelectedWindow = winId
  result = model.setRecentWindowsSelected(winId) or result

proc closeCurrentRecentWindow*(model: var Model): core_types.WindowId =
  if not model.recentWindowsActive:
    return NullWindowId
  result = model.selectedRecentWindow()
  if result == NullWindowId:
    return
  discard model.removeFocusHistoryRef(result)
  discard model.advanceRecentSelection(RecentWindowDirection.Forward)

proc tickRecentWindows*(model: var Model, elapsedMs = DefaultFrameIntervalMs): bool =
  let tickMs = if elapsedMs > 0: elapsedMs else: DefaultFrameIntervalMs
  if model.pendingRecentFocusWindow != NullWindowId:
    model.pendingRecentFocusElapsedMs += tickMs
    if model.pendingRecentFocusElapsedMs >= model.recentWindows.debounceMs:
      result = model.commitRecentFocus(model.pendingRecentFocusWindow) or result
  if model.recentWindowsActive:
    let wasVisible = model.recentWindowsVisible()
    if model.recentWindowsOpenElapsedMs < model.recentWindows.openDelayMs:
      model.recentWindowsOpenElapsedMs =
        min(model.recentWindows.openDelayMs, model.recentWindowsOpenElapsedMs + tickMs)
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
  var stripW = 0'i32
  let maxHeight = max(RecentPreviewMinSize, model.recentWindows.previews.maxHeight)
  let maxScale = max(0.01'f32, model.recentWindows.previews.maxScale)
  let outputMaxH = max(RecentPreviewMinSize, int32(round(float32(screen.h) * maxScale)))
  let boundedMaxH = min(maxHeight, outputMaxH)
  let aspectMaxW =
    if screen.h > 0:
      max(
        RecentPreviewMinSize,
        int32(round(float32(boundedMaxH * screen.w) / float32(screen.h))),
      )
    else:
      boundedMaxH
  for winId in candidates:
    let winOpt = model.windowData(winId)
    var sourceW = RecentPreviewFallbackW
    var sourceH = RecentPreviewFallbackH
    if winOpt.isSome and winOpt.get().actualW > RecentPreviewMinSize * 2 and
        winOpt.get().actualH > RecentPreviewMinSize * 2:
      sourceW = max(RecentPreviewMinSize, winOpt.get().actualW)
      sourceH = max(RecentPreviewMinSize, winOpt.get().actualH)
    let minScale =
      min(1'f32, float32(RecentPreviewMinSize) / float32(max(sourceW, sourceH)))
    let thumbScale = min(
      min(
        float32(aspectMaxW) / float32(sourceW), float32(boundedMaxH) / float32(sourceH)
      ),
      maxScale,
    )
    let scale = max(minScale, thumbScale)
    let w = max(RecentPreviewMinSize, int32(round(float32(sourceW) * scale)))
    let h = max(RecentPreviewMinSize, int32(round(float32(sourceH) * scale)))
    widths.add(w)
    heights.add(h)
    stripW += w
  let chromePad =
    max(0'i32, model.recentWindows.highlight.padding) + RecentPreviewBorder
  let previewGap = chromePad * 2 + RecentPreviewGap
  stripW += int32(max(0, candidates.len - 1)) * previewGap

  let selected = model.selectedRecentWindow()
  var selectedIdx = candidates.find(selected)
  if selectedIdx == -1:
    selectedIdx = 0
  var selectedCenter = 0'i32
  for idx in 0 ..< selectedIdx:
    selectedCenter += widths[idx] + previewGap
  selectedCenter += widths[selectedIdx] div 2

  var startX = screen.x + screen.w div 2 - selectedCenter
  if model.recentWindowsViewFrozen:
    startX = model.recentWindowsFrozenStartX
  elif stripW > screen.w:
    startX = min(screen.x + RecentPreviewStrut, startX)
    startX = max(screen.x + screen.w - stripW - RecentPreviewStrut, startX)
  else:
    startX = screen.x + (screen.w - stripW) div 2

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
            uint32(uint32(winOpt.get().externalId))
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
    x += widths[idx] + previewGap

proc recentWindowLayoutInstructions*(
    model: Model, screen: rv.Rect
): seq[rv.RenderInstruction] =
  for preview in model.recentWindowPreviews(screen):
    if preview.riverId != 0:
      result.add(rv.RenderInstruction(windowId: preview.riverId, geom: preview.geom))
