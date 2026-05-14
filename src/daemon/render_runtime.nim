import std/[algorithm, options, tables]
import protocols/river/client as river
import ../core/render_visibility
import ../systems/[daemon_view, layout_projection, window_rules]
import ../types/[model, runtime_values]
import ../utils/overview_hit_test
import protocol_surface_runtime, protocol_surfaces, state, wayland_helpers

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

proc applyBorder(
    daemon: TriadDaemon,
    id: runtime_values.WindowId,
    win: ptr RiverWindowV1,
    focused: bool,
    edges: uint32,
) =
  let logicalId = daemon.currentModel.windowForRiverId(id)
  let border = daemon.currentModel.effectiveWindowBorder(logicalId, focused)
  let color =
    if focused:
      premulColor(border.activeColor)
    else:
      premulColor(border.inactiveColor)
  win.setBorders(edges, border.width, color.r, color.g, color.b, color.a)

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

proc isDescendantRiverWindow(daemon: TriadDaemon, child, ancestor: WindowId): bool =
  if child == 0 or ancestor == 0 or child == ancestor:
    return false
  var current = child
  var depth = 0
  while current != 0 and depth < 64:
    let winOpt = daemon.currentModel.windowDataForRiverId(current)
    if winOpt.isNone:
      return false
    let parent = WindowId(uint32(winOpt.get().parentExternalId))
    if parent == 0:
      return false
    if parent == ancestor:
      return true
    current = parent
    inc depth
  false

proc logicalWindowSortKey(daemon: TriadDaemon, id: WindowId): uint32 =
  let logicalId = daemon.currentModel.windowForRiverId(id)
  if uint32(logicalId) != 0:
    return uint32(logicalId)
  uint32(id)

proc windowOrAncestorOverlay(daemon: TriadDaemon, id: WindowId): bool =
  if id == 0:
    return false
  var current = id
  var depth = 0
  while current != 0 and depth < 64:
    let winOpt = daemon.currentModel.windowDataForRiverId(current)
    if winOpt.isNone:
      return false
    let win = winOpt.get()
    if win.isOverlay:
      return true
    let parent = WindowId(uint32(win.parentExternalId))
    if parent == 0:
      return false
    current = parent
    inc depth
  false

proc desiredStackCmp(daemon: TriadDaemon, a, b: WindowId): int =
  if daemon.isDescendantRiverWindow(a, b):
    return 1
  if daemon.isDescendantRiverWindow(b, a):
    return -1
  let aOverlay = daemon.windowOrAncestorOverlay(a)
  let bOverlay = daemon.windowOrAncestorOverlay(b)
  if aOverlay != bOverlay:
    return cmp(ord(aOverlay), ord(bOverlay))
  cmp(daemon.logicalWindowSortKey(a), daemon.logicalWindowSortKey(b))

proc orderedDesiredIds*(daemon: TriadDaemon): seq[WindowId] =
  for id in daemon.desiredPlacements.keys:
    if daemon.desiredPlacementOrder.find(id) == -1:
      result.add(id)
  for id in daemon.desiredPlacementOrder:
    if daemon.desiredPlacements.hasKey(id) and result.find(id) == -1:
      result.add(id)
  result.sort(
    proc(a, b: WindowId): int =
      daemon.desiredStackCmp(a, b)
  )

proc orderedDesiredInstructions*(daemon: TriadDaemon): seq[RenderInstruction] =
  let highlighted =
    if daemon.currentModel.overviewActive:
      daemon.currentModel.highlightRiverId()
    else:
      0'u32
  for id in daemon.orderedDesiredIds():
    if id != highlighted:
      result.add(RenderInstruction(windowId: id, geom: daemon.desiredPlacements[id]))
  if highlighted != 0 and daemon.desiredPlacements.hasKey(highlighted):
    result.add(
      RenderInstruction(
        windowId: highlighted, geom: daemon.desiredPlacements[highlighted]
      )
    )

