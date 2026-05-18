import std/[re, sets, tables]
from core import
  ColumnId, EmptyTagMask, EntityManager, ExternalOutputId, ExternalWindowId, FrameId,
  GroupId, IdCounters, OutputId, Rect, TagId, TagMask, WindowId
from runtime_values import
  AxisBindingConfig, ConfigNotificationConfig, CursorConfig, EnvironmentEntryConfig,
  InputConfig, GestureBindingConfig, JanetConfig, JanetLayoutConfig, JanetLayoutId,
  KeyBindingConfig, LayoutMode, LayoutSelection, HotkeyOverlayConfig, FrameTabsConfig,
  LayoutSwitchToastConfig, OutputConfigTransform, ParentedRole,
  OverviewHotCornersConfig, PointerBindingConfig, PointerOpKind, PresentationMode,
  ProtocolSurfacesConfig, QuickshellConfig, ShellsConfig, RecentWindowFilter,
  RecentWindowScope, RecentWindowsConfig, ScreenshotConfig, SwitchEventConfig,
  TerminalConfig, WindowRuleBorderConfig, WindowRuleFloatingConfig,
  WindowRuleFloatingPositionConfig, WindowRuleFocusRingConfig,
  WindowRuleIdleInhibitMode, WindowRuleMaximizePolicy
from runtime_values import FrameNodeKind, FrameSplitOrientation, NativeLayoutId

