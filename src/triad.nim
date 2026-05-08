import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as river_layer
import protocols/river_xkb_bindings/client as river_xkb
import core/model
import core/msg
import core/update
import core/model_utils
import layouts/scroller
import layouts/tiling
import config/parser
import ipc/socket
import utils/runtime_log
import tables, os, fsnotify, asyncdispatch, chronicles, algorithm, asyncnet, nativesockets, osproc, strutils

type
  RiverPhase = enum
    RiverIdle,
    RiverManage,
    RiverRender

# --- Global Engine State ---
var
  display: ptr Display
  registry: ptr Registry
  river_manager: ptr RiverWindowManagerV1
  river_layer_shell: ptr river_layer.RiverLayerShellV1
  river_xkb_bindings: ptr river_xkb.RiverXkbBindingsV1
  riverPhase = RiverIdle
  bindingsConfigured = false
  
  # TEA State
  currentModel: Model
  msgQueue: seq[Msg] = @[]
  pendingManageEffects: seq[Effect] = @[]
  desiredPlacements: Table[WindowId, Rect]
  lastPointerOpSeat: pointer
  
  # Mapping from logical IDs to Wayland pointers
  windowPointers: Table[WindowId, ptr RiverWindowV1]
  windowNodes: Table[WindowId, ptr RiverNodeV1]
  outputPointers: Table[uint32, ptr RiverOutputV1]
  layerOutputPointers: Table[uint32, ptr river_layer.RiverLayerShellOutputV1]
  layerOutputOwners: Table[uint32, uint32]
  seatPointers: seq[ptr RiverSeatV1] = @[]
  layerSeatPointers: seq[ptr river_layer.RiverLayerShellSeatV1] = @[]
  xkbBindings: Table[uint32, Msg]
  xkbBindingPointers: seq[ptr river_xkb.RiverXkbBindingV1] = @[]
  pointerBindings: Table[uint32, Msg]
  pointerBindingKinds: Table[uint32, PointerOpKind]
  pointerBindingSeats: Table[uint32, ptr RiverSeatV1]
  pointerBindingPointers: seq[ptr RiverPointerBindingV1] = @[]

  # Config Watcher
  configPath: string
  watcher: Watcher

# --- Helpers ---

proc get_id(p: pointer): uint32 =
  get_id(cast[ptr Proxy](p))

proc failCli(message: string) =
  stderr.writeLine("triad: " & message)
  quit 1

proc cstringOrEmpty(value: cstring): string =
  if value == nil:
    ""
  else:
    $value

proc primaryScreen(model: Model): Rect =
  if model.primaryOutput != 0 and model.outputs.hasKey(model.primaryOutput):
    let output = model.outputs[model.primaryOutput]
    if output.hasUsable and output.usableW > 0 and output.usableH > 0:
      return Rect(x: output.usableX, y: output.usableY, w: output.usableW, h: output.usableH)
    Rect(x: output.x, y: output.y, w: output.w, h: output.h)
  else:
    Rect(x: 0, y: 0, w: model.screenWidth, h: model.screenHeight)

proc activeFocus(model: Model): WindowId =
  if model.tags.hasKey(model.activeTag):
    let tag = model.tags[model.activeTag]
    if tag.focusedWindow != 0 and tag.containsWindow(tag.focusedWindow):
      return tag.focusedWindow
  0

proc outputName(model: Model; outputId: uint32): string =
  if outputId == 0:
    "triad-0"
  else:
    "river-" & $outputId

proc getTiledTagState(tag: TagState, model: Model): TagState =
  # Helper to get a TagState with only non-floating and active grouped windows
  result = tag
  result.columns = @[]
  for col in tag.columns:
    var filteredWindows: seq[WindowId] = @[]
    for winId in col.windows:
      let isFloating = model.windows.hasKey(winId) and model.windows[winId].isFloating
      
      # Group filtering logic
      var isHiddenInGroup = false
      for group in model.groups.values:
        if group.windows.contains(winId) and group.activeWindow != winId:
          isHiddenInGroup = true
          break
          
      if not isFloating and not isHiddenInGroup:
        filteredWindows.add(winId)
    if filteredWindows.len > 0:
      var filteredCol = col
      filteredCol.windows = filteredWindows
      result.columns.add(filteredCol)

proc computeLayoutInstructions(model: var Model): seq[RenderInstruction] =
  let screen = model.primaryScreen()
  result = @[]

  if model.overviewActive:
    var overviewTag = TagState(tagId: 0, layoutMode: Grid)
    var tagIds: seq[uint32] = @[]
    for id in model.tags.keys:
      tagIds.add(id)
    tagIds.sort()
    for id in tagIds:
      let tag = model.tags[id]
      for col in tag.columns:
        for win in col.windows:
          overviewTag.columns.add(Column(windows: @[win], widthProportion: 1.0))

    result = layoutGrid(overviewTag, screen, 64, model.innerGaps * 2)

  elif model.tags.hasKey(model.activeTag):
    var tag = model.tags[model.activeTag]
    let tiledTagState = getTiledTagState(tag, model)

    var currentOuterGap = model.outerGaps
    var currentInnerGap = model.innerGaps

    var tiledWindowCount = 0
    for col in tiledTagState.columns:
      tiledWindowCount += col.windows.len

    if model.smartGaps and tiledWindowCount <= 1:
      currentOuterGap = 0
      currentInnerGap = 0

    var tagForLayout = tiledTagState
    result = case tagForLayout.layoutMode
      of Scroller:
        layoutScroller(tagForLayout, model.windows, screen, currentOuterGap, currentInnerGap,
                       model.scrollerFocusCenter, model.scrollerPreferCenter,
                       model.centerFocusedColumn)
      of VerticalScroller:
        layoutVerticalScroller(tagForLayout, model.windows, screen, currentOuterGap, currentInnerGap,
                               model.scrollerFocusCenter, model.scrollerPreferCenter,
                               model.centerFocusedColumn)
      of MasterStack:
        layoutMasterStack(tagForLayout, screen, currentOuterGap, currentInnerGap)
      of Grid:
        layoutGrid(tagForLayout, screen, currentOuterGap, currentInnerGap)
      of Monocle:
        layoutMonocle(tagForLayout, screen, currentOuterGap)

    tag.targetViewportXOffset = tagForLayout.targetViewportXOffset
    tag.targetViewportYOffset = tagForLayout.targetViewportYOffset
    model.tags[model.activeTag] = tag

    for col in tag.columns:
      for winId in col.windows:
        if model.windows.hasKey(winId):
          let winData = model.windows[winId]
          if winData.isFloating:
            result.add(RenderInstruction(
              windowId: winId,
              geom: winData.floatingGeom
            ))

    if model.isScratchpadVisible and model.scratchpadWindows.len > 0:
      let winId = model.scratchpadWindows[^1]
      let sw = int32(float32(model.screenWidth) * 0.8)
      let sh = int32(float32(model.screenHeight) * 0.8)
      result.add(RenderInstruction(
        windowId: winId,
        geom: Rect(
          x: screen.x + (model.screenWidth - sw) div 2,
          y: screen.y + (model.screenHeight - sh) div 2,
          w: sw,
          h: sh
        )
      ))

    let focused = model.activeFocus()
    if focused != 0 and model.windows.hasKey(focused) and model.windows[focused].isFullscreen:
      result = @[RenderInstruction(windowId: focused, geom: screen)]