proc overviewWindowAtPointer*(daemon: TriadDaemon, seat: ptr RiverSeatV1): WindowId =
  if not daemon.currentModel.overviewActive or seat == nil:
    return 0
  let seatId = seat.id()
  if not daemon.pointerPositionBySeat.hasKey(seatId):
    return 0
  let point = daemon.pointerPositionBySeat[seatId]
  overviewHitTest(daemon.orderedDesiredInstructions(), point.x, point.y)

proc placementHonorsMinimums(daemon: TriadDaemon, id: WindowId): bool =
  if daemon.currentModel.overviewActive:
    return false
  let winOpt = daemon.currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return true
  let win = winOpt.get()
  let scratchpad =
    daemon.currentModel.isScratchpadVisible and
    daemon.currentModel.visibleScratchpadRiverId() == id
  win.isFloating or win.isFullscreen or scratchpad

proc placementNeedsCellClip(daemon: TriadDaemon, id: WindowId, geom: Rect): bool =
  let winOpt = daemon.currentModel.windowDataForRiverId(id)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if not daemon.currentModel.overviewActive:
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

proc recordDesiredPlacements*(
    daemon: var TriadDaemon, instructions: seq[RenderInstruction]
) =
  daemon.desiredPlacements.clear()
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

proc renderDesiredPlacements*(daemon: var TriadDaemon) =
  let screen = daemon.currentModel.primaryScreen()
  if daemon.currentModel.hasPresentationPreference():
    let mode = daemon.currentModel.configuredPresentationMode()
    for output in daemon.outputPointers.values:
      output.setPresentationMode(mode)
  let ids = daemon.orderedDesiredIds()

  var visible = initTable[WindowId, bool]()
  var lastNode: ptr RiverNodeV1 = nil
  var firstNode: ptr RiverNodeV1 = nil
  let highlighted = daemon.currentModel.highlightRiverId()
  for id in ids:
    if daemon.windowNodes.hasKey(id):
      let node = daemon.windowNodes[id]
      let geom = daemon.desiredPlacements[id]
      visible[id] = true
      node.setPosition(geom.x, geom.y)
      if firstNode == nil:
        firstNode = node
      if lastNode != nil:
        node.placeAbove(lastNode)
      lastNode = node
      if daemon.windowPointers.hasKey(id):
        let logicalId = daemon.currentModel.windowForRiverId(id)
        let focused = id == highlighted
        let border = daemon.currentModel.effectiveWindowBorder(logicalId, focused)
        let visibility = renderVisibility(geom, screen, max(border.width * 2, 4'i32))
        let forceClip =
          daemon.currentModel.windowClipToGeometry(logicalId) or
          daemon.placementNeedsCellClip(id, geom)
        daemon.windowPointers[id].applyVisibility(visibility, forceClip, border.width)
        daemon.applyBorder(
          id, daemon.windowPointers[id], focused, visibility.borderEdges
        )

  for id, win in daemon.windowPointers.pairs:
    if not visible.hasKey(id):
      win.hide()

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
    if daemon.windowNodes.hasKey(id) and daemon.windowOrAncestorOverlay(id):
      daemon.windowNodes[id].placeTop()

  if highlighted != 0 and daemon.windowNodes.hasKey(highlighted):
    daemon.windowNodes[highlighted].placeTop()

  if daemon.ownedShellSurfaceId != 0 and
      daemon.surfaceTable.hasKey(daemon.ownedShellSurfaceId):
    daemon.syncOwnedShellSurface(screen)
    var shell = daemon.surfaceTable[daemon.ownedShellSurfaceId]
    if shell.node != nil:
      shell.node.setPosition(screen.x, screen.y)
      if daemon.currentModel.overviewActive:
        shell.node.placeTop()
      else:
        shell.node.placeBottom()
        if firstNode != nil:
          shell.node.placeBelow(firstNode)
    daemon.surfaceTable[daemon.ownedShellSurfaceId] = shell

  daemon.syncHotkeyOverlaySurface(screen)