type
  WindowAdmissionState* {.pure.} = enum
    Admitted
    PendingAdmission

  WindowData* = object
    id*: WindowId
    externalId*: ExternalWindowId
    pid*: int32
    title*: string
    appId*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    isSticky*: bool
    isOverlay*: bool
    isUnmanagedGlobal*: bool
    fullscreenOutput*: ExternalOutputId
    parentExternalId*: ExternalWindowId
    identifier*: string
    actualW*, actualH*: int32
    clientMinWidth*, clientMinHeight*, clientMaxWidth*, clientMaxHeight*: int32
    minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    hasDecorationHint*: bool
    decorationHint*: uint32
    hasPresentationHint*: bool
    presentationHint*: uint32
    floatingGeom*: Rect
    parentAutoFloating*: bool
    manualFloatingPosition*: bool
    admissionState*: WindowAdmissionState
    focusAfterAdmission*: bool
    keyboardShortcutsInhibit*: bool
    keyboardShortcutsInhibitBypass*: bool
    idleInhibitMode*: WindowRuleIdleInhibitMode
    isTerminal*: bool
    allowSwallow*: bool

  TagData* = object
    id*: TagId
    slot*: uint32
    bit*: TagMask
    name*: string
    layoutMode*: LayoutMode
    customLayoutId*: JanetLayoutId
    nativeLayoutId*: NativeLayoutId
    focusedFrame*: FrameId
    focusedWindow*: WindowId
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  ColumnData* = object
    id*: ColumnId
    tagId*: TagId
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool
    focusedWindow*: WindowId

  FrameData* = object
    id*: FrameId
    tagId*: TagId
    kind*: FrameNodeKind
    parent*: FrameId
    firstChild*: FrameId
    secondChild*: FrameId
    orientation*: FrameSplitOrientation
    ratio*: float32
    activeWindow*: WindowId

  OutputData* = object
    id*: OutputId
    externalId*: ExternalOutputId
    wlName*: uint32
    name*: string
    make*: string
    model*: string
    description*: string
    x*, y*, w*, h*: int32
    refreshRate*: int32
    usableX*, usableY*, usableW*, usableH*: int32
    hasUsable*: bool

  GroupData* = object
    id*: GroupId
    windows*: seq[WindowId]
    activeWindow*: WindowId

  WindowPlacement* = object
    tagId*: TagId
    windowId*: WindowId
    columnId*: ColumnId
    windowIdx*: uint32

  WindowRuleMatcherData* = object
    appIdSet*: bool
    appIdPattern*: string
    appIdRegex*: Regex
    titleSet*: bool
    titlePattern*: string
    titleRegex*: Regex
    isActiveSet*: bool
    isActive*: bool
    isFocusedSet*: bool
    isFocused*: bool
    isActiveInColumnSet*: bool
    isActiveInColumn*: bool
    isFloatingSet*: bool
    isFloating*: bool
    atStartupSet*: bool
    atStartup*: bool

  WindowRuleData* = object
    matches*: seq[WindowRuleMatcherData]
    excludes*: seq[WindowRuleMatcherData]
    defaultSlot*: uint32
    defaultSlots*: seq[uint32]
    openOnOutput*: string
    defaultColumnWidthSet*: bool
    defaultColumnWidth*: float32
    scrollerProportionSet*: bool
    scrollerProportion*: float32
    scrollerSingleProportionSet*: bool
    scrollerSingleProportion*: float32
    defaultWindowWidthSet*: bool
    defaultWindowWidth*: float32
    defaultWindowHeightSet*: bool
    defaultWindowHeight*: float32
    minWidthSet*: bool
    minWidth*: int32
    minHeightSet*: bool
    minHeight*: int32
    maxWidthSet*: bool
    maxWidth*: int32
    maxHeightSet*: bool
    maxHeight*: int32
    openFloatingSet*: bool
    openFloating*: bool
    openFocusedSet*: bool
    openFocused*: bool
    openFullscreenSet*: bool
    openFullscreen*: bool
    openMaximizedSet*: bool
    openMaximized*: bool
    openMaximizedToEdgesSet*: bool
    openMaximizedToEdges*: bool
    openOnAllWorkspacesSet*: bool
    openOnAllWorkspaces*: bool
    openOverlaySet*: bool
    openOverlay*: bool
    openUnmanagedGlobalSet*: bool
    openUnmanagedGlobal*: bool
    terminalSet*: bool
    terminal*: bool
    allowSwallowSet*: bool
    allowSwallow*: bool
    maximizePolicySet*: bool
    maximizePolicy*: WindowRuleMaximizePolicy
    respectSizeHintsSet*: bool
    respectSizeHints*: bool
    centerFloatingSet*: bool
    centerFloating*: bool
    parentedRoleSet*: bool
    parentedRole*: ParentedRole
    openNamedScratchpad*: string
    floating*: WindowRuleFloatingConfig
    defaultFloatingPosition*: WindowRuleFloatingPositionConfig
    border*: WindowRuleBorderConfig
    focusRing*: WindowRuleFocusRingConfig
    clipToGeometrySet*: bool
    clipToGeometry*: bool
    dialogViewportJumpSet*: bool
    dialogViewportJump*: bool
    keyboardShortcutsInhibitSet*: bool
    keyboardShortcutsInhibit*: bool
    idleInhibitModeSet*: bool
    idleInhibitMode*: WindowRuleIdleInhibitMode
    presentationModeSet*: bool
    presentationMode*: PresentationMode
    tiledStateSet*: bool
    tiledState*: bool
    forcedLayoutSet*: bool
    forcedLayout*: int

  ResolvedWindowRuleData* = object
    defaultSlot*: uint32
    defaultSlots*: seq[uint32]
    openOnOutput*: string
    defaultColumnWidthSet*: bool
    defaultColumnWidth*: float32
    scrollerProportionSet*: bool
    scrollerProportion*: float32
    scrollerSingleProportionSet*: bool
    scrollerSingleProportion*: float32
    defaultWindowWidthSet*: bool
    defaultWindowWidth*: float32
    defaultWindowHeightSet*: bool
    defaultWindowHeight*: float32
    minWidthSet*: bool
    minWidth*: int32
    minHeightSet*: bool
    minHeight*: int32
    maxWidthSet*: bool
    maxWidth*: int32
    maxHeightSet*: bool
    maxHeight*: int32
    openFloatingSet*: bool
    openFloating*: bool
    openFocusedSet*: bool
    openFocused*: bool
    openFullscreenSet*: bool
    openFullscreen*: bool
    openMaximizedSet*: bool
    openMaximized*: bool
    openMaximizedToEdgesSet*: bool
    openMaximizedToEdges*: bool
    openOnAllWorkspacesSet*: bool
    openOnAllWorkspaces*: bool
    openOverlaySet*: bool
    openOverlay*: bool
    openUnmanagedGlobalSet*: bool
    openUnmanagedGlobal*: bool
    terminalSet*: bool
    terminal*: bool
    allowSwallowSet*: bool
    allowSwallow*: bool
    maximizePolicySet*: bool
    maximizePolicy*: WindowRuleMaximizePolicy
    respectSizeHintsSet*: bool
    respectSizeHints*: bool
    centerFloatingSet*: bool
    centerFloating*: bool
    parentedRole*: ParentedRole
    openNamedScratchpad*: string
    floating*: WindowRuleFloatingConfig
    defaultFloatingPosition*: WindowRuleFloatingPositionConfig
    border*: WindowRuleBorderConfig
    focusRing*: WindowRuleFocusRingConfig
    clipToGeometrySet*: bool
    clipToGeometry*: bool
    dialogViewportJump*: bool
    keyboardShortcutsInhibit*: bool
    idleInhibitMode*: WindowRuleIdleInhibitMode
    presentationModeSet*: bool
    presentationMode*: PresentationMode
    tiledStateSet*: bool
    tiledState*: bool
    forcedLayout*: int

  TagRuleData* = object
    slot*: uint32
    name*: string
    defaultLayoutSet*: bool
    defaultLayout*: LayoutMode
    defaultLayoutSelection*: LayoutSelection
    openOnOutput*: string

  OutputRuleData* = object
    target*: string
    focusAtStartup*: bool
    workspaceSlots*: seq[uint32]
    modeSet*: bool
    modeWidth*: int32
    modeHeight*: int32
    modeRefresh*: int32
    scaleSet*: bool
    scale*: float32
    positionSet*: bool
    positionX*: int32
    positionY*: int32
    transformSet*: bool
    transform*: OutputConfigTransform
    adaptiveSyncSet*: bool
    adaptiveSync*: bool

  RestoredWindowData* = object
    slot*: uint32
    parentExternalId*: ExternalWindowId
    swallowedByExternalId*: ExternalWindowId
    swallowingExternalId*: ExternalWindowId
    pid*: int32
    appId*: string
    title*: string
    identifier*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    isSticky*: bool
    isUnmanagedGlobal*: bool
    fullscreenOutput*: ExternalOutputId
    floatingGeom*: Rect
    manualFloatingPosition*: bool
    isTerminal*: bool
    allowSwallow*: bool
    actualW*, actualH*: int32

  RestoredColumnData* = object
    windows*: seq[ExternalWindowId]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

  RestoredFrameData* = object
    id*: FrameId
    kind*: FrameNodeKind
    parent*: FrameId
    firstChild*: FrameId
    secondChild*: FrameId
    orientation*: FrameSplitOrientation
    ratio*: float32
    windows*: seq[ExternalWindowId]
    activeWindow*: ExternalWindowId

  RestoredTagData* = object
    slot*: uint32
    name*: string
    layoutMode*: LayoutMode
    customLayoutId*: JanetLayoutId
    nativeLayoutId*: NativeLayoutId
    columns*: seq[RestoredColumnData]
    frames*: seq[RestoredFrameData]
    focusedWindow*: ExternalWindowId
    focusedFrame*: FrameId
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  PointerOpData* = object
    kind*: PointerOpKind
    windowId*: WindowId
    initialGeom*: Rect
    edges*: uint32
    startX*, startY*: int32
    currentX*, currentY*: int32
    totalDX*, totalDY*: int32
    startScrollOffset*: float32
    hoverSlot*: uint32
    hoverElapsedMs*: int32

  ViewportState* = object
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32

  PendingRestoreState* = object
    activeSlot*: uint32
    focusedWindow*: ExternalWindowId
    tagByWindow*: Table[ExternalWindowId, uint32]
    windows*: Table[ExternalWindowId, RestoredWindowData]
    tags*: Table[uint32, RestoredTagData]
    outputTags*: Table[ExternalOutputId, uint32]
    scratchpadWindows*: seq[ExternalWindowId]
    namedScratchpads*: Table[string, ExternalWindowId]
    scratchpadRestoreSlots*: Table[ExternalWindowId, seq[uint32]]
    visibleScratchpad*: ExternalWindowId
    isScratchpadVisible*: bool
    focusHistory*: seq[ExternalWindowId]
    workspaceHistory*: seq[uint32]
    swallowedBy*: Table[ExternalWindowId, ExternalWindowId]
    swallowing*: Table[ExternalWindowId, ExternalWindowId]

  Model* = object
    counters*: IdCounters
    windows*: EntityManager[WindowId, WindowData]
    tags*: EntityManager[TagId, TagData]
    columns*: EntityManager[ColumnId, ColumnData]
    frames*: EntityManager[FrameId, FrameData]
    outputs*: EntityManager[OutputId, OutputData]
    groups*: EntityManager[GroupId, GroupData]

    windowTags*: Table[WindowId, TagMask]
    externalWindowIds*: Table[ExternalWindowId, WindowId]
    externalOutputIds*: Table[ExternalOutputId, OutputId]
    tagBySlot*: Table[uint32, TagId]
    columnsByTag*: Table[TagId, seq[ColumnId]]
    windowsByTag*: Table[TagId, seq[WindowId]]
    windowsByColumn*: Table[ColumnId, seq[WindowId]]
    placementByTagWindow*: Table[(TagId, WindowId), WindowPlacement]
    frameRootsByTag*: Table[TagId, FrameId]
    windowsByFrame*: Table[FrameId, seq[WindowId]]
    frameByTagWindow*: Table[(TagId, WindowId), FrameId]
    outputTags*: Table[OutputId, TagId]
    tagOutputs*: Table[TagId, OutputId]
    tagHomeOutputTargets*: Table[TagId, string]
    tagHomeOutputPinned*: HashSet[TagId]
    outputLastActiveSlots*: Table[string, uint32]
    groupByWindow*: Table[WindowId, GroupId]
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    scratchpadRestoreTags*: Table[WindowId, TagMask]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool
    swallowedBy*: Table[WindowId, WindowId]
    swallowing*: Table[WindowId, WindowId]

    activeTag*: TagId
    activeSlot*: uint32
    activeOutput*: OutputId
    primaryOutput*: OutputId
    outputStartupFocusResolved*: bool
    defaultWorkspaceCount*: uint32
    defaultWorkspaceLayout*: LayoutMode
    defaultWorkspaceLayoutSelection*: LayoutSelection
    visibleSlots*: seq[uint32]
    overviewActive*: bool
    overviewWorkspacePreviewsActive*: bool
    overviewTabMode*: bool
    overviewTabModeActive*: bool
    overviewTabModeModifiers*: uint32
    hotkeyOverlayOpen*: bool
    hotkeyOverlayShownOnce*: bool
    exitSessionConfirmOpen*: bool
    overviewSelectedWindow*: WindowId
    recentWindowsActive*: bool
    recentWindowsOpenElapsedMs*: int32
    layoutSwitchToastOpen*: bool
    layoutSwitchToastElapsedMs*: int32
    layoutSwitchToastLayout*: LayoutMode
    layoutSwitchToastCustomLayout*: JanetLayoutId
    recentWindowsScope*: RecentWindowScope
    recentWindowsPreviousScope*: RecentWindowScope
    recentWindowsFilter*: RecentWindowFilter
    recentWindowsAppIdFilter*: string
    recentWindowsSelectedWindow*: WindowId
    recentWindowsPointerSelectedWindow*: WindowId
    recentWindowsViewFrozen*: bool
    recentWindowsFrozenStartX*: int32
    overviewViewportSnapshot*: Table[TagId, ViewportState]
    viewportRetargetTags*: HashSet[TagId]
    viewportSnapTags*: HashSet[TagId]
    pendingDialogFocusWindows*: seq[WindowId]
    layerFocusExclusive*: bool
    sessionLocked*: bool
    activeModifiers*: uint32
    screenWidth*: int32
    screenHeight*: int32
    outerGaps*: int32
    innerGaps*: int32
    previousOuterGaps*: int32
    previousInnerGaps*: int32
    smartGaps*: bool
    borderWidth*: int32
    focusedBorderColor*: uint32
    unfocusedBorderColor*: uint32
    frameTabs*: FrameTabsConfig
    overviewOuterGap*: int32
    overviewInnerGapMultiplier*: float32
    overviewZoom*: float32
    overviewScrollerIndicators*: bool
    overviewHotCorners*: OverviewHotCornersConfig
    overviewScrollOffset*: float32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    defaultColumnWidth*: float32
    scrollerProportionPresets*: seq[float32]
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    enableAnimations*: bool
    animationSpeed*: float32
    animationSnapThreshold*: float32
    frameRate*: int32
    floatingXRatio*: float32
    floatingYRatio*: float32
    floatingWidthRatio*: float32
    floatingHeightRatio*: float32
    floatingMinWidth*: int32
    floatingMinHeight*: int32
    environment*: seq[EnvironmentEntryConfig]
    scratchpadWidthRatio*: float32
    scratchpadHeightRatio*: float32
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    shells*: ShellsConfig
    janet*: JanetConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    input*: InputConfig
    keyboardLayoutIndex*: uint32
    cursor*: CursorConfig
    hotkeyOverlay*: HotkeyOverlayConfig
    configNotification*: ConfigNotificationConfig
    recentWindows*: RecentWindowsConfig
    layoutSwitchToast*: LayoutSwitchToastConfig
    presentationMode*: PresentationMode
    protocolSurfaces*: ProtocolSurfacesConfig
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]
    axisBindings*: seq[AxisBindingConfig]
    gestureBindings*: seq[GestureBindingConfig]
    switchEvents*: seq[SwitchEventConfig]
    pointerOp*: PointerOpData
    screenLockCommand*: seq[string]
    windowMenuCommand*: seq[string]
    allowExitSession*: bool
    startupWindowRulesActive*: bool
    outputRules*: seq[OutputRuleData]
    windowRules*: seq[WindowRuleData]
    tagRules*: seq[TagRuleData]
    restoreActiveSlot*: uint32
    restoreFocusedWindow*: ExternalWindowId
    restoreTagByWindow*: Table[ExternalWindowId, uint32]
    restoreWindows*: Table[ExternalWindowId, RestoredWindowData]
    restoreTags*: Table[uint32, RestoredTagData]
    restoreOutputTags*: Table[ExternalOutputId, uint32]
    restoreScratchpadWindows*: seq[ExternalWindowId]
    restoreNamedScratchpads*: Table[string, ExternalWindowId]
    restoreScratchpadSlots*: Table[ExternalWindowId, seq[uint32]]
    restoreVisibleScratchpad*: ExternalWindowId
    restoreIsScratchpadVisible*: bool
    restoreFocusHistory*: seq[ExternalWindowId]
    restoreWorkspaceHistory*: seq[uint32]
    restoreResolvedWindows*: Table[ExternalWindowId, WindowId]
    restoreSwallowedBy*: Table[ExternalWindowId, ExternalWindowId]
    restoreSwallowing*: Table[ExternalWindowId, ExternalWindowId]
    layoutCycle*: seq[LayoutMode]
    layoutCycleSelections*: seq[LayoutSelection]
    customLayouts*: seq[JanetLayoutConfig]
    focusHistory*: seq[WindowId]
    recentWindowHistory*: seq[WindowId]
    pendingRecentFocusWindow*: WindowId
    pendingRecentFocusElapsedMs*: int32
    workspaceHistory*: seq[TagId]
    nextGroupId*: uint32
