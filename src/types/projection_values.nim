import core
import runtime_values

export core.Rect
export runtime_values

type
  ProjectionWindowId* = uint32
  ProjectionOutputId* = uint32

  ProjectedOutput* = object
    id*: ProjectionOutputId
    wlName*: uint32
    name*: string
    x*, y*, w*, h*: int32
    usableX*, usableY*, usableW*, usableH*: int32
    hasUsable*: bool

  ProjectedWindow* = object
    id*: ProjectionWindowId
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
    fullscreenOutput*: ProjectionOutputId
    parentId*: ProjectionWindowId
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
    idleInhibitMode*: WindowRuleIdleInhibitMode
    isTerminal*: bool
    allowSwallow*: bool

  ProjectedGroup* = object
    id*: uint32
    windows*: seq[ProjectionWindowId]
    activeWindow*: ProjectionWindowId

  ProjectedColumn* = object
    windows*: seq[ProjectionWindowId]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

  ProjectedFrame* = object
    id*: uint32
    kind*: FrameNodeKind
    parent*: uint32
    firstChild*: uint32
    secondChild*: uint32
    orientation*: FrameSplitOrientation
    ratio*: float32
    windows*: seq[ProjectionWindowId]
    activeWindow*: ProjectionWindowId
    focused*: bool
    rectSet*: bool
    rect*: Rect

  ProjectedBspNode* = object
    id*: uint32
    kind*: FrameNodeKind
    parent*: uint32
    firstChild*: uint32
    secondChild*: uint32
    orientation*: FrameSplitOrientation
    ratio*: float32
    window*: ProjectionWindowId
    focused*: bool
    rectSet*: bool
    rect*: Rect

  ProjectedFrameTab* = object
    windowId*: ProjectionWindowId
    title*: string
    appId*: string
    active*: bool

  ProjectedFrameTabBar* = object
    frameId*: uint32
    windowId*: ProjectionWindowId
    geom*: Rect
    focused*: bool
    frameTabs*: FrameTabsConfig
    ringWidth*: int32
    ringColor*: uint32
    tabs*: seq[ProjectedFrameTab]

  ProjectedFrameEmptyChrome* = object
    frameId*: uint32
    geom*: Rect
    focused*: bool
    ringWidth*: int32
    ringColor*: uint32
    backgroundColor*: uint32

  ProjectedTag* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[ProjectedColumn]
    frames*: seq[ProjectedFrame]
    bspNodes*: seq[ProjectedBspNode]
    focusedWindow*: ProjectionWindowId
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  RenderInstruction* = object
    windowId*: ProjectionWindowId
    geom*: Rect
    clipSet*: bool
    clip*: Rect
