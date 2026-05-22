import std/[deques, options, osproc, sets, tables, times]
import fsnotify
from posix import TPollfd
import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import protocols/river_xkb_bindings/client as riverXkb
import protocols/wlr_output_management/client as wlrOutput
import wayland/protocols/staging/cursorshape/v1/client as cursorShape
import wayland/protocols/staging/singlepixelbuffer/v1/client as singlepixel
import wayland/protocols/unstable/idleinhibitunstable/v1/client as idle
import wayland/protocols/unstable/pointergesturesunstable/v1/client as pointerGestures
import ../core/[effects, msg, restore_state]
import ../config/reload_policy
import ../janet/runtime
import ../types/[projection_values, runtime_state, runtime_values]
import cursor_shake, protocol_surfaces, quickshell_runner

type
  RiverPhase* {.pure.} = enum
    RiverIdle
    RiverManage
    RiverRender

  QueuedMsgOrigin* {.pure.} = enum
    Normal
    JanetHook

  QueuedMsg* = object
    msg*: Msg
    origin*: QueuedMsgOrigin

  IpcBroadcastKind* {.pure.} = enum
    Niri
    Triad

  PendingIpcBroadcast* = object
    kind*: IpcBroadcastKind
    eventName*: string
    payload*: string

  WlOutputListenerData* = object
    daemon*: ptr TriadDaemon
    globalName*: uint32

  WlSeatListenerData* = object
    daemon*: ptr TriadDaemon
    globalName*: uint32

  WlrOutputHeadListenerData* = object
    daemon*: ptr TriadDaemon
    headId*: uint32

  WlrOutputModeListenerData* = object
    daemon*: ptr TriadDaemon
    modeId*: uint32

  WlrOutputConfigListenerData* = object
    daemon*: ptr TriadDaemon
    serial*: uint32
    monitorPowerCompletionSet*: bool
    monitorPowerRestoreHeadIds*: seq[uint32]

  OutputManagementModeRuntime* = object
    pointer*: ptr wlrOutput.ZwlrOutputModeV1
    headId*: uint32
    width*: int32
    height*: int32
    refresh*: int32
    preferred*: bool
    finished*: bool

  OutputManagementHeadRuntime* = object
    pointer*: ptr wlrOutput.ZwlrOutputHeadV1
    name*: string
    description*: string
    make*: string
    modelName*: string
    serialNumber*: string
    physicalWidth*: int32
    physicalHeight*: int32
    enabled*: bool
    enabledSet*: bool
    currentModeId*: uint32
    x*: int32
    y*: int32
    positionSet*: bool
    transform*: int32
    transformSet*: bool
    scale*: float32
    scaleSet*: bool
    adaptiveSync*: bool
    adaptiveSyncSet*: bool
    modeIds*: seq[uint32]
    finished*: bool

  WlPointerWheelFrame* = object
    hasSource*: bool
    source*: uint32
    horizontal120*: int32
    vertical120*: int32
    horizontalDiscrete*: int32
    verticalDiscrete*: int32

  WlPointerWheelRemainder* = object
    horizontal120*: int32
    vertical120*: int32

  WlSwipeState* = object
    active*: bool
    fingers*: uint32
    dx*: float64
    dy*: float64

  InputDeviceRuntime* = object
    pointer*: pointer
    deviceType*: uint32
    name*: string
    done*: bool

  LibinputDeviceRuntime* = object
    pointer*: pointer
    inputDeviceId*: uint32
    done*: bool
    sendEventsSupport*: uint32
    sendEventsCurrent*: uint32
    sendEventsCurrentSet*: bool
    tapFingerCount*: int32
    accelProfilesSupport*: uint32
    accelProfileCurrent*: uint32
    accelProfileCurrentSet*: bool
    accelSpeedCurrent*: float32
    accelSpeedCurrentSet*: bool
    naturalScrollSupport*: bool
    naturalScrollCurrent*: bool
    naturalScrollCurrentSet*: bool
    leftHandedSupport*: bool
    leftHandedCurrent*: bool
    leftHandedCurrentSet*: bool
    clickMethodsSupport*: uint32
    middleEmulationSupport*: bool
    middleEmulationCurrent*: bool
    middleEmulationCurrentSet*: bool
    scrollMethodsSupport*: uint32
    dwtSupport*: bool
    dwtpSupport*: bool

  XkbKeyboardRuntime* = object
    pointer*: pointer
    inputDeviceId*: uint32

  XkbKeymapRuntime* = object
    pointer*: pointer
    fd*: int32
    successful*: bool

  SwitchEventDeviceRuntime* = object
    fd*: int32
    path*: string

  RenderWindowState* = object
    visible*: bool
    geom*: Rect
    clipSet*: bool
    clip*: Rect
    forceClip*: bool
    borderWidth*: int32
    renderBorderWidth*: int32
    borderActiveColor*: uint32
    borderInactiveColor*: uint32
    borderEdges*: uint32
    focused*: bool

  ProposedDimensions* = object
    w*: int32
    h*: int32

  RenderPerfCounters* = object
    frameTicks*: uint64
    activeFrameTicks*: uint64
    dirtyFrameTicks*: uint64
    renderStarts*: uint64
    skippedRenderStarts*: uint64
    renderLayoutProjections*: uint64
    renderRequests*: uint64
    skippedRenderRequests*: uint64
    manageRequests*: uint64
    skippedAnimationManages*: uint64
    renderStartCallbackSkips*: uint64
    renderStartQueuedSkips*: uint64
    dimensionProposals*: uint64
    skippedDimensionProposals*: uint64

  RuntimeLoopCounters* = object
    loopIterations*: uint64
    watcherPolls*: uint64
    switchPolls*: uint64
    childReapPolls*: uint64
    childReapedProcesses*: uint64
    memorySampleChecks*: uint64
    memoryCompactionChecks*: uint64
    asyncPolls*: uint64
    configReloadChecks*: uint64
    configReloadsDue*: uint64
    shellWatchdogPolls*: uint64
    shellRecoveryPolls*: uint64
    manageFlushChecks*: uint64
    waylandWakeups*: uint64
    asyncWakeups*: uint64
    switchWakeups*: uint64

  FullscreenRequestState* = object
    active*: bool
    outputId*: uint32

  SpawnPlacementContext* = object
    pid*: int32
    outputId*: uint32
    slot*: uint32
    createdMs*: int64
    remainingManageCycles*: int

  RuntimeReasonHook* = proc(daemon: pointer, reason: string) {.nimcall.}
  ConfigNotificationHook* = proc(
    daemon: pointer, event: ConfigNotificationEvent, command: seq[string]
  ) {.nimcall.}

  TriadDaemon* = object
    display*: ptr Display
    startUnixMs*: int64
    registry*: ptr Registry
    riverManager*: ptr RiverWindowManagerV1
    riverInputManager*: pointer
    riverLibinputConfig*: pointer
    riverXkbConfig*: pointer
    riverLayerShell*: ptr riverLayer.RiverLayerShellV1
    riverXkbBindings*: ptr riverXkb.RiverXkbBindingsV1
    wlrOutputManager*: ptr wlrOutput.ZwlrOutputManagerV1
    wlrOutputManagerGlobalName*: uint32
    wlrOutputSerial*: uint32
    wlrOutputReady*: bool
    wlrOutputApplyInFlight*: bool
    wlrOutputRetryPending*: bool
    wlrOutputRetryCount*: int
    wlrOutputHeads*: Table[uint32, OutputManagementHeadRuntime]
    wlrOutputModes*: Table[uint32, OutputManagementModeRuntime]
    wlrOutputHeadListenerData*: Table[uint32, ref WlrOutputHeadListenerData]
    wlrOutputModeListenerData*: Table[uint32, ref WlrOutputModeListenerData]
    wlrOutputConfig*: ptr wlrOutput.ZwlrOutputConfigurationV1
    wlrOutputConfigListenerData*: ref WlrOutputConfigListenerData
    monitorPowerOffActive*: bool
    monitorPowerRestoreHeadIds*: seq[uint32]
    compositor*: ptr Compositor
    shm*: ptr Shm
    cursorShapeManager*: ptr cursorShape.WpCursorShapeManagerV1
    cursorShapeGlobalName*: uint32
    pointerGestures*: ptr pointerGestures.ZwpPointerGesturesV1
    pointerGesturesGlobalName*: uint32
    singlePixelManager*: ptr singlepixel.WpSinglePixelBufferManagerV1
    idleInhibitManager*: ptr idle.ZwpIdleInhibitManagerV1
    idleInhibitGlobalName*: uint32
    idleInhibitor*: ptr idle.ZwpIdleInhibitorV1
    idleInhibitSurface*: ptr Surface
    idleInhibitBuffer*: ptr Buffer
    idleInhibitDesired*: bool
    idleInhibitUnavailableWarned*: bool
    riverPhase*: RiverPhase
    bindingsConfigured*: bool
    bindingsReconfigurePending*: bool
    hotkeyOverlayKeyEatArmed*: bool
    manageRequestPending*: bool
    manageRequestReason*: string
    activeManageReason*: string
    screenshotCaptureActive*: bool
    shmBufferCounter*: uint32

    runtimeState*: TriadRuntimeState
    janetRuntime*: JanetRuntime
    msgQueue*: Deque[QueuedMsg]
    pendingIpcBroadcasts*: seq[PendingIpcBroadcast]
    pendingManageEffects*: seq[Effect]
    desiredPlacements*: Table[uint32, Rect]
    desiredPlacementClips*: Table[uint32, Rect]
    desiredPlacementOrder*: seq[uint32]
    lastProposedDimensions*: Table[uint32, ProposedDimensions]
    currentFrameTabBars*: seq[ProjectedFrameTabBar]
    currentFrameTabBarsBySurface*: Table[uint32, ProjectedFrameTabBar]
    currentFrameEmptyChrome*: seq[ProjectedFrameEmptyChrome]
    currentBspPreselections*: seq[ProjectedBspPreselection]
    lastRenderWindowStates*: Table[uint32, RenderWindowState]
    lastRenderOrder*: seq[uint32]
    lastFrameTickMs*: int64
    lastWaitTimeoutMs*: int
    waitBackend*: string
    renderDirty*: bool
    renderDirtyReason*: string
    eventPollFds*: seq[TPollfd]
    eventSwitchFds*: seq[int32]
    perfCounters*: RenderPerfCounters
    loopCounters*: RuntimeLoopCounters
    lastRuntimeLoopSampleMs*: int64
    lastRuntimeLoopSampleCounters*: RuntimeLoopCounters
    lastRuntimeLoopSamplePerfCounters*: RenderPerfCounters
    lastRuntimeLoopSampleFrameTickReasonCounts*: Table[string, uint64]
    lastRuntimeLoopSampleManageRequestReasonCounts*: Table[string, uint64]
    lastRuntimeLoopSampleMessageKindCounts*: Table[string, uint64]
    lastRuntimeLoopSampleEffectKindCounts*: Table[string, uint64]
    lastRuntimeLoopSampleIpcEventCounts*: Table[string, uint64]
    frameTickReasonCounts*: Table[string, uint64]
    manageRequestReasonCounts*: Table[string, uint64]
    messageKindCounts*: Table[string, uint64]
    effectKindCounts*: Table[string, uint64]
    lastFullscreenRequests*: Table[uint32, FullscreenRequestState]
    lastMaximizedRequests*: Table[uint32, bool]
    lastPointerOpSeat*: pointer
    pendingMaximizedAcks*: Table[uint32, bool]
    windowReadyEmitted*: HashSet[uint32]

    windowPointers*: Table[uint32, ptr RiverWindowV1]
    windowNodes*: Table[uint32, ptr RiverNodeV1]
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
    xkbBindingOnRelease*: Table[uint32, bool]
    xkbBindingReleaseArmed*: Table[uint32, bool]
    xkbBindingWhileLocked*: Table[uint32, bool]
    xkbBindingModes*: Table[uint32, BindingMode]
    xkbBindingModifiers*: Table[uint32, uint32]
    xkbStopRepeatCount*: Table[uint32, uint32]
    pointerBindings*: Table[uint32, Msg]
    pointerBindingKinds*: Table[uint32, PointerOpKind]
    pointerBindingSeats*: Table[uint32, ptr RiverSeatV1]
    pointerBindingButtons*: Table[uint32, uint32]
    pointerBindingPointers*: seq[ptr RiverPointerBindingV1]
    pointerBindingPressed*: Table[uint32, bool]
    shellSurfacePointers*: Table[uint32, ptr RiverShellSurfaceV1]
    protocolSurfaceRuntime*: ProtocolSurfaceRuntime
    outputWlNames*: Table[uint32, uint32]
    outputGlobalOwners*: Table[uint32, uint32]
    outputGlobalNames*: Table[uint32, string]
    outputGlobalIdentities*: Table[uint32, tuple[make, modelName: string]]
    outputGlobalDescriptions*: Table[uint32, string]
    outputGlobalRefreshRates*: Table[uint32, int32]
    outputGlobalPhysicalMetadata*:
      Table[uint32, tuple[physicalWidth, physicalHeight, transform: int32]]
    outputGlobalScales*: Table[uint32, float32]
    wlOutputPointers*: Table[uint32, ptr Output]
    wlOutputListenerData*: Table[uint32, ref WlOutputListenerData]
    seatWlNames*: Table[uint32, uint32]
    wlSeatPointers*: Table[uint32, ptr Seat]
    wlSeatListenerData*: Table[uint32, ref WlSeatListenerData]
    wlPointerPointers*: Table[uint32, ptr Pointer]
    wlPointerGlobalNames*: Table[uint32, uint32]
    wlPointerRiverSeats*: Table[uint32, uint32]
    wlPointerWheelFrames*: Table[uint32, WlPointerWheelFrame]
    wlPointerWheelRemainders*: Table[uint32, WlPointerWheelRemainder]
    wlPointerSurfaceIds*: Table[uint32, uint32]
    wlPointerSurfaceXs*: Table[uint32, int32]
    wlPointerSurfaceYs*: Table[uint32, int32]
    wlSwipePointers*: Table[uint32, ptr pointerGestures.ZwpPointerGestureSwipeV1]
    wlSwipePointerIds*: Table[uint32, uint32]
    wlSwipeStates*: Table[uint32, WlSwipeState]
    cursorShapeDevices*: Table[uint32, ptr cursorShape.WpCursorShapeDeviceV1]
    cursorHiddenPointers*: Table[uint32, bool]
    cursorLastMotionMsByPointer*: Table[uint32, int64]
    frameTabClickSuppressWindowId*: uint32
    frameTabClickTargetWindowId*: uint32
    frameTabClickSuppressUntilMs*: int64
    pointerWindowBySeat*: Table[uint32, uint32]
    pointerPositionBySeat*: Table[uint32, Rect]
    pointerHotCornerInsideBySeat*: Table[uint32, bool]
    pointerHotCornerOpenedBySeat*: Table[uint32, bool]
    cursorShakeBySeat*: Table[uint32, CursorShakeState]
    inputDevices*: Table[uint32, InputDeviceRuntime]
    libinputDevices*: Table[uint32, LibinputDeviceRuntime]
    xkbConfigKeyboards*: Table[uint32, XkbKeyboardRuntime]
    xkbConfigKeymap*: XkbKeymapRuntime
    libinputResultDescriptions*: Table[uint32, string]
    switchEventDevices*: seq[SwitchEventDeviceRuntime]
    windowUnreliablePids*: Table[uint32, int32]
    pendingWindows*: Table[uint32, ProjectedWindow]
    fireAndForgetProcesses*: seq[Process]
    pendingSpawnPlacements*: seq[SpawnPlacementContext]

    configPath*: string
    configWatchPaths*: seq[string]
    watcher*: Watcher
    configReloadDebouncer*: ConfigReloadDebouncer
    inputConfigReloadHook*: RuntimeReasonHook
    configNotificationHook*: ConfigNotificationHook
    shouldExit*: bool
    quickshellState*: QuickshellRunner
    startupCommandsPending*: bool
    initialManageComplete*: bool
    postManageBroadcastPending*: bool
    postManageBroadcastReason*: string
    pendingLiveRestorePath*: string
    pendingLiveRestore*: Option[LiveRestoreState]
    liveRestoreCommitPending*: bool
    lastMemorySampleMs*: int64
    closeBurstStartMs*: int64
    closeBurstDestroyedCount*: int
    memoryPressureDueMs*: int64
    memoryPressureCloseCount*: int
    memoryPressureReason*: string
    lastMemoryTrimMs*: int64

