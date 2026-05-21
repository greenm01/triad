import std/[algorithm, options, tables]
import protocols/river/client as river
import ../core/render_visibility
import ../state/engine
import ../systems/[daemon_view, layout_projection, recent_windows, window_rules]
import ../types/projection_values
import ../types/runtime_values
import ../utils/overview_hit_test
import protocol_surface_runtime, protocol_surfaces, state, wayland_helpers
from ../types/core import NullOutputId, WindowId

const
  RiverEdgeBottom* = 2'u32
  RiverEdgeRight* = 8'u32
  RiverPresentationVsync = 0'u32
  RiverPresentationAsync = 1'u32

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

template surfaceTable(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.surfaces

template ownedShellSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.ownedShellSurfaceId

template overviewSurfaceByOutput(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.overviewSurfaceByOutput

template recentWindowsSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.recentWindowsSurfaceId

template recentWindowsChromeSurfaceId(daemon: TriadDaemon): untyped =
  daemon.protocolSurfaceRuntime.recentWindowsChromeSurfaceId

proc applyBorder(win: ptr RiverWindowV1, state: RenderWindowState) =
  let color =
    if state.focused:
      premulColor(state.borderActiveColor)
    else:
      premulColor(state.borderInactiveColor)
  win.setBorders(
    state.borderEdges, state.borderWidth, color.r, color.g, color.b, color.a
  )

proc supportedCapabilities*(model: Model): uint32 =
  const
    RiverCapabilityFullscreen = 4'u32
    RiverCapabilityMaximize = 2'u32
    RiverCapabilityMinimize = 8'u32
    RiverCapabilityWindowMenu = 1'u32
    RiverBaseCapabilities =
      RiverCapabilityFullscreen or RiverCapabilityMaximize or RiverCapabilityMinimize

  result = RiverBaseCapabilities
  if model.windowMenuCommand.len > 0:
    result = result or RiverCapabilityWindowMenu

proc riverPresentationMode*(mode: PresentationMode): uint32 =
  case mode
  of PresentationMode.PresentationAsync: RiverPresentationAsync
  else: RiverPresentationVsync

proc configuredPresentationMode*(model: Model): uint32 =
  model.effectivePresentationMode().mode.riverPresentationMode()

proc hasPresentationPreference*(model: Model): bool =
  model.effectivePresentationMode().hasPreference

proc isDescendantRiverWindow(daemon: TriadDaemon, child, ancestor: uint32): bool =
  if child == 0 or ancestor == 0 or child == ancestor:
    return false
  var current = child
  var depth = 0
  while current != 0 and depth < 64:
    let winOpt = daemon.currentModel.windowDataForRiverId(current)
    if winOpt.isNone:
      return false
    let parent = uint32(uint32(winOpt.get().parentExternalId))
    if parent == 0:
      return false
    if parent == ancestor:
      return true
    current = parent
    inc depth
  false

proc logicalWindowSortKey(daemon: TriadDaemon, id: uint32): uint32 =
  let logicalId = daemon.currentModel.windowForRiverId(id)
  if uint32(logicalId) != 0:
    return uint32(logicalId)
  uint32(id)

proc windowOrAncestorStackLayer(daemon: TriadDaemon, id: uint32): int =
  if id == 0:
    return 0
  var current = id
  var depth = 0
  while current != 0 and depth < 64:
    let winOpt = daemon.currentModel.windowDataForRiverId(current)
    if winOpt.isNone:
      return 0
    let win = winOpt.get()
    if win.isUnmanagedGlobal:
      return 2
    if win.isOverlay:
      result = max(result, 1)
    let parent = uint32(uint32(win.parentExternalId))
    if parent == 0:
      return
    current = parent
    inc depth

proc desiredStackCmp(daemon: TriadDaemon, a, b: uint32): int =
  if daemon.isDescendantRiverWindow(a, b):
    return 1
  if daemon.isDescendantRiverWindow(b, a):
    return -1
  let aLayer = daemon.windowOrAncestorStackLayer(a)
  let bLayer = daemon.windowOrAncestorStackLayer(b)
  if aLayer != bLayer:
    return cmp(aLayer, bLayer)
  cmp(daemon.logicalWindowSortKey(a), daemon.logicalWindowSortKey(b))

proc orderedDesiredIds*(daemon: TriadDaemon): seq[uint32] =
  for id in daemon.desiredPlacements.keys:
    if daemon.desiredPlacementOrder.find(id) == -1:
      result.add(id)
  for id in daemon.desiredPlacementOrder:
    if daemon.desiredPlacements.hasKey(id) and result.find(id) == -1:
      result.add(id)
  result.sort(
    proc(a, b: uint32): int =
      daemon.desiredStackCmp(a, b)
  )

proc orderedDesiredInstructions*(daemon: TriadDaemon): seq[RenderInstruction] =
  proc desiredInstruction(id: uint32): RenderInstruction =
    result = RenderInstruction(windowId: id, geom: daemon.desiredPlacements[id])
    if daemon.desiredPlacementClips.hasKey(id):
      result.clipSet = true
      result.clip = daemon.desiredPlacementClips[id]

  let highlighted =
    if daemon.currentModel.overviewActive or daemon.currentModel.recentWindowsActive:
      daemon.currentModel.highlightRiverId()
    else:
      0'u32
  for id in daemon.orderedDesiredIds():
    if id != highlighted:
      result.add(desiredInstruction(id))
  if highlighted != 0 and daemon.desiredPlacements.hasKey(highlighted):
    result.add(desiredInstruction(highlighted))

proc renderOrderKey(daemon: TriadDaemon, ids: seq[uint32]): seq[uint32] =
  let highlighted = daemon.currentModel.highlightRiverId()
  result.add(highlighted)
  result.add(daemon.currentModel.visibleScratchpadRiverId())
  result.add(daemon.ownedShellSurfaceId)
  for outputId in daemon.currentModel.sortedOutputIdsByExternal():
    result.add(daemon.overviewSurfaceByOutput.getOrDefault(outputId, 0'u32))
  result.add(daemon.recentWindowsSurfaceId)
  result.add(daemon.recentWindowsChromeSurfaceId)
  result.add(if daemon.currentModel.overviewActive: 1'u32 else: 0'u32)
  result.add(if daemon.currentModel.recentWindowsVisible(): 1'u32 else: 0'u32)
  for id in ids:
    let visibleScratchpad = daemon.currentModel.visibleScratchpadRiverId()
    let isScratchpad =
      daemon.currentModel.isScratchpadVisible and visibleScratchpad == id
    let winOpt = daemon.currentModel.windowDataForRiverId(id)
    let isFloating = winOpt.isSome and winOpt.get().isFloating
    let isFullscreen = winOpt.isSome and winOpt.get().isFullscreen
    let isMaximized = daemon.currentModel.effectivelyMaximizedForRiverId(id)
    var flags = uint32(daemon.windowOrAncestorStackLayer(id) shl 4)
    if isScratchpad:
      flags = flags or 1'u32
    if isFloating:
      flags = flags or 2'u32
    if isFullscreen:
      flags = flags or 4'u32
    if isMaximized:
      flags = flags or 8'u32
    if id == highlighted:
      flags = flags or 64'u32
    result.add(id)
    result.add(flags)

proc overviewWindowAtPointer*(daemon: TriadDaemon, seat: ptr RiverSeatV1): uint32 =
  if not daemon.currentModel.overviewActive or seat == nil:
    return 0
  let seatId = seat.id()
  if not daemon.pointerPositionBySeat.hasKey(seatId):
    return 0
  let point = daemon.pointerPositionBySeat[seatId]
  overviewHitTest(daemon.orderedDesiredInstructions(), point.x, point.y)

proc placementHonorsMinimums(daemon: TriadDaemon, id: uint32): bool =
  if daemon.currentModel.overviewActive or daemon.currentModel.recentWindowsActive:
    return false
  let winOpt = daemon.currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return true
  let win = winOpt.get()
  let scratchpad =
    daemon.currentModel.isScratchpadVisible and
    daemon.currentModel.visibleScratchpadRiverId() == id
  win.isFloating or win.isFullscreen or scratchpad

proc placementNeedsCellClip(daemon: TriadDaemon, id: uint32, geom: Rect): bool =
  let winOpt = daemon.currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if not daemon.currentModel.overviewActive and
      not daemon.currentModel.recentWindowsActive:
    let scratchpad =
      daemon.currentModel.isScratchpadVisible and
      daemon.currentModel.visibleScratchpadRiverId() == id
    if win.isFloating or win.isFullscreen or scratchpad:
      return false
  win.needsCellClip(geom.w, geom.h)

proc recordDesiredPlacement*(daemon: var TriadDaemon, instr: RenderInstruction) =
  if daemon.desiredPlacements.hasKey(instr.windowId):
    let existingIdx = daemon.desiredPlacementOrder.find(instr.windowId)
    if existingIdx != -1:
      daemon.desiredPlacementOrder.delete(existingIdx)
  daemon.desiredPlacementOrder.add(instr.windowId)
  daemon.desiredPlacements[instr.windowId] = instr.geom
  if instr.clipSet:
    daemon.desiredPlacementClips[instr.windowId] = instr.clip
  else:
    daemon.desiredPlacementClips.del(instr.windowId)

proc recordDesiredPlacements*(
    daemon: var TriadDaemon, instructions: seq[RenderInstruction]
) =
  daemon.desiredPlacements.clear()
  daemon.desiredPlacementClips.clear()
  daemon.desiredPlacementOrder.setLen(0)
  for instr in instructions:
    daemon.recordDesiredPlacement(instr)

proc proposeDesiredDimensions*(
    daemon: var TriadDaemon, instructions: seq[RenderInstruction]
) =
  daemon.recordDesiredPlacements(instructions)
  for instr in instructions:
    if daemon.windowPointers.hasKey(instr.windowId):
      var geom = instr.geom
      let proposal = daemon.currentModel.proposalDimensionsForRiverId(
        instr.windowId, geom.w, geom.h, daemon.placementHonorsMinimums(instr.windowId)
      )
      geom.w = proposal.w
      geom.h = proposal.h
      daemon.windowPointers[instr.windowId].proposeDimensions(
        max(0'i32, geom.w), max(0'i32, geom.h)
      )

proc applyVisibility(
    win: ptr RiverWindowV1,
    visibility: RenderVisibility,
    forceClip: bool,
    borderWidth: int32,
) =
  if visibility.visible:
    win.show()
    if visibility.clipped or forceClip:
      let clips = visibility.renderClipBoxes(borderWidth)
      win.setClipBox(clips.windowX, clips.windowY, clips.windowW, clips.windowH)
      win.setContentClipBox(
        clips.contentX, clips.contentY, clips.contentW, clips.contentH
      )
    else:
      win.setClipBox(0, 0, 0, 0)
      win.setContentClipBox(0, 0, 0, 0)
  else:
    win.hide()

proc applyHiddenRenderWindowState(win: ptr RiverWindowV1) =
  # River border state is sticky; clear it before hiding a formerly focused window.
  win.setBorders(0'u32, 0'i32, 0'u32, 0'u32, 0'u32, 0'u32)
  win.hide()

proc desiredRenderWindowState*(
    daemon: TriadDaemon, id: uint32, geom, visibilityBounds: Rect, clipSet: bool
): RenderWindowState =
  let logicalId = daemon.currentModel.windowForRiverId(id)
  let focused = daemon.currentModel.windowRenderFocused(id)
  let renderBorder = daemon.currentModel.renderWindowBorder(logicalId, focused)
  let visibility =
    renderVisibility(geom, visibilityBounds, max(renderBorder.width * 2, 4'i32))
  RenderWindowState(
    visible: visibility.visible,
    geom: geom,
    clipSet: clipSet,
    clip: visibilityBounds,
    forceClip:
      clipSet or daemon.currentModel.windowClipToGeometry(logicalId) or
      daemon.placementNeedsCellClip(id, geom),
    borderWidth: renderBorder.width,
    renderBorderWidth: renderBorder.width,
    borderActiveColor: renderBorder.activeColor,
    borderInactiveColor: renderBorder.inactiveColor,
    borderEdges: visibility.borderEdges,
    focused: focused,
  )

proc desiredVisibilityBounds(daemon: TriadDaemon, id: uint32): Rect =
  if daemon.currentModel.overviewActive or daemon.currentModel.recentWindowsActive:
    return daemon.currentModel.activeWorkspaceScreen()
  let logicalId = daemon.currentModel.windowForRiverId(id)
  if uint32(logicalId) != 0:
    if daemon.currentModel.isScratchpadVisible and
        daemon.currentModel.visibleScratchpadRiverId() == id:
      return daemon.currentModel.activeWorkspaceScreen()
    let position = daemon.currentModel.firstWindowPosition(logicalId)
    if position.found:
      let outputId = daemon.currentModel.workspaceOutput(position.tagId)
      if outputId != NullOutputId:
        return daemon.currentModel.outputScreen(outputId)
  daemon.currentModel.activeWorkspaceScreen()

proc applyRenderWindowState(
    daemon: TriadDaemon,
    id: uint32,
    win: ptr RiverWindowV1,
    node: ptr RiverNodeV1,
    state: RenderWindowState,
) =
  node.setPosition(state.geom.x, state.geom.y)
  let visibility =
    renderVisibility(state.geom, state.clip, max(state.borderWidth * 2, 4'i32))
  win.applyVisibility(visibility, state.forceClip, state.borderWidth)
  win.applyBorder(state)

proc renderDesiredPlacements*(daemon: var TriadDaemon) =
  if daemon.currentModel.hasPresentationPreference():
    let mode = daemon.currentModel.configuredPresentationMode()
    for output in daemon.outputPointers.values:
      output.setPresentationMode(mode)
  let screen = daemon.currentModel.activeWorkspaceScreen()
  let ids = daemon.orderedDesiredIds()
  let orderKey = daemon.renderOrderKey(ids)
  let orderChanged = daemon.lastRenderOrder != orderKey
  if orderChanged:
    daemon.lastRenderOrder = orderKey

  var visible = initTable[uint32, bool]()
  var lastNode: ptr RiverNodeV1 = nil
  var firstNode: ptr RiverNodeV1 = nil
  let highlighted = daemon.currentModel.highlightRiverId()
  for id in ids:
    if daemon.windowNodes.hasKey(id):
      let node = daemon.windowNodes[id]
      let geom = daemon.desiredPlacements[id]
      visible[id] = true
      if firstNode == nil:
        firstNode = node
      if orderChanged and lastNode != nil:
        node.placeAbove(lastNode)
      lastNode = node
      if daemon.windowPointers.hasKey(id):
        let hasClip = daemon.desiredPlacementClips.hasKey(id)
        let visibilityBounds =
          if hasClip:
            daemon.desiredPlacementClips[id]
          else:
            daemon.desiredVisibilityBounds(id)
        let nextState =
          daemon.desiredRenderWindowState(id, geom, visibilityBounds, hasClip)
        if not daemon.lastRenderWindowStates.hasKey(id) or
            daemon.lastRenderWindowStates[id] != nextState:
          daemon.applyRenderWindowState(id, daemon.windowPointers[id], node, nextState)
          daemon.lastRenderWindowStates[id] = nextState
          inc daemon.perfCounters.renderRequests
        else:
          inc daemon.perfCounters.skippedRenderRequests

  for id, win in daemon.windowPointers.pairs:
    if not visible.hasKey(id):
      let hiddenState = RenderWindowState(visible: false)
      if not daemon.lastRenderWindowStates.hasKey(id) or
          daemon.lastRenderWindowStates[id] != hiddenState:
        win.applyHiddenRenderWindowState()
        daemon.lastRenderWindowStates[id] = hiddenState
        inc daemon.perfCounters.renderRequests
      else:
        inc daemon.perfCounters.skippedRenderRequests

  var staleCachedIds: seq[uint32]
  for id in daemon.lastRenderWindowStates.keys:
    if not daemon.windowPointers.hasKey(id):
      staleCachedIds.add(id)
  for id in staleCachedIds:
    daemon.lastRenderWindowStates.del(id)

  daemon.syncFrameTabBarSurfaces(daemon.currentFrameTabBars)
  daemon.syncFrameEmptySurfaces(daemon.currentFrameEmptyChrome)
  daemon.syncBspPreselectionSurfaces(daemon.currentBspPreselections)

  if orderChanged:
    for id in ids:
      if daemon.windowNodes.hasKey(id):
        let visibleScratchpad = daemon.currentModel.visibleScratchpadRiverId()
        let isScratchpad =
          daemon.currentModel.isScratchpadVisible and visibleScratchpad == id
        let winOpt = daemon.currentModel.windowDataForRiverId(id)
        let isFloating = winOpt.isSome and winOpt.get().isFloating
        let isFullscreen = winOpt.isSome and winOpt.get().isFullscreen
        let isMaximized = daemon.currentModel.effectivelyMaximizedForRiverId(id)
        if not isFloating and not isScratchpad and
            (isFullscreen or isMaximized or id == highlighted):
          daemon.windowNodes[id].placeTop()

    for id in ids:
      if daemon.windowNodes.hasKey(id):
        let visibleScratchpad = daemon.currentModel.visibleScratchpadRiverId()
        let isScratchpad =
          daemon.currentModel.isScratchpadVisible and visibleScratchpad == id
        let winOpt = daemon.currentModel.windowDataForRiverId(id)
        let isFloating = winOpt.isSome and winOpt.get().isFloating
        if isFloating or isScratchpad or id == highlighted:
          daemon.windowNodes[id].placeTop()

    for id in ids:
      if daemon.windowNodes.hasKey(id) and daemon.windowOrAncestorStackLayer(id) >= 1:
        daemon.windowNodes[id].placeTop()

    for id in ids:
      if daemon.windowNodes.hasKey(id) and daemon.windowOrAncestorStackLayer(id) >= 2:
        daemon.windowNodes[id].placeTop()

    if highlighted != 0 and daemon.windowNodes.hasKey(highlighted):
      daemon.windowNodes[highlighted].placeTop()

  if daemon.ownedShellSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.ownedShellSurfaceId):
    daemon.syncOwnedShellSurface(screen)
    var shell = daemon.surfaceTable[daemon.ownedShellSurfaceId]
    if shell.node != nil:
      shell.node.setPosition(screen.x, screen.y)
      if orderChanged:
        let overviewShellActive =
          daemon.currentModel.overviewActive and daemon.overviewSurfaceByOutput.len > 0
        if daemon.currentModel.overviewActive and not overviewShellActive:
          shell.node.placeTop()
        elif daemon.currentModel.recentWindowsVisible():
          shell.node.placeBottom()
          if firstNode != nil:
            shell.node.placeBelow(firstNode)
        else:
          shell.node.placeBottom()
          if firstNode != nil:
            shell.node.placeBelow(firstNode)
    daemon.surfaceTable[daemon.ownedShellSurfaceId] = shell

  for outputId, surfaceId in daemon.overviewSurfaceByOutput.pairs:
    if surfaceId == 0 or not daemon.surfaceTable.hasKey(surfaceId):
      continue
    let outputScreen = daemon.currentModel.outputScreen(outputId)
    var overview = daemon.surfaceTable[surfaceId]
    if overview.node != nil:
      overview.node.setPosition(outputScreen.x, outputScreen.y)
      if daemon.currentModel.overviewActive:
        overview.node.placeTop()
      else:
        overview.node.placeBottom()
        if firstNode != nil:
          overview.node.placeBelow(firstNode)
    daemon.surfaceTable[surfaceId] = overview

  daemon.syncHotkeyOverlaySurface(screen)
  daemon.syncRecentWindowsSurface(screen)
  if daemon.currentModel.recentWindowsVisible():
    if daemon.recentWindowsSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.recentWindowsSurfaceId):
      var backdrop = daemon.surfaceTable[daemon.recentWindowsSurfaceId]
      if backdrop.node != nil:
        backdrop.node.setPosition(screen.x, screen.y)
        if orderChanged:
          backdrop.node.placeBottom()
          if firstNode != nil:
            backdrop.node.placeBelow(firstNode)
      daemon.surfaceTable[daemon.recentWindowsSurfaceId] = backdrop
    if daemon.recentWindowsChromeSurfaceId != 0 and
        daemon.surfaceTable.hasKey(daemon.recentWindowsChromeSurfaceId):
      var chrome = daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId]
      if chrome.node != nil:
        chrome.node.setPosition(screen.x, screen.y)
        if orderChanged:
          chrome.node.placeTop()
      daemon.surfaceTable[daemon.recentWindowsChromeSurfaceId] = chrome
  daemon.syncLayoutSwitchToastSurface(screen)
  daemon.syncExitSessionConfirmSurface(screen)
