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

  PresentationMode* {.pure.} = enum
    PresentationDefault
    PresentationVsync
    PresentationAsync

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

  LayoutMode* {.pure.} = enum
    Scroller
    VerticalScroller
    MasterStack
    Grid
    Monocle
    Deck
    CenterTile
    RightTile
    VerticalTile
    VerticalGrid
    VerticalDeck
    TGMix

  Direction* {.pure.} = enum
    DirLeft
    DirRight
    DirUp
    DirDown

  ParentedRole* {.pure.} = enum
    Dialog
    Tool
    Plain

  WindowRuleMaximizePolicy* {.pure.} = enum
    Edge
    Column
    Ignore

  FloatingPositionAnchor* {.pure.} = enum
    TopLeft
    TopRight
    BottomLeft
    BottomRight
    Top
    Bottom
    Left
    Right

  WindowRuleFloatingConfig* = object
    xRatioSet*: bool
    xRatio*: float32
    yRatioSet*: bool
    yRatio*: float32
    widthRatioSet*: bool
    widthRatio*: float32
    widthSet*: bool
    width*: int32
    heightRatioSet*: bool
    heightRatio*: float32
    heightSet*: bool
    height*: int32

  WindowRuleFloatingPositionConfig* = object
    set*: bool
    x*, y*: int32
    relativeTo*: FloatingPositionAnchor

  WindowData* = object
    id*: WindowId
    title*: string
    appId*: string
    widthProportion*: float32
    heightProportion*: float32
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
    keyboardShortcutsInhibit*: bool
    keyboardShortcutsInhibitBypass*: bool

  GroupState* = object
    id*: uint32
    windows*: seq[WindowId]
    activeWindow*: WindowId

  Column* = object
    windows*: seq[WindowId]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

  TagState* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[Column]
    focusedWindow*: WindowId
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  WindowRuleMatcher* = object
    appIdSet*: bool
    appId*: string
    titleSet*: bool
    title*: string
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

  WindowRule* = object
    appIdMatch*: string
    titleMatch*: string
    matches*: seq[WindowRuleMatcher]
    excludes*: seq[WindowRuleMatcher]
    defaultWorkspace*: uint32
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

  TagRule* = object
    tagId*: uint32
    name*: string
    defaultLayoutSet*: bool
    defaultLayout*: LayoutMode

  WorkspaceConfig* = object
    defaultCount*: uint32
    defaultLayout*: LayoutMode

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
    clipboardCommand*: string
    showPointer*: bool

  OverviewHotCornersConfig* = object
    size*: int32
    topLeft*: bool
    topRight*: bool
    bottomLeft*: bool
    bottomRight*: bool

  OverviewConfig* = object
    outerGap*: int32
    innerGapMultiplier*: float32
    zoom*: float32
    hotCorners*: OverviewHotCornersConfig

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
    shakeToFind*: bool

  HotkeyOverlayConfig* = object
    skipAtStartup*: bool
    hideNotBound*: bool

  HotkeyOverlayRow* = object
    key*: string
    label*: string

  PointerOpKind* {.pure.} = enum
    OpNone
    OpMove
    OpResize
    OpOverviewDrag
    OpOverviewScroll

  HotkeyOverlayTitleKind* {.pure.} = enum
    HotkeyTitleDefault
    HotkeyTitleCustom
    HotkeyTitleHidden

  BindingMode* {.pure.} = enum
    BindAlways
    BindNormal
    BindOverview

  KeyBindingConfig* = object
    key*: string
    modifiers*: uint32
    command*: string
    mode*: BindingMode
    hasLayoutOverride*: bool
    layoutOverride*: uint32
    bypassShortcutsInhibit*: bool
    hotkeyOverlayTitleKind*: HotkeyOverlayTitleKind
    hotkeyOverlayTitle*: string

  PointerBindingConfig* = object
    button*: uint32
    modifiers*: uint32
    op*: PointerOpKind
    command*: string
    mode*: BindingMode
    bypassShortcutsInhibit*: bool

  ProtocolSurfacesConfig* = object
    enabled*: bool
    visibleDebug*: bool

  PointerOpState* = object
    kind*: PointerOpKind
    windowId*: WindowId
    initialGeom*: Rect
    edges*: uint32

  RestoredWindowState* = object
    tagId*: uint32
    parentId*: WindowId
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
    manualFloatingPosition*: bool
    actualW*, actualH*: int32

  RestoredColumnState* = object
    windows*: seq[WindowId]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

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