proc initTriadDaemon*(): TriadDaemon =
  result.startUnixMs = int64(epochTime() * 1000.0)
  result.riverPhase = RiverPhase.RiverIdle
  result.msgQueue = initDeque[QueuedMsg]()
  result.windowReadyEmitted = initHashSet[uint32]()
  result.pendingManageEffects = @[]
  result.desiredPlacementOrder = @[]
  result.seatPointers = @[]
  result.layerSeatPointers = @[]
  result.xkbBindingPointers = @[]
  result.pointerBindingPointers = @[]
  result.waitBackend = "timeout"
  result.renderDirty = true
  result.renderDirtyReason = "startup"
  result.pendingLiveRestore = none(LiveRestoreState)
  result.fireAndForgetProcesses = @[]
  result.pendingSpawnPlacements = @[]

proc daemonData*(daemon: var TriadDaemon): pointer =
  cast[pointer](addr daemon)

proc daemonFromData*(data: pointer): ptr TriadDaemon =
  if data == nil:
    nil
  else:
    cast[ptr TriadDaemon](data)

proc expectMaximizedAck*(daemon: var TriadDaemon, id: uint32, maximized: bool) =
  if id == 0:
    return
  daemon.pendingMaximizedAcks[id] = maximized

proc consumeMaximizedAck*(daemon: var TriadDaemon, id: uint32, maximized: bool): bool =
  if not daemon.pendingMaximizedAcks.hasKey(id):
    return false
  if daemon.pendingMaximizedAcks[id] != maximized:
    return false
  daemon.pendingMaximizedAcks.del(id)
  true
