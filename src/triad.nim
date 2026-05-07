import wayland/native/client
import protocols/river/client as river
import core/model
import core/msg
import core/update
import layouts/scroller
import config/parser
import ipc/socket
import tables, os, fsnotify, asyncdispatch, chronicles

# --- Global Engine State ---
var
  display: ptr Display
  registry: ptr Registry
  river_manager: ptr RiverWindowManagerV1
  
  # TEA State
  currentModel: Model
  msgQueue: seq[Msg] = @[]
  
  # Mapping from logical IDs to Wayland pointers
  windowPointers: Table[WindowId, ptr RiverWindowV1]
  windowNodes: Table[WindowId, ptr RiverNodeV1]
  outputPointers: Table[uint32, ptr RiverOutputV1]
  seatPointers: seq[ptr RiverSeatV1] = @[]

  # Config Watcher
  configPath: string
  watcher: Watcher

# --- Helpers ---

proc get_id(p: pointer): uint32 =
  get_id(cast[ptr Proxy](p))

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
}

tag-rules {
    tag 1 default-layout="scroller"
    tag 2 default-layout="tile"
    tag 3 default-layout="grid"
    tag 4 default-layout="monocle"
}
"""
    writeFile(configPath, defaultContent)
    info "Created default config", path=configPath

# --- Effects Execution ---

proc executeEffect(eff: Effect) =
  case eff.kind
  of EffLog:
    info "log", msg=eff.msg
  of EffManageFinish:
    if river_manager != nil:
      river_manager.manageFinish()
  of EffRenderFinish:
    if river_manager != nil:
      river_manager.renderFinish()
  of EffSetPosition:
    if windowNodes.hasKey(eff.windowId):
      let node = windowNodes[eff.windowId]
      node.setPosition(eff.x, eff.y)
    if windowPointers.hasKey(eff.windowId):
      let win = windowPointers[eff.windowId]
      win.proposeDimensions(eff.w, eff.h)
  of EffFocusWindow:
    if windowPointers.hasKey(eff.focusId):
      let win = windowPointers[eff.focusId]
      for seat in seatPointers:
        seat.focusWindow(win)
  else:
    discard

# --- Wayland Callbacks ---

proc on_manage_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  msgQueue.add(Msg(kind: WlManageStart))

proc on_render_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  msgQueue.add(Msg(kind: WlRenderStart))

proc on_window(data: pointer, mgr: ptr RiverWindowManagerV1, win: ptr RiverWindowV1) =
  let id = win.get_id()
  windowPointers[id] = win
  # Get the node for this window to control its position
  windowNodes[id] = win.getNode()
  msgQueue.add(Msg(kind: WlWindowCreated, windowId: id, appId: "unknown", title: "unknown"))

proc on_output_dimensions(data: pointer, output: ptr RiverOutputV1, width: int32, height: int32) =
  msgQueue.add(Msg(kind: WlOutputDimensions, width: width, height: height))

# Listener setup
var 
  manager_listener: RiverWindowManagerV1Listener
  output_listener: RiverOutputV1Listener

proc on_output(data: pointer, mgr: ptr RiverWindowManagerV1, output: ptr RiverOutputV1) =
  let id = output.get_id()
  outputPointers[id] = output
  discard output.addListener(output_listener.addr, nil)

proc on_seat(data: pointer, mgr: ptr RiverWindowManagerV1, seat: ptr RiverSeatV1) =
  seatPointers.add(seat)

# --- Registry Callbacks ---

proc registry_handle_global(data: pointer, registry: ptr Registry, name: uint32, interface_name: cstring, version: uint32) =
  # Bind to the river_window_manager_v1 interface
  river_manager = cast[ptr RiverWindowManagerV1](registry.`bind`(name, river_window_manager_v1_interface.addr, 4))
  discard river_manager.addListener(manager_listener.addr, nil)
  info "Bound to river_window_manager_v1"


proc registry_handle_global_remove(data: pointer, registry: ptr Registry, name: uint32) =
  discard

var registry_listener = RegistryListener(
  global: registry_handle_global,
  globalRemove: registry_handle_global_remove
)

# --- Main Loop ---

proc main() =
  if paramCount() >= 2 and paramStr(1) == "msg":
    let cmd = paramStr(2)
    waitFor sendIpcMsg(getTriadSocketPath(), cmd)
    return

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
  asyncCheck startIpcServer(getTriadSocketPath(), proc(msg: Msg) =
    {.cast(gcsafe).}:
      msgQueue.add(msg)
  )

  display = connectDisplay(nil)
  if display == nil:
    fatal "Failed to connect to Wayland display"
    quit 1

  registry = display.getRegistry()
  discard registry.addListener(registry_listener.addr, nil)

  info "Triad starting..."
  
  while display.dispatch() != -1:
    # Poll watcher (non-blocking)
    watcher.poll(0)
    
    # Poll async (IPC)
    asyncdispatch.poll(0)

    # Process Message Queue
    while msgQueue.len > 0:
      let msg = msgQueue[0]
      msgQueue.delete(0)
      
      if msg.kind == CmdReloadConfig:
        let config = loadConfig(configPath)
        currentModel.applyConfig(config)
        info "Config reloaded"
        # Force a re-render
        if river_manager != nil:
          river_manager.manageDirty()
        continue

      let (nextModel, effects) = update(currentModel, msg)
      currentModel = nextModel
      
      # Handle View phase during RenderStart
      if msg.kind == WlRenderStart:
        let screen = Rect(x: 0, y: 0, w: currentModel.screenWidth, h: currentModel.screenHeight)
        if currentModel.tags.hasKey(currentModel.activeTag):
          let tag = currentModel.tags[currentModel.activeTag]
          let instructions = layoutScroller(tag, screen, currentModel.outerGaps, currentModel.innerGaps,
                                            currentModel.scrollerFocusCenter, currentModel.scrollerPreferCenter,
                                            currentModel.centerFocusedColumn)
          for instr in instructions:
            executeEffect(Effect(kind: EffSetPosition, windowId: instr.windowId, 
                                 x: instr.geom.x, y: instr.geom.y, 
                                 w: instr.geom.w, h: instr.geom.h))
        
        # Must finish render
        executeEffect(Effect(kind: EffRenderFinish))
      
      for eff in effects:
        executeEffect(eff)

if isMainModule:
  # Initialize listeners
  manager_listener = RiverWindowManagerV1Listener(
    manageStart: on_manage_start,
    renderStart: on_render_start,
    window: on_window,
    output: on_output,
    seat: on_seat
  )
  output_listener = RiverOutputV1Listener(
    dimensions: on_output_dimensions
  )
  
  main()