proc setupConfig() =
  configPath = getConfigPath()
  let configDir = configPath.splitFile().dir
  if not dirExists(configDir):
    createDir(configDir)
  
  if not fileExists(configPath):
    let defaultContent = """// Triad Configuration (KDL 2.0)

layout {
    gaps 16
    center-focused-column "on-overflow"
    default-column-width { proportion 0.5; }
    enable-animations #true
    animation-speed 0.15
    smart-gaps #false
}

tag-rules {
    tag 1 default-layout="scroller"
    tag 2 default-layout="tile"
    tag 3 default-layout="grid"
    tag 4 default-layout="monocle"
}

quickshell {
    enabled #false
    theme "noctalia-shell"
}

// spawn-at-startup "waybar"

window-rule {
    match app-id="firefox"
    default-tag 2
}

window-rule {
    match app-id="alacritty"
    default-tag 1
}

window-rule {
    match title="^Picture-in-Picture$"
    open-floating #true
}
"""
    writeFile(configPath, defaultContent)
    info "Created default config", path=configPath

proc spawnStartupCommands(model: Model) =
  for cmd in model.startupCommands:
    if cmd.len > 0:
      try:
        let p = startProcess(cmd[0], args = cmd[1..^1], options = {poUsePath})
        info "Spawned startup command", cmd=cmd[0], pid=p.processID
      except CatchableError as e:
        warn "Failed to spawn startup command", cmd=cmd[0], error=e.msg

proc spawnQuickshell(model: Model) =
  if model.quickshell.enabled and model.quickshell.theme != "":
    var args = @["-c", model.quickshell.theme]
    for arg in model.quickshell.args:
      args.add(arg)
    
    try:
      let p = startProcess("qs", args = args, options = {poUsePath})
      info "Spawned Quickshell", theme=model.quickshell.theme, pid=p.processID
    except CatchableError as e:
      warn "Failed to spawn Quickshell", theme=model.quickshell.theme, error=e.msg

proc spawnTerminal() =
  var candidates: seq[string] = @[]
  let configured = getEnv("TERMINAL", "")
  if configured.len > 0:
    candidates.add(configured)
  candidates.add(@["foot", "kitty", "wezterm", "ghostty", "alacritty", "xterm"])

  for terminal in candidates:
    try:
      let p = startProcess(terminal, options = {poUsePath})
      info "Spawned terminal", terminal=terminal, pid=p.processID
      return
    except CatchableError as e:
      trace "Terminal candidate failed", terminal=terminal, error=e.msg

  warn "No terminal command could be spawned", candidates=candidates

proc requestManage(reason: string)

const
  RiverEdgeTop = 1'u32
  RiverEdgeBottom = 2'u32
  RiverEdgeLeft = 4'u32
  RiverEdgeRight = 8'u32
  RiverAllEdges = RiverEdgeTop or RiverEdgeBottom or RiverEdgeLeft or RiverEdgeRight
  RiverModSuper = 64'u32
  BtnLeft = 0x110'u32
  BtnRight = 0x111'u32
  FocusedBorder = 0xffffffff'u32
  UnfocusedBorder = 0x666666ff'u32
  RiverCapabilityFullscreen = 4'u32
  BorderWidth = 2'i32

var
  xkb_binding_listener: river_xkb.RiverXkbBindingV1Listener
  pointer_binding_listener: RiverPointerBindingV1Listener
  layer_output_listener: river_layer.RiverLayerShellOutputV1Listener
  layer_seat_listener: river_layer.RiverLayerShellSeatV1Listener

