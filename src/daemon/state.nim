import std/[deques, options, tables]
import fsnotify
import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import ../core/[effects, msg, restore_state]
import ../config/reload_policy
import ../types/[runtime_state, runtime_values]
import protocol_surfaces, quickshell_runner

type
  RiverPhase* {.pure.} = enum
    RiverIdle,
    RiverManage,
    RiverRender

  WlOutputListenerData* = object
    daemon*: ptr TriadDaemon
    globalName*: uint32

  TriadDaemon* = object
    display*: ptr Display
    registry*: ptr Registry
    riverManager*: ptr RiverWindowManagerV1
    riverLayerShell*: ptr riverLayer.RiverLayerShellV1
    riverXkbBindings*: ptr riverXkb.RiverXkbBindingsV1
    compositor*: ptr Compositor
    shm*: ptr Shm
    singlePixelManager*: ptr singlepixel.WpSinglePixelBufferManagerV1
    riverPhase*: RiverPhase
    bindingsConfigured*: bool
    manageRequestPending*: bool
    manageRequestReason*: string
    screenshotCaptureActive*: bool
    shmBufferCounter*: uint32

    runtimeState*: TriadRuntimeState
    msgQueue*: Deque[Msg]
    pendingManageEffects*: seq[Effect]
    desiredPlacements*: Table[WindowId, Rect]
    desiredPlacementOrder*: seq[WindowId]
    lastPointerOpSeat*: pointer
    pendingMaximizedAcks*: Table[WindowId, bool]

    windowPointers*: Table[WindowId, ptr RiverWindowV1]
    windowNodes*: Table[WindowId, ptr RiverNodeV1]
    outputPointers*: Table[uint32, ptr RiverOutputV1]
    layerOutputPointers*: Table[uint32, ptr riverLayer.RiverLayerShellOutputV1]
    layerOutputOwners*: Table[uint32, uint32]
    seatPointers*: seq[ptr RiverSeatV1]
    layerSeatPointers*: seq[ptr riverLayer.RiverLayerShellSeatV1]
    xkbBindings*: Table[uint32, Msg]
    xkbBindingPointers*: seq[ptr riverXkb.RiverXkbBindingV1]
    xkbSeatPointers*: Table[uint32, ptr riverXkb.RiverXkbBindingsSeatV1]
    xkbSeatAteUnbound*: Table[uint32, uint32]
    xkbBindingPressed*: Table[uint32, bool]
    xkbBindingModes*: Table[uint32, BindingMode]
    xkbStopRepeatCount*: Table[uint32, uint32]
    pointerBindings*: Table[uint32, Msg]
    pointerBindingKinds*: Table[uint32, PointerOpKind]
    pointerBindingSeats*: Table[uint32, ptr RiverSeatV1]
    pointerBindingPointers*: seq[ptr RiverPointerBindingV1]
    pointerBindingPressed*: Table[uint32, bool]
    shellSurfacePointers*: Table[uint32, ptr RiverShellSurfaceV1]
    protocolSurfaceRuntime*: ProtocolSurfaceRuntime
    outputWlNames*: Table[uint32, uint32]
    outputGlobalOwners*: Table[uint32, uint32]
    outputGlobalNames*: Table[uint32, string]
    wlOutputPointers*: Table[uint32, ptr Output]
    wlOutputListenerData*: Table[uint32, ref WlOutputListenerData]
    seatWlNames*: Table[uint32, uint32]
    pointerWindowBySeat*: Table[uint32, WindowId]
    pointerPositionBySeat*: Table[uint32, Rect]
    windowUnreliablePids*: Table[WindowId, int32]
    pendingWindows*: Table[WindowId, WindowData]

    configPath*: string
    watcher*: Watcher
    configReloadDebouncer*: ConfigReloadDebouncer
    shouldExit*: bool
    quickshellState*: QuickshellRunner
    startupCommandsPending*: bool
    initialManageComplete*: bool
    pendingLiveRestorePath*: string
    pendingLiveRestore*: Option[LiveRestoreState]
    liveRestoreCommitPending*: bool

proc initTriadDaemon*(): TriadDaemon =
  result.riverPhase = RiverPhase.RiverIdle
  result.msgQueue = initDeque[Msg]()
  result.pendingManageEffects = @[]
  result.desiredPlacementOrder = @[]
  result.seatPointers = @[]
  result.layerSeatPointers = @[]
  result.xkbBindingPointers = @[]
  result.pointerBindingPointers = @[]
  result.pendingLiveRestore = none(LiveRestoreState)

proc daemonData*(daemon: var TriadDaemon): pointer =
  cast[pointer](addr daemon)

proc daemonFromData*(data: pointer): ptr TriadDaemon =
  if data == nil:
    nil
  else:
    cast[ptr TriadDaemon](data)

proc expectMaximizedAck*(
    daemon: var TriadDaemon; id: WindowId; maximized: bool) =
  if id == 0:
    return
  daemon.pendingMaximizedAcks[id] = maximized

proc consumeMaximizedAck*(
    daemon: var TriadDaemon; id: WindowId; maximized: bool): bool =
  if not daemon.pendingMaximizedAcks.hasKey(id):
    return false
  if daemon.pendingMaximizedAcks[id] != maximized:
    return false
  daemon.pendingMaximizedAcks.del(id)
  true
