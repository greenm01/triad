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

  ProjectedTag* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    columns*: seq[ProjectedColumn]
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
