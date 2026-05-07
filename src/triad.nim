import wayland/native/client
import protocols/river/client as river
import core/model
import core/msg
import core/update
import layouts/scroller
import layouts/tiling
import config/parser
import ipc/socket
import tables, os, fsnotify, asyncdispatch, chronicles, algorithm

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

proc getTiledTagState(tag: TagState, model: Model): TagState =
  # Helper to get a TagState with only non-floating windows
  result = tag
  result.columns = @[]
  for col in tag.columns:
    var filteredWindows: seq[WindowId] = @[]
    for winId in col.windows:
      if model.windows.hasKey(winId) and not model.windows[winId].isFloating:
        filteredWindows.add(winId)
    if filteredWindows.len > 0:
      var filteredCol = col
      filteredCol.windows = filteredWindows
      result.columns.add(filteredCol)

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
  of EffManageDirty:
    if river_manager != nil:
      river_manager.manageDirty()
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

# Mapping from logical IDs to window metadata for late creation
var pendingWindows: Table[WindowId, WindowData]

# --- RiverWindowV1 Callbacks ---

proc on_window_app_id(data: pointer, win: ptr RiverWindowV1, appId: cstring) =
  let id = win.get_id()
  if pendingWindows.hasKey(id):
    pendingWindows[id].appId = $appId
  elif currentModel.windows.hasKey(id):
    # Already created, maybe update and re-render?
    discard

proc on_window_title(data: pointer, win: ptr RiverWindowV1, title: cstring) =
  let id = win.get_id()
  if pendingWindows.hasKey(id):
    pendingWindows[id].title = $title

proc on_window_closed(data: pointer, win: ptr RiverWindowV1) =
  let id = win.get_id()
  msgQueue.add(Msg(kind: WlWindowDestroyed, destroyedId: id))

var window_listener = RiverWindowV1Listener(
  appId: on_window_app_id,
  title: on_window_title,
  closed: on_window_closed
)

# --- Wayland Callbacks ---

proc on_manage_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  # Before starting manage, move all pending windows to the message queue
  for id, data in pendingWindows:
    msgQueue.add(Msg(kind: WlWindowCreated, windowId: id, appId: data.appId, title: data.title))
  pendingWindows.clear()
  msgQueue.add(Msg(kind: WlManageStart))

proc on_render_start(data: pointer, mgr: ptr RiverWindowManagerV1) =
  msgQueue.add(Msg(kind: WlRenderStart))

proc on_window(data: pointer, mgr: ptr RiverWindowManagerV1, win: ptr RiverWindowV1) =
  let id = win.get_id()
  windowPointers[id] = win
  windowNodes[id] = win.getNode()
  # Start tracking as pending until we get metadata or manage starts
  pendingWindows[id] = WindowData(id: id, appId: "unknown", title: "unknown")
  discard win.addListener(window_listener.addr, nil)

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
  if $interface_name == "river_window_manager_v1":
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
    var cmd = ""
    for i in 2 .. paramCount():
      if i > 2: cmd.add(" ")
      cmd.add(paramStr(i))
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
        
        var instructions: seq[RenderInstruction] = @[]

        if currentModel.overviewActive:
          # --- OVERVIEW MODE ---
          # Aggregate all windows from all tags into a dummy TagState for the grid layout
          var overviewTag = TagState(tagId: 0, layoutMode: Grid)
          # Sort tag IDs for consistent navigation order
          var tagIds: seq[uint32] = @[]
          for id in currentModel.tags.keys: tagIds.add(id)
          tagIds.sort()
          for id in tagIds:
            let tag = currentModel.tags[id]
            for col in tag.columns:
              for win in col.windows:
                overviewTag.columns.add(Column(windows: @[win], widthProportion: 1.0))
          
          # Use large gaps for overview
          instructions = layoutGrid(overviewTag, screen, 64, currentModel.innerGaps * 2)
          
        elif currentModel.tags.hasKey(currentModel.activeTag):
          # --- NORMAL MODE ---
          let originalTag = currentModel.tags[currentModel.activeTag]
          let tiledTag = getTiledTagState(originalTag, currentModel)
          
          instructions = case tiledTag.layoutMode
            of Scroller:
              layoutScroller(tiledTag, screen, currentModel.outerGaps, currentModel.innerGaps,
                             currentModel.scrollerFocusCenter, currentModel.scrollerPreferCenter,
                             currentModel.centerFocusedColumn)
            of VerticalScroller:
              layoutVerticalScroller(tiledTag, screen, currentModel.outerGaps, currentModel.innerGaps,
                                     currentModel.scrollerFocusCenter, currentModel.scrollerPreferCenter,
                                     currentModel.centerFocusedColumn)
            of MasterStack:
              layoutMasterStack(tiledTag, screen, currentModel.outerGaps, currentModel.innerGaps)
            of Grid:
              layoutGrid(tiledTag, screen, currentModel.outerGaps, currentModel.innerGaps)
            of Monocle:
              layoutMonocle(tiledTag, screen, currentModel.outerGaps)

          # Add floating windows on top
          for col in originalTag.columns:
            for winId in col.windows:
              if currentModel.windows.hasKey(winId):
                let winData = currentModel.windows[winId]
                if winData.isFloating:
                  instructions.add(RenderInstruction(
                    windowId: winId,
                    geom: winData.floatingGeom
                  ))

        for instr in instructions:
          # Execute set_position effects
          if windowNodes.hasKey(instr.windowId):
            let node = windowNodes[instr.windowId]
            node.setPosition(instr.geom.x, instr.geom.y)
            
            # Place floating windows on top
            if currentModel.windows.hasKey(instr.windowId) and currentModel.windows[instr.windowId].isFloating:
              node.placeTop()

          if windowPointers.hasKey(instr.windowId):
            let win = windowPointers[instr.windowId]
            win.proposeDimensions(instr.geom.w, instr.geom.h)
        
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
