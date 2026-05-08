import tables

type
  WindowId* = uint32

  Rect* = object
    x*, y*, w*, h*: int32

  OutputData* = object
    id*: uint32
    wlName*: uint32
    name*: string
    x*, y*, w*, h*: int32
    usableX*, usableY*, usableW*, usableH*: int32
    hasUsable*: bool

  PresentationMode* = enum
    PresentationDefault,
    PresentationVsync,
    PresentationAsync

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

  LayoutMode* = enum
    Scroller,
    VerticalScroller,
    MasterStack,
    Grid,
    Monocle,
    Deck,
    CenterTile,
    RightTile,
    VerticalTile,
    VerticalGrid,
    VerticalDeck

  Direction* = enum
    DirLeft,
    DirRight,
    DirUp,
    DirDown

  WindowData* = object
    id*: WindowId
    title*: string
    appId*: string
    # Abstract proportions for layout algorithms
    # Using float32 for efficiency, following DOD
    widthProportion*: float32  # 0.0 to 1.0
    heightProportion*: float32 # 0.0 to 1.0
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    fullscreenOutput*: uint32
    parentId*: WindowId
    identifier*: string
    actualW*, actualH*: int32
    minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    hasDecorationHint*: bool
    decorationHint*: uint32
    hasPresentationHint*: bool
    presentationHint*: uint32
    floatingGeom*: Rect

  GroupState* = object
    id*: uint32
    windows*: seq[WindowId]
    activeWindow*: WindowId

  Column* = object
    windows*: seq[WindowId] # DOD simplification: keep flat windows for now, use GroupState to filter
    widthProportion*: float32 # For the scroller ribbon

  TagState* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[Column]
    focusedWindow*: WindowId
    # Scroller specific state
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    # Master-Stack specific state
    masterCount*: int
    masterSplitRatio*: float32

  WindowRule* = object
    appIdMatch*: string
    titleMatch*: string
    defaultTag*: uint32
    openFloating*: bool
    forcedLayout*: int # 0: none, else: ord(LayoutMode) + 1

  QuickshellConfig* = object
    enabled*: bool
    command*: string
    theme*: string
    args*: seq[string]

  TerminalConfig* = object
    command*: seq[string]

  ScreenshotConfig* = object
    directory*: string
    filenamePrefix*: string
    captureCommand*: string
    regionSelectorCommand*: string
    showPointer*: bool

  OverviewConfig* = object
    outerGap*: int32
    innerGapMultiplier*: float32

  FloatingConfig* = object
    xRatio*: float32
    yRatio*: float32
    widthRatio*: float32
    heightRatio*: float32
    minWidth*: int32
    minHeight*: int32

  ScreenLockConfig* = object
    command*: seq[string]

  WindowMenuConfig* = object
    command*: seq[string]

  ScratchpadConfig* = object
    widthRatio*: float32
    heightRatio*: float32

  CursorConfig* = object
    theme*: string
    size*: uint32

  PointerOpKind* = enum
    OpNone,
    OpMove,
    OpResize

  BindingMode* = enum
    BindAlways,
    BindNormal,
    BindOverview

  KeyBindingConfig* = object
    key*: string
    modifiers*: uint32
    command*: string
    mode*: BindingMode
    hasLayoutOverride*: bool
    layoutOverride*: uint32

  PointerBindingConfig* = object
    button*: uint32
    modifiers*: uint32
    op*: PointerOpKind

  ProtocolSurfacesConfig* = object
    enabled*: bool
    visibleDebug*: bool

  PointerOpState* = object
    kind*: PointerOpKind
    windowId*: WindowId
    initialGeom*: Rect
    edges*: uint32 # For resize operations

  RestoredWindowState* = object
    tagId*: uint32
    appId*: string
    title*: string
    identifier*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    fullscreenOutput*: uint32
    floatingGeom*: Rect
    actualW*, actualH*: int32

  RestoredColumnState* = object
    windows*: seq[WindowId]
    widthProportion*: float32

  RestoredTagState* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[RestoredColumnState]
    focusedWindow*: WindowId
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  Model* = object
    tags*: Table[uint32, TagState]
    windows*: Table[WindowId, WindowData]
    outputs*: Table[uint32, OutputData]
    primaryOutput*: uint32
    outputTags*: Table[uint32, uint32]
    groups*: Table[uint32, GroupState]
    windowRules*: seq[WindowRule]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    overview*: OverviewConfig
    floating*: FloatingConfig
    screenLock*: ScreenLockConfig
    windowMenu*: WindowMenuConfig
    scratchpad*: ScratchpadConfig
    cursor*: CursorConfig
    presentationMode*: PresentationMode
    allowExitSession*: bool
    protocolSurfaces*: ProtocolSurfacesConfig
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]
    pointerOp*: PointerOpState
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool
    activeTag*: uint32
    overviewActive*: bool
    layerFocusExclusive*: bool
    sessionLocked*: bool
    activeModifiers*: uint32
    # Screen dimensions
    screenWidth*: int32
    screenHeight*: int32
    # Config-driven gaps
    outerGaps*: int32
    innerGaps*: int32
    previousOuterGaps*: int32
    previousInnerGaps*: int32
    smartGaps*: bool
    borderWidth*: int32
    focusedBorderColor*: uint32
    unfocusedBorderColor*: uint32
    # Scroller global config
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    defaultColumnWidth*: float32
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    # Animation config
    enableAnimations*: bool
    animationSpeed*: float32
    layoutCycle*: seq[LayoutMode]
    scratchpadWidthRatio*: float32
    scratchpadHeightRatio*: float32
    focusHistory*: seq[WindowId]
    restoreActiveTag*: uint32
    restoreTagByWindow*: Table[WindowId, uint32]
    restoreWindows*: Table[WindowId, RestoredWindowState]
    restoreTags*: Table[uint32, RestoredTagState]
    # Grouping counter
    nextGroupId*: uint32
