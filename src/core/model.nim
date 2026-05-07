import tables

type
  LayoutMode* = enum
    Scroller,
    MasterStack,
    Grid,
    Monocle

  WindowId* = uint32

  WindowData* = object
    id*: WindowId
    title*: string
    appId*: string
    # Abstract proportions for layout algorithms
    # Using float32 for efficiency, following DOD
    widthProportion*: float32  # 0.0 to 1.0
    heightProportion*: float32 # 0.0 to 1.0

  Column* = object
    windows*: seq[WindowId]
    widthProportion*: float32 # For the scroller ribbon

  TagState* = object
    tagId*: uint32
    layoutMode*: LayoutMode
    columns*: seq[Column]
    focusedWindow*: WindowId
    # Scroller specific state
    viewportXOffset*: float32
    # Master-Stack specific state
    masterCount*: int
    masterSplitRatio*: float32

  Model* = object
    tags*: Table[uint32, TagState]
    windows*: Table[WindowId, WindowData]
    activeTag*: uint32
    # Screen dimensions
    screenWidth*: int32
    screenHeight*: int32
    # Config-driven gaps
    outerGaps*: int32
    innerGaps*: int32
