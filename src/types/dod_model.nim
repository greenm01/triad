import tables
from core import ColumnId, EmptyTagMask, EntityManager, ExternalOutputId,
  ExternalWindowId, IdCounters, OutputId, TagId, TagMask, WindowId
from legacy_model import LayoutMode, Rect

type
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
    minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    hasDecorationHint*: bool
    decorationHint*: uint32
    hasPresentationHint*: bool
    presentationHint*: uint32
    floatingGeom*: Rect
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

  OutputData* = object
    id*: OutputId
    externalId*: ExternalOutputId
    wlName*: uint32
    name*: string
    x*, y*, w*, h*: int32
    usableX*, usableY*, usableW*, usableH*: int32
    hasUsable*: bool

  WindowPlacement* = object
    tagId*: TagId
    windowId*: WindowId
    columnId*: ColumnId
    windowIdx*: uint32

  DodModel* = object
    counters*: IdCounters
    windows*: EntityManager[WindowId, WindowData]
    tags*: EntityManager[TagId, TagData]
    columns*: EntityManager[ColumnId, ColumnData]
    outputs*: EntityManager[OutputId, OutputData]

    windowTags*: Table[WindowId, TagMask]
    externalWindowIds*: Table[ExternalWindowId, WindowId]
    externalOutputIds*: Table[ExternalOutputId, OutputId]
    tagBySlot*: Table[uint32, TagId]
    columnsByTag*: Table[TagId, seq[ColumnId]]
    windowsByTag*: Table[TagId, seq[WindowId]]
    windowsByColumn*: Table[ColumnId, seq[WindowId]]
    placementByTagWindow*: Table[(TagId, WindowId), WindowPlacement]
    outputTags*: Table[OutputId, TagId]

    activeTag*: TagId
    activeSlot*: uint32
    primaryOutput*: OutputId
    defaultWorkspaceCount*: uint32
    visibleSlots*: seq[uint32]
    overviewActive*: bool
    screenWidth*: int32
    screenHeight*: int32
    outerGaps*: int32
    innerGaps*: int32
    smartGaps*: bool
    overviewOuterGap*: int32
    overviewInnerGapMultiplier*: float32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    layoutCycle*: seq[LayoutMode]
    focusHistory*: seq[WindowId]
    workspaceHistory*: seq[TagId]
