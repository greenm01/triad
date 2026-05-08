import tables

type
  WindowId* = uint32

  Rect* = object
    x*, y*, w*, h*: int32

  RenderInstruction* = object
    windowId*: WindowId
    geom*: Rect

  LayoutMode* = enum
    Scroller,
    VerticalScroller,
    MasterStack,
    Grid,
    Monocle

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
    theme*: string
    args*: seq[string]

  PointerOpKind* = enum
    OpNone,
    OpMove,
    OpResize

  PointerOpState* = object
    kind*: PointerOpKind
    windowId*: WindowId
    initialGeom*: Rect
    edges*: uint32 # For resize operations

  Model* = object
    tags*: Table[uint32, TagState]
    windows*: Table[WindowId, WindowData]
    groups*: Table[uint32, GroupState]
    windowRules*: seq[WindowRule]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    pointerOp*: PointerOpState
    scratchpadWindows*: seq[WindowId]
    isScratchpadVisible*: bool
    activeTag*: uint32
    overviewActive*: bool
    # Screen dimensions
    screenWidth*: int32
    screenHeight*: int32
    # Config-driven gaps
    outerGaps*: int32
    innerGaps*: int32
    previousOuterGaps*: int32
    previousInnerGaps*: int32
    smartGaps*: bool
    # Scroller global config
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    # Animation config
    enableAnimations*: bool
    animationSpeed*: float32
    # Grouping counter
    nextGroupId*: uint32