proc premulColor(value: uint32): tuple[r, g, b, a: uint32] =
  let r8 = (value shr 24) and 0xff
  let g8 = (value shr 16) and 0xff
  let b8 = (value shr 8) and 0xff
  let a8 = value and 0xff
  let max32 = uint64(high(uint32))
  let a32 = uint32((uint64(a8) * max32) div 255)
  result.r = uint32((uint64(r8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.g = uint32((uint64(g8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.b = uint32((uint64(b8) * uint64(a8) * max32) div (255'u64 * 255'u64))
  result.a = a32

proc keySym(ch: char): uint32 =
  uint32(ord(ch))

proc applyBorder(win: ptr RiverWindowV1; focused: bool) =
  let color = premulColor(if focused: FocusedBorder else: UnfocusedBorder)
  win.setBorders(RiverAllEdges, BorderWidth, color.r, color.g, color.b, color.a)

proc outputIdForPointer(output: ptr RiverOutputV1): uint32 =
  if output == nil:
    return 0
  let id = output.get_id()
  if outputPointers.hasKey(id):
    id
  else:
    0

proc attachLayerOutput(outputId: uint32) =
  if river_layer_shell == nil or not outputPointers.hasKey(outputId) or layerOutputPointers.hasKey(outputId):
    return
  let layerOutput = river_layer_shell.getOutput(outputPointers[outputId])
  layerOutputPointers[outputId] = layerOutput
  layerOutputOwners[layerOutput.get_id()] = outputId
  discard layerOutput.addListener(layer_output_listener.addr, nil)

proc attachLayerSeat(seat: ptr RiverSeatV1) =
  if river_layer_shell == nil or seat == nil:
    return
  let layerSeat = river_layer_shell.getSeat(seat)
  layerSeatPointers.add(layerSeat)
  discard layerSeat.addListener(layer_seat_listener.addr, nil)

proc destroyBindings() =
  for binding in xkbBindingPointers:
    binding.destroy()
  xkbBindingPointers = @[]
  xkbBindings.clear()

  for binding in pointerBindingPointers:
    binding.destroy()
  pointerBindingPointers = @[]
  pointerBindings.clear()
  pointerBindingKinds.clear()
  pointerBindingSeats.clear()
  bindingsConfigured = false

proc addXkbBinding(seat: ptr RiverSeatV1; keysym, modifiers: uint32; msg: Msg) =
  if river_xkb_bindings == nil:
    return
  let binding = river_xkb_bindings.getXkbBinding(seat, keysym, modifiers)
  xkbBindingPointers.add(binding)
  xkbBindings[binding.get_id()] = msg
  discard binding.addListener(xkb_binding_listener.addr, nil)
  binding.enable()

proc addPointerBinding(seat: ptr RiverSeatV1; button, modifiers: uint32; op: PointerOpKind) =
  let binding = seat.getPointerBinding(button, modifiers)
  pointerBindingPointers.add(binding)
  pointerBindingKinds[binding.get_id()] = op
  pointerBindingSeats[binding.get_id()] = seat
  discard binding.addListener(pointer_binding_listener.addr, nil)
  binding.enable()

proc setupDefaultBindings() =
  if bindingsConfigured:
    return
  if seatPointers.len == 0:
    return

  for seat in seatPointers:
    addXkbBinding(seat, keySym('q'), RiverModSuper, Msg(kind: CmdCloseWindow))
    addXkbBinding(seat, keySym('f'), RiverModSuper, Msg(kind: CmdToggleFullscreen))
    addXkbBinding(seat, keySym('r'), RiverModSuper, Msg(kind: CmdReloadConfig))
    addXkbBinding(seat, keySym('t'), RiverModSuper, Msg(kind: CmdSpawnTerminal))
    for idx in 1'u32 .. 9'u32:
      addXkbBinding(seat, uint32(ord('0') + int(idx)), RiverModSuper, Msg(kind: CmdFocusTag, focusTag: idx))

    addPointerBinding(seat, BtnLeft, RiverModSuper, OpMove)
    addPointerBinding(seat, BtnRight, RiverModSuper, OpResize)

  bindingsConfigured = true

proc applyManageState() =
  setupDefaultBindings()

  for id, win in windowPointers.pairs:
    win.useSsd()
    win.setCapabilities(RiverCapabilityFullscreen)
    var edges = RiverAllEdges
    if currentModel.windows.hasKey(id):
      let data = currentModel.windows[id]
      win.setDimensionBounds(data.maxWidth, data.maxHeight)
      if data.isFloating or data.isFullscreen:
        edges = 0
    win.setTiled(edges)

  let focused = currentModel.activeFocus()
  for seat in seatPointers:
    if focused != 0 and windowPointers.hasKey(focused):
      seat.focusWindow(windowPointers[focused])
    else:
      seat.clearFocus()

  if currentModel.primaryOutput != 0 and layerOutputPointers.hasKey(currentModel.primaryOutput):
    layerOutputPointers[currentModel.primaryOutput].setDefault()

# --- RiverSeatV1 Callbacks ---

proc removeSeatPointer(seat: ptr RiverSeatV1) =
  var i = 0
  while i < seatPointers.len:
    if seatPointers[i] == seat:
      seatPointers.delete(i)
    else:
      inc i

proc on_seat_removed(data: pointer, seat: ptr RiverSeatV1) =
  info "Seat removed"
  removeSeatPointer(seat)
  for layerSeat in layerSeatPointers:
    layerSeat.destroy()
  layerSeatPointers = @[]
  destroyBindings()
  seat.destroy()

proc on_seat_wl_seat(data: pointer, seat: ptr RiverSeatV1, name: uint32) =
  trace "Seat wl_seat received", name=name

proc on_seat_pointer_enter(data: pointer, seat: ptr RiverSeatV1, win: ptr RiverWindowV1) =
  if win != nil:
    trace "Pointer entered window", windowId=win.get_id()

proc on_seat_pointer_leave(data: pointer, seat: ptr RiverSeatV1) =
  trace "Pointer left window"

proc on_seat_window_interaction(data: pointer, seat: ptr RiverSeatV1, win: ptr RiverWindowV1) =
  if win != nil:
    let id = win.get_id()
    debug "Seat window interaction", windowId=id
    msgQueue.add(Msg(kind: WlFocusChanged, newFocusedId: id))

proc on_seat_shell_surface_interaction(data: pointer, seat: ptr RiverSeatV1, shellSurface: ptr RiverShellSurfaceV1) =
  trace "Seat shell surface interaction"

proc on_op_delta(data: pointer, seat: ptr RiverSeatV1, dx: int32, dy: int32) =
  msgQueue.add(Msg(kind: WlPointerDelta, dx: dx, dy: dy))

proc on_op_release(data: pointer, seat: ptr RiverSeatV1) =
  msgQueue.add(Msg(kind: WlPointerRelease))

proc on_seat_pointer_position(data: pointer, seat: ptr RiverSeatV1, x: int32, y: int32) =
  trace "Seat pointer position", x=x, y=y

var seat_listener = RiverSeatV1Listener(
  removed: on_seat_removed,
  seat: on_seat_wl_seat,
  pointerEnter: on_seat_pointer_enter,
  pointerLeave: on_seat_pointer_leave,
  windowInteraction: on_seat_window_interaction,
  shellSurfaceInteraction: on_seat_shell_surface_interaction,
  opDelta: on_op_delta,
  opRelease: on_op_release,
  pointerPosition: on_seat_pointer_position
)

proc on_xkb_pressed(data: pointer, binding: ptr river_xkb.RiverXkbBindingV1) =
  let id = binding.get_id()
  if xkbBindings.hasKey(id):
    msgQueue.add(xkbBindings[id])

proc on_xkb_released(data: pointer, binding: ptr river_xkb.RiverXkbBindingV1) =
  discard

proc on_xkb_stop_repeat(data: pointer, binding: ptr river_xkb.RiverXkbBindingV1) =
  discard

xkb_binding_listener = river_xkb.RiverXkbBindingV1Listener(
  pressed: on_xkb_pressed,
  released: on_xkb_released,
  stopRepeat: on_xkb_stop_repeat
)

proc on_pointer_binding_pressed(data: pointer, binding: ptr RiverPointerBindingV1) =
  let id = binding.get_id()
  let focused = currentModel.activeFocus()
  if focused == 0 or not pointerBindingSeats.hasKey(id):
    return
  let seat = pointerBindingSeats[id]
  if pointerBindingKinds.hasKey(id):
    case pointerBindingKinds[id]
    of OpMove:
      msgQueue.add(Msg(kind: WlPointerMoveRequested, moveWinId: focused, moveSeat: seat))
    of OpResize:
      msgQueue.add(Msg(kind: WlPointerResizeRequested, resizeWinId: focused, resizeSeat: seat, resizeEdges: RiverEdgeBottom or RiverEdgeRight))
    else:
      discard
  elif pointerBindings.hasKey(id):
    msgQueue.add(pointerBindings[id])

proc on_pointer_binding_released(data: pointer, binding: ptr RiverPointerBindingV1) =
  discard

pointer_binding_listener = RiverPointerBindingV1Listener(
  pressed: on_pointer_binding_pressed,
  released: on_pointer_binding_released
)

proc on_layer_output_non_exclusive(
    data: pointer,
    layerOutput: ptr river_layer.RiverLayerShellOutputV1,
    x: int32,
    y: int32,
    width: int32,
    height: int32) =
  let layerId = layerOutput.get_id()
  if layerOutputOwners.hasKey(layerId):
    let outputId = layerOutputOwners[layerId]
    msgQueue.add(Msg(kind: WlOutputUsable, usableOutputId: outputId, usableX: x, usableY: y, usableW: width, usableH: height))

layer_output_listener = river_layer.RiverLayerShellOutputV1Listener(
  nonExclusiveArea: on_layer_output_non_exclusive
)

proc on_layer_seat_focus_exclusive(data: pointer, seat: ptr river_layer.RiverLayerShellSeatV1) =
  trace "Layer shell focus exclusive"

proc on_layer_seat_focus_non_exclusive(data: pointer, seat: ptr river_layer.RiverLayerShellSeatV1) =
  trace "Layer shell focus non-exclusive"

proc on_layer_seat_focus_none(data: pointer, seat: ptr river_layer.RiverLayerShellSeatV1) =
  requestManage("layer focus none")

layer_seat_listener = river_layer.RiverLayerShellSeatV1Listener(
  focusExclusive: on_layer_seat_focus_exclusive,
  focusNonExclusive: on_layer_seat_focus_non_exclusive,
  focusNone: on_layer_seat_focus_none
)

# --- Effects Execution ---

proc requestManage(reason: string) =
  if river_manager != nil:
    trace "Requesting River manage sequence", reason=reason
    river_manager.manageDirty()

proc executeManageEffect(eff: Effect) =
  case eff.kind
  of EffOpStartPointer:
    if eff.opSeat != nil:
      lastPointerOpSeat = eff.opSeat
      cast[ptr RiverSeatV1](eff.opSeat).opStartPointer()
  of EffOpEnd:
    if eff.endSeat != nil:
      cast[ptr RiverSeatV1](eff.endSeat).opEnd()
      if lastPointerOpSeat == eff.endSeat:
        lastPointerOpSeat = nil
  of EffSetPosition:
    if windowPointers.hasKey(eff.windowId):
      windowPointers[eff.windowId].proposeDimensions(max(0'i32, eff.w), max(0'i32, eff.h))
  of EffFocusWindow:
    if windowPointers.hasKey(eff.focusId):
      let win = windowPointers[eff.focusId]
      for seat in seatPointers:
        seat.focusWindow(win)
  of EffCloseWindow:
    if windowPointers.hasKey(eff.closeId):
      windowPointers[eff.closeId].close()
  of EffSetFullscreen:
    if windowPointers.hasKey(eff.fsWinId):
      let win = windowPointers[eff.fsWinId]
      if eff.isFullscreen:
        var output: ptr RiverOutputV1 = nil
        if eff.fsOutputId != 0 and outputPointers.hasKey(eff.fsOutputId):
          output = outputPointers[eff.fsOutputId]
        elif currentModel.primaryOutput != 0 and outputPointers.hasKey(currentModel.primaryOutput):
          output = outputPointers[currentModel.primaryOutput]
        elif outputPointers.len > 0:
          for p in outputPointers.values:
            output = p
            break
        if output != nil:
          win.fullscreen(output)
          win.informFullscreen()
      else:
        win.exitFullscreen()
        win.informNotFullscreen()
  else:
    discard

proc queueManageEffect(eff: Effect) =
  if riverPhase == RiverManage:
    executeManageEffect(eff)
  else:
    pendingManageEffects.add(eff)
    requestManage($eff.kind)

proc flushPendingManageEffects() =
  if pendingManageEffects.len == 0:
    return
  let effects = pendingManageEffects
  pendingManageEffects = @[]
  for eff in effects:
    executeManageEffect(eff)

proc proposeDesiredDimensions(instructions: seq[RenderInstruction]) =
  desiredPlacements.clear()
  for instr in instructions:
    desiredPlacements[instr.windowId] = instr.geom
    if windowPointers.hasKey(instr.windowId):
      var geom = instr.geom
      if currentModel.windows.hasKey(instr.windowId):
        let bounded = currentModel.windows[instr.windowId].boundedDimensions(geom.w, geom.h)
        geom.w = bounded.w
        geom.h = bounded.h
      windowPointers[instr.windowId].proposeDimensions(max(0'i32, geom.w), max(0'i32, geom.h))

proc intersects(a, b: Rect): bool =
  a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y

proc applyVisibility(win: ptr RiverWindowV1; geom, screen: Rect) =
  if geom.intersects(screen):
    win.show()
    var clipX = max(0'i32, screen.x - geom.x)
    var clipY = max(0'i32, screen.y - geom.y)
    let right = min(geom.x + geom.w, screen.x + screen.w)
    let bottom = min(geom.y + geom.h, screen.y + screen.h)
    let clipW = max(0'i32, right - max(geom.x, screen.x))
    let clipH = max(0'i32, bottom - max(geom.y, screen.y))
    if clipW < geom.w or clipH < geom.h or clipX > 0 or clipY > 0:
      win.setClipBox(clipX, clipY, clipW, clipH)
    else:
      win.setClipBox(0, 0, 0, 0)
  else:
    win.hide()

proc renderDesiredPlacements() =
  let screen = currentModel.primaryScreen()
  var ids: seq[WindowId] = @[]
  for id in desiredPlacements.keys:
    ids.add(id)
  ids.sort()

  var visible = initTable[WindowId, bool]()
  var lastNode: ptr RiverNodeV1 = nil
  for id in ids:
    if windowNodes.hasKey(id):
      let node = windowNodes[id]
      let geom = desiredPlacements[id]
      visible[id] = true
      node.setPosition(geom.x, geom.y)
      if lastNode != nil:
        node.placeAbove(lastNode)
      lastNode = node
      if windowPointers.hasKey(id):
        windowPointers[id].applyVisibility(geom, screen)
        windowPointers[id].applyBorder(id == currentModel.activeFocus())

  for id, win in windowPointers.pairs:
    if not visible.hasKey(id):
      win.hide()

  for id in ids:
    if windowNodes.hasKey(id):
      let isScratchpad = currentModel.isScratchpadVisible and
        currentModel.scratchpadWindows.len > 0 and
        currentModel.scratchpadWindows[^1] == id
      let isFullscreen = currentModel.windows.hasKey(id) and currentModel.windows[id].isFullscreen
      if (currentModel.windows.hasKey(id) and currentModel.windows[id].isFloating) or isScratchpad or isFullscreen or id == currentModel.activeFocus():
        windowNodes[id].placeTop()

proc executeEffect(eff: Effect) =
  case eff.kind
  of EffLog:
    info "log", msg=eff.msg
  of EffManageFinish:
    if river_manager != nil and riverPhase == RiverManage:
      river_manager.manageFinish()
  of EffRenderFinish:
    if river_manager != nil and riverPhase == RiverRender:
      river_manager.renderFinish()
  of EffManageDirty:
    requestManage("effect")
  of EffBroadcastJson:
    asyncCheck broadcastJson(eff.jsonPayload)
  of EffOpStartPointer, EffOpEnd, EffFocusWindow, EffCloseWindow, EffSetFullscreen:
    queueManageEffect(eff)
  of EffSetPosition:
    if riverPhase == RiverRender and windowNodes.hasKey(eff.windowId):
      let node = windowNodes[eff.windowId]
      node.setPosition(eff.x, eff.y)

      if currentModel.windows.hasKey(eff.windowId) and currentModel.windows[eff.windowId].isFloating:
        node.placeTop()
    else:
      desiredPlacements[eff.windowId] = Rect(x: eff.x, y: eff.y, w: eff.w, h: eff.h)
      queueManageEffect(eff)
  else:
    discard

# Mapping from logical IDs to window metadata for late creation
var pendingWindows: Table[WindowId, WindowData]

# --- RiverWindowV1 Callbacks ---

proc forgetWindow(id: WindowId) =
  desiredPlacements.del(id)
  pendingWindows.del(id)
  if windowNodes.hasKey(id):
    let node = windowNodes[id]
    windowNodes.del(id)
    node.destroy()
  if windowPointers.hasKey(id):
    let win = windowPointers[id]
    windowPointers.del(id)
    win.destroy()

proc on_window_app_id(data: pointer, win: ptr RiverWindowV1, appId: cstring) =
  let id = win.get_id()
  let appIdText = cstringOrEmpty(appId)
  debug "Window app-id received", windowId=id, appId=appIdText
  if pendingWindows.hasKey(id):
    pendingWindows[id].appId = appIdText
  elif currentModel.windows.hasKey(id):
    msgQueue.add(Msg(kind: WlWindowAppId, appIdWindowId: id, updatedAppId: appIdText))

proc on_window_title(data: pointer, win: ptr RiverWindowV1, title: cstring) =
  let id = win.get_id()
  let titleText = cstringOrEmpty(title)
  debug "Window title received", windowId=id, title=titleText
  if pendingWindows.hasKey(id):
    pendingWindows[id].title = titleText
  elif currentModel.windows.hasKey(id):
    msgQueue.add(Msg(kind: WlWindowTitle, titleWindowId: id, updatedTitle: titleText))

proc on_window_closed(data: pointer, win: ptr RiverWindowV1) =
  let id = win.get_id()
  info "Window closed", windowId=id
  msgQueue.add(Msg(kind: WlWindowDestroyed, destroyedId: id))
  forgetWindow(id)

proc on_window_dimensions_hint(
    data: pointer,
    win: ptr RiverWindowV1,
    minWidth: int32,
    minHeight: int32,
    maxWidth: int32,
    maxHeight: int32) =
  trace "Window dimensions hint received",
    windowId=win.get_id(),
    minWidth=minWidth,
    minHeight=minHeight,
    maxWidth=maxWidth,
    maxHeight=maxHeight
  if pendingWindows.hasKey(win.get_id()):
    pendingWindows[win.get_id()].minWidth = max(0'i32, minWidth)
    pendingWindows[win.get_id()].minHeight = max(0'i32, minHeight)
    pendingWindows[win.get_id()].maxWidth = max(0'i32, maxWidth)
    pendingWindows[win.get_id()].maxHeight = max(0'i32, maxHeight)
  elif currentModel.windows.hasKey(win.get_id()):
    msgQueue.add(Msg(
      kind: WlWindowDimensionsHint,
      hintWindowId: win.get_id(),
      minWidth: minWidth,
      minHeight: minHeight,
      maxWidth: maxWidth,
      maxHeight: maxHeight))

proc on_window_dimensions(data: pointer, win: ptr RiverWindowV1, width: int32, height: int32) =
  trace "Window dimensions acknowledged", windowId=win.get_id(), width=width, height=height

proc on_window_parent(data: pointer, win: ptr RiverWindowV1, parent: ptr RiverWindowV1) =
  let parentId = if parent == nil: 0'u32 else: parent.get_id()
  trace "Window parent received", windowId=win.get_id(), parentId=parentId
  if pendingWindows.hasKey(win.get_id()):
    pendingWindows[win.get_id()].parentId = parentId
  else:
    msgQueue.add(Msg(kind: WlWindowParent, childWindowId: win.get_id(), parentWindowId: parentId))

proc on_window_decoration_hint(data: pointer, win: ptr RiverWindowV1, hint: uint32) =
  trace "Window decoration hint received", windowId=win.get_id(), hint=hint

proc on_window_pointer_move_requested(data: pointer, win: ptr RiverWindowV1, seat: ptr RiverSeatV1) =
  debug "Pointer move requested", windowId=win.get_id()
  msgQueue.add(Msg(kind: WlPointerMoveRequested, moveWinId: win.get_id(), moveSeat: seat))

proc on_window_pointer_resize_requested(data: pointer, win: ptr RiverWindowV1, seat: ptr RiverSeatV1, edges: uint32) =
  debug "Pointer resize requested", windowId=win.get_id(), edges=edges
  msgQueue.add(Msg(kind: WlPointerResizeRequested, resizeWinId: win.get_id(), resizeSeat: seat, resizeEdges: edges))

proc on_window_show_menu_requested(data: pointer, win: ptr RiverWindowV1, x: int32, y: int32) =
  debug "Window menu requested", windowId=win.get_id(), x=x, y=y

proc on_window_maximize_requested(data: pointer, win: ptr RiverWindowV1) =
  debug "Window maximize requested", windowId=win.get_id()

proc on_window_unmaximize_requested(data: pointer, win: ptr RiverWindowV1) =
  debug "Window unmaximize requested", windowId=win.get_id()

proc on_window_fullscreen_requested(data: pointer, win: ptr RiverWindowV1, output: ptr RiverOutputV1) =
  let requestedOutput = outputIdForPointer(output)
  debug "Window fullscreen requested", windowId=win.get_id(), outputId=requestedOutput
  if pendingWindows.hasKey(win.get_id()):
    pendingWindows[win.get_id()].isFullscreen = true
    pendingWindows[win.get_id()].fullscreenOutput = requestedOutput
  else:
    msgQueue.add(Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: win.get_id(), fullscreenOutputId: requestedOutput))

proc on_window_exit_fullscreen_requested(data: pointer, win: ptr RiverWindowV1) =
  debug "Window exit fullscreen requested", windowId=win.get_id()
  if pendingWindows.hasKey(win.get_id()):
    pendingWindows[win.get_id()].isFullscreen = false
    pendingWindows[win.get_id()].fullscreenOutput = 0
  else:
    msgQueue.add(Msg(kind: WlWindowExitFullscreenRequested, exitFullscreenRequestId: win.get_id()))

proc on_window_minimize_requested(data: pointer, win: ptr RiverWindowV1) =
  debug "Window minimize requested", windowId=win.get_id()

proc on_window_unreliable_pid(data: pointer, win: ptr RiverWindowV1, unreliablePid: int32) =
  trace "Window unreliable pid received", windowId=win.get_id(), pid=unreliablePid

proc on_window_presentation_hint(data: pointer, win: ptr RiverWindowV1, hint: uint32) =
  trace "Window presentation hint received", windowId=win.get_id(), hint=hint

proc on_window_identifier(data: pointer, win: ptr RiverWindowV1, identifier: cstring) =
  let text = cstringOrEmpty(identifier)
  let id = win.get_id()
  trace "Window identifier received", windowId=id, identifier=text
  if pendingWindows.hasKey(id):
    pendingWindows[id].identifier = text
  else:
    msgQueue.add(Msg(kind: WlWindowIdentifier, identifierWindowId: id, identifier: text))

var window_listener = RiverWindowV1Listener(
  closed: on_window_closed,
  dimensionsHint: on_window_dimensions_hint,
  dimensions: on_window_dimensions,
  appId: on_window_app_id,
  title: on_window_title,
  parent: on_window_parent,
  decorationHint: on_window_decoration_hint,
  pointerMoveRequested: on_window_pointer_move_requested,
  pointerResizeRequested: on_window_pointer_resize_requested,
  showWindowMenuRequested: on_window_show_menu_requested,
  maximizeRequested: on_window_maximize_requested,
  unmaximizeRequested: on_window_unmaximize_requested,
  fullscreenRequested: on_window_fullscreen_requested,
  exitFullscreenRequested: on_window_exit_fullscreen_requested,
  minimizeRequested: on_window_minimize_requested,
  unreliablePid: on_window_unreliable_pid,
  presentationHint: on_window_presentation_hint,
  identifier: on_window_identifier
)

# --- Wayland Callbacks ---

proc cleanupRiverObjects() =
  var winIds: seq[WindowId] = @[]
  for id in windowPointers.keys:
    winIds.add(id)
  for id in winIds:
    forgetWindow(id)

  var outputIds: seq[uint32] = @[]
  for id in outputPointers.keys:
    outputIds.add(id)
  for id in outputIds:
    if layerOutputPointers.hasKey(id):
      let layerOutput = layerOutputPointers[id]
      layerOutputOwners.del(layerOutput.get_id())
      layerOutputPointers.del(id)
      layerOutput.destroy()
    let output = outputPointers[id]
    outputPointers.del(id)
    output.destroy()

  for seat in layerSeatPointers:
    seat.destroy()
  layerSeatPointers = @[]

  destroyBindings()

  let seats = seatPointers
  seatPointers = @[]
  for seat in seats:
    seat.destroy()

proc on_manager_unavailable(data: pointer, mgr: ptr RiverWindowManagerV1) =
  fatal "River window manager interface is unavailable"
  quit 1

proc on_manager_finished(data: pointer, mgr: ptr RiverWindowManagerV1) =
  warn "River window manager interface finished"
  cleanupRiverObjects()
  if river_manager != nil:
    river_manager.destroy()
    river_manager = nil

proc on_session_locked(data: pointer, mgr: ptr RiverWindowManagerV1) =
  info "River session locked"

proc on_session_unlocked(data: pointer, mgr: ptr RiverWindowManagerV1) =
  info "River session unlocked"

proc on_manage_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  debug "River manage start", pendingWindows=pendingWindows.len
  # Before starting manage, move all pending windows to the message queue
  for id, data in pendingWindows:
    msgQueue.add(Msg(kind: WlWindowCreated, windowId: id, appId: data.appId, title: data.title, createdIdentifier: data.identifier))
    if data.parentId != 0:
      msgQueue.add(Msg(kind: WlWindowParent, childWindowId: id, parentWindowId: data.parentId))
    if data.minWidth > 0 or data.minHeight > 0 or data.maxWidth > 0 or data.maxHeight > 0:
      msgQueue.add(Msg(
        kind: WlWindowDimensionsHint,
        hintWindowId: id,
        minWidth: data.minWidth,
        minHeight: data.minHeight,
        maxWidth: data.maxWidth,
        maxHeight: data.maxHeight))
    if data.isFullscreen:
      msgQueue.add(Msg(kind: WlWindowFullscreenRequested, fullscreenRequestId: id, fullscreenOutputId: data.fullscreenOutput))
  pendingWindows.clear()
  msgQueue.add(Msg(kind: WlManageStart))

proc on_render_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  trace "River render start"
  msgQueue.add(Msg(kind: WlRenderStart))

proc on_window(data: pointer, mgr: ptr RiverWindowManagerV1, win: ptr RiverWindowV1) =
  let id = win.get_id()
  info "Window discovered", windowId=id
  windowPointers[id] = win
  windowNodes[id] = win.getNode()
  # Start tracking as pending until we get metadata or manage starts
  pendingWindows[id] = WindowData(id: id, appId: "unknown", title: "unknown")
  discard win.addListener(window_listener.addr, nil)

proc on_output_dimensions(data: pointer, output: ptr RiverOutputV1, width: int32, height: int32) =
  info "Output dimensions changed", outputId=output.get_id(), width=width, height=height
  msgQueue.add(Msg(kind: WlOutputDimensions, outputId: output.get_id(), width: width, height: height))

proc on_output_removed(data: pointer, output: ptr RiverOutputV1) =
  let id = output.get_id()
  info "Output removed", outputId=id
  if layerOutputPointers.hasKey(id):
    let layerOutput = layerOutputPointers[id]
    layerOutputOwners.del(layerOutput.get_id())
    layerOutputPointers.del(id)
    layerOutput.destroy()
  outputPointers.del(id)
  msgQueue.add(Msg(kind: WlOutputRemoved, removedOutputId: id))
  output.destroy()

proc on_output_wl_output(data: pointer, output: ptr RiverOutputV1, name: uint32) =
  trace "Output wl_output received", outputId=output.get_id(), name=name

proc on_output_position(data: pointer, output: ptr RiverOutputV1, x: int32, y: int32) =
  info "Output position changed", outputId=output.get_id(), x=x, y=y
  msgQueue.add(Msg(kind: WlOutputPosition, positionOutputId: output.get_id(), outputX: x, outputY: y))

# Listener setup
var 
  manager_listener: RiverWindowManagerV1Listener
  output_listener: RiverOutputV1Listener

proc on_output(data: pointer, mgr: ptr RiverWindowManagerV1, output: ptr RiverOutputV1) =
  let id = output.get_id()
  info "Output discovered", outputId=id
  outputPointers[id] = output
  discard output.addListener(output_listener.addr, nil)
  attachLayerOutput(id)

proc on_seat(data: pointer, mgr: ptr RiverWindowManagerV1, seat: ptr RiverSeatV1) =
  info "Seat discovered", seatIndex=seatPointers.len
  seatPointers.add(seat)
  discard seat.addListener(seat_listener.addr, nil)
  attachLayerSeat(seat)
  bindingsConfigured = false
  requestManage("seat discovered")

# --- Registry Callbacks ---

proc registry_handle_global(data: pointer, registry: ptr Registry, name: uint32, interface_name: cstring, version: uint32) =
  let interfaceName = $interface_name
  debug "Wayland global advertised", name=name, interfaceName=interfaceName, version=version
  # Bind to the river_window_manager_v1 interface
  if interfaceName == "river_window_manager_v1":
    if version < 4'u32:
      fatal "river_window_manager_v1 v4 is required", advertisedVersion=version
      quit 1
    river_manager = cast[ptr RiverWindowManagerV1](registry.`bind`(name, river_window_manager_v1_interface.addr, 4'u32))
    discard river_manager.addListener(manager_listener.addr, nil)
    info "Bound to river_window_manager_v1", name=name, advertisedVersion=version, boundVersion=4
  elif interfaceName == "river_layer_shell_v1":
    river_layer_shell = cast[ptr river_layer.RiverLayerShellV1](registry.`bind`(name, river_layer.river_layer_shell_v1_interface.addr, min(version, 1'u32)))
    for outputId in outputPointers.keys:
      attachLayerOutput(outputId)
    for seat in seatPointers:
      attachLayerSeat(seat)
    info "Bound to river_layer_shell_v1", name=name, advertisedVersion=version
  elif interfaceName == "river_xkb_bindings_v1":
    river_xkb_bindings = cast[ptr river_xkb.RiverXkbBindingsV1](registry.`bind`(name, river_xkb.river_xkb_bindings_v1_interface.addr, min(version, 3'u32)))
    bindingsConfigured = false
    requestManage("xkb bindings discovered")
    info "Bound to river_xkb_bindings_v1", name=name, advertisedVersion=version


proc registry_handle_global_remove(data: pointer, registry: ptr Registry, name: uint32) =
  debug "Wayland global removed", name=name

var registry_listener = RegistryListener(
  global: registry_handle_global,
  globalRemove: registry_handle_global_remove
)

proc startAnimationLoop() {.async.} =
  while true:
    {.cast(gcsafe).}:
      msgQueue.add(Msg(kind: CmdTick))
    await sleepAsync(16) # ~60fps

# --- Main Loop ---

proc main() =
  configureLogging()

  if paramCount() >= 2 and paramStr(1) == "msg":
    let cmdPart = paramStr(2)
    if cmdPart == "event-stream":
      # Subscription client
      let client = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
      try:
        waitFor client.connectUnix(getTriadSocketPath())
        waitFor client.send("event-stream\L")
        while not client.isClosed:
          let line = waitFor client.recvLine()
          if line != "": echo line
      except CatchableError as e:
        if not client.isClosed:
          client.close()
        failCli("event stream failed: " & e.msg)
      return

    var cmd = ""
    for i in 2 .. paramCount():
      if i > 2: cmd.add(" ")
      cmd.add(paramStr(i))
    try:
      waitFor sendIpcMsg(getTriadSocketPath(), cmd)
    except CatchableError as e:
      failCli("socket request failed: " & e.msg)
    return

  info "Triad process starting",
    pid=getCurrentProcessId(),
    runtimeDir=getRuntimeDir(),
    waylandDisplay=getEnv("WAYLAND_DISPLAY", "")

  # Initialize Model
  currentModel = Model(
    activeTag: 1
  )

  # Setup and Load Config
  setupConfig()
  let initialConfig = loadConfig(configPath)
  currentModel.applyConfig(initialConfig)
  info "Initial config loaded", path=configPath

  # Setup Watcher
  watcher = initWatcher()
  proc onConfigChange(events: seq[PathEvent]) {.gcsafe.} =
    {.cast(gcsafe).}:
      msgQueue.add(Msg(kind: CmdReloadConfig))
  
  watcher.register(configPath, onConfigChange)

  # Start IPC Server
  proc queueMsg(msg: Msg) {.gcsafe.} =
    {.cast(gcsafe).}:
      msgQueue.add(msg)

  proc snapshotModel(): Model {.gcsafe.} =
    {.cast(gcsafe).}:
      currentModel

  let triadSocketPath = getTriadSocketPath()
  info "Starting Triad IPC server", path=triadSocketPath
  asyncCheck startIpcServer(triadSocketPath, queueMsg, snapshotModel)

  let niriSocketPath = getEnv("NIRI_SOCKET", "")
  if niriSocketPath.len > 0 and niriSocketPath != triadSocketPath:
    if fileExists(niriSocketPath):
      warn "NIRI_SOCKET already exists; not replacing another compositor socket", path=niriSocketPath
    else:
      info "Starting Niri-compatible IPC server", path=niriSocketPath
      asyncCheck startIpcServer(niriSocketPath, queueMsg, snapshotModel)

  # Start Animation Loop
  asyncCheck startAnimationLoop()

  display = connectDisplay(nil)
  if display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  registry = display.getRegistry()
  discard registry.addListener(registry_listener.addr, nil)

  # Roundtrip to get the globals and listeners
  let roundtripResult = display.roundtrip()
  debug "Wayland registry roundtrip finished", result=roundtripResult

  if river_manager == nil:
    fatal "river_window_manager_v1 not advertised; Triad must run inside River 0.4+"
    quit 1

  info "Triad connected to River", outputs=outputPointers.len, seats=seatPointers.len
  
  # Spawn startup commands (e.g. Noctalia shell)
  spawnStartupCommands(currentModel)
  spawnQuickshell(currentModel)
  
  while display.dispatch() != -1:
    # Poll watcher (non-blocking)
    watcher.poll(0)
    
    # Poll async (IPC)
    asyncdispatch.poll(0)

    # Process Message Queue
    while msgQueue.len > 0:
      let msg = msgQueue[0]
      msgQueue.delete(0)
      
      if msg.kind == WlPointerRelease:
        if currentModel.pointerOp.kind != OpNone:
          if lastPointerOpSeat != nil:
            executeEffect(Effect(kind: EffOpEnd, endSeat: lastPointerOpSeat))

      if msg.kind == CmdSpawnTerminal:
        spawnTerminal()
        continue

      if msg.kind == CmdReloadConfig:
        let config = loadConfig(configPath)
        currentModel.applyConfig(config)
        info "Config reloaded", path=configPath
        requestManage("config reload")
        continue

      let (nextModel, effects) = update(currentModel, msg)
      currentModel = nextModel

      if msg.kind == WlManageStart:
        riverPhase = RiverManage
        let instructions = computeLayoutInstructions(currentModel)
        proposeDesiredDimensions(instructions)
        applyManageState()
        flushPendingManageEffects()
        executeEffect(Effect(kind: EffManageFinish))
        riverPhase = RiverIdle
        continue

      if msg.kind == WlRenderStart:
        riverPhase = RiverRender
        if desiredPlacements.len == 0:
          let instructions = computeLayoutInstructions(currentModel)
          for instr in instructions:
            desiredPlacements[instr.windowId] = instr.geom
        renderDesiredPlacements()
        executeEffect(Effect(kind: EffRenderFinish))
        riverPhase = RiverIdle
        continue

      for eff in effects:
        executeEffect(eff)

if isMainModule:
  # Initialize listeners
  manager_listener = RiverWindowManagerV1Listener(
    unavailable: on_manager_unavailable,
    finished: on_manager_finished,
    manageStart: on_manage_start,
    renderStart: on_render_start,
    sessionLocked: on_session_locked,
    sessionUnlocked: on_session_unlocked,
    window: on_window,
    output: on_output,
    seat: on_seat
  )
  output_listener = RiverOutputV1Listener(
    removed: on_output_removed,
    output: on_output_wl_output,
    position: on_output_position,
    dimensions: on_output_dimensions
  )
  
  main()
