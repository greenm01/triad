import std/[re, sets, tables]
from core import
  ColumnId, EmptyTagMask, EntityManager, ExternalOutputId, ExternalWindowId, GroupId,
  IdCounters, OutputId, TagId, TagMask, WindowId
from runtime_values import
  CursorConfig, KeyBindingConfig, LayoutMode, HotkeyOverlayConfig, ParentedRole,
  OverviewHotCornersConfig, PointerBindingConfig, PointerOpKind, PresentationMode,
  ProtocolSurfacesConfig, QuickshellConfig, Rect, ScreenshotConfig, TerminalConfig,
  WindowRuleFloatingConfig, WindowRuleFloatingPositionConfig, WindowRuleMaximizePolicy

type
  WindowAdmissionState* {.pure.} = enum
    Admitted
    PendingAdmission

  WindowData* = object
    id*: WindowId
    externalId*: ExternalWindowId
    title*: string
    appId*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
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

  TagData* = object
    id*: TagId
    slot*: uint32
    bit*: TagMask
    name*: string
    layoutMode*: LayoutMode
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

  OutputData* = object
    id*: OutputId
    externalId*: ExternalOutputId
    wlName*: uint32
    name*: string
    x*, y*, w*, h*: int32
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
    dialogViewportJumpSet*: bool
    dialogViewportJump*: bool
    keyboardShortcutsInhibitSet*: bool
    keyboardShortcutsInhibit*: bool
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
    dialogViewportJump*: bool
    keyboardShortcutsInhibit*: bool
    tiledStateSet*: bool
    tiledState*: bool
    forcedLayout*: int

  TagRuleData* = object
    slot*: uint32
    name*: string
    defaultLayoutSet*: bool
    defaultLayout*: LayoutMode

  RestoredWindowData* = object
    slot*: uint32
    parentExternalId*: ExternalWindowId
    appId*: string
    title*: string
    identifier*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    fullscreenOutput*: ExternalOutputId
    floatingGeom*: Rect
    manualFloatingPosition*: bool
    actualW*, actualH*: int32

  RestoredColumnData* = object
    windows*: seq[ExternalWindowId]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

  RestoredTagData* = object
    slot*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[RestoredColumnData]
    focusedWindow*: ExternalWindowId
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
    hoverTicks*: int

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
    visibleScratchpad*: ExternalWindowId
    isScratchpadVisible*: bool
    focusHistory*: seq[ExternalWindowId]
    workspaceHistory*: seq[uint32]

  Model* = object
    counters*: IdCounters
    windows*: EntityManager[WindowId, WindowData]
    tags*: EntityManager[TagId, TagData]
    columns*: EntityManager[ColumnId, ColumnData]
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
    outputTags*: Table[OutputId, TagId]
    groupByWindow*: Table[WindowId, GroupId]
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool

    activeTag*: TagId
    activeSlot*: uint32
    primaryOutput*: OutputId
    defaultWorkspaceCount*: uint32
    defaultWorkspaceLayout*: LayoutMode
    visibleSlots*: seq[uint32]
    overviewActive*: bool
    overviewWorkspacePreviewsActive*: bool
    hotkeyOverlayOpen*: bool
    hotkeyOverlayShownOnce*: bool
    overviewSelectedWindow*: WindowId
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
    overviewOuterGap*: int32
    overviewInnerGapMultiplier*: float32
    overviewZoom*: float32
    overviewHotCorners*: OverviewHotCornersConfig
    overviewScrollOffset*: float32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    defaultColumnWidth*: float32
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    enableAnimations*: bool
    animationSpeed*: float32
    floatingXRatio*: float32
    floatingYRatio*: float32
    floatingWidthRatio*: float32
    floatingHeightRatio*: float32
    floatingMinWidth*: int32
    floatingMinHeight*: int32
    scratchpadWidthRatio*: float32
    scratchpadHeightRatio*: float32
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    cursor*: CursorConfig
    hotkeyOverlay*: HotkeyOverlayConfig
    presentationMode*: PresentationMode
    protocolSurfaces*: ProtocolSurfacesConfig
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]
    pointerOp*: PointerOpData
    screenLockCommand*: seq[string]
    windowMenuCommand*: seq[string]
    allowExitSession*: bool
    startupWindowRulesActive*: bool
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
    restoreVisibleScratchpad*: ExternalWindowId
    restoreIsScratchpadVisible*: bool
    restoreFocusHistory*: seq[ExternalWindowId]
    restoreWorkspaceHistory*: seq[uint32]
    layoutCycle*: seq[LayoutMode]
    focusHistory*: seq[WindowId]
    workspaceHistory*: seq[TagId]
    nextGroupId*: uint32
