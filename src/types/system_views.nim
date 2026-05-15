import core as core_types
from runtime_effects import Effect
import runtime_values as rv

type
  RecentWindowPreview* = object
    winId*: core_types.WindowId
    riverId*: rv.WindowId
    geom*: rv.Rect
    title*: string
    appId*: string
    selected*: bool

  ParentedWindowIntent* {.pure.} = enum
    None
    Float
    Tile

  LeadFloatingAnchor* = object
    found*: bool
    winId*: core_types.WindowId
    columnId*: core_types.ColumnId

  UpdateStep* = object
    dirty*: bool
    effects*: seq[Effect]

  OverviewStyle* {.pure.} = enum
    WorkspaceStrip

  OverviewDropKind* {.pure.} = enum
    DropNone
    DropWorkspace
    DropDynamicGap

  OverviewDropTarget* = object
    kind*: OverviewDropKind
    slot*: uint32

  OverviewHiddenCountBadge* = object
    slot*: uint32
    count*: int
    rect*: rv.Rect

  OverviewScrollAxis* {.pure.} = enum
    Horizontal
    Vertical

  OverviewScrollIndicator* = object
    slot*: uint32
    axis*: OverviewScrollAxis
    before*: bool
    after*: bool
    rect*: rv.Rect
