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
    PresentationDefault,
    PresentationVsync,
    PresentationAsync

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

  LayoutMode* {.pure.} = enum
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
    VerticalDeck,
    TGMix

  Direction* {.pure.} = enum
    DirLeft,
    DirRight,
    DirUp,
    DirDown

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

  WindowRule* = object
    appIdMatch*: string
    titleMatch*: string
    defaultTag*: uint32
    openFloatingSet*: bool
    openFloating*: bool
    openFocusedSet*: bool
    openFocused*: bool
    keyboardShortcutsInhibit*: bool
    forcedLayout*: int

  TagRule* = object
    tagId*: uint32
    name*: string
    defaultLayout*: LayoutMode

  WorkspaceConfig* = object
    defaultCount*: uint32

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

  HotkeyOverlayConfig* = object
    skipAtStartup*: bool
    hideNotBound*: bool

  HotkeyOverlayRow* = object
    key*: string
    label*: string

  PointerOpKind* {.pure.} = enum
    OpNone,
    OpMove,
    OpResize

  HotkeyOverlayTitleKind* {.pure.} = enum
    HotkeyTitleDefault,
    HotkeyTitleCustom,
    HotkeyTitleHidden

  BindingMode* {.pure.} = enum
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
