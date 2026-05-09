import options
from runtime_values import CenterTile, Deck, Grid, LayoutMode, MasterStack,
  Monocle, Rect, RightTile, Scroller, VerticalDeck, VerticalGrid,
  VerticalScroller, VerticalTile, WindowId

const TriadIpcVersion* = 1

type
  ShellColumn* = object
    idx*: uint32
    widthProportion*: float32
    windows*: seq[WindowId]

  ShellWorkspace* = object
    tagId*: uint32
    workspaceIdx*: uint32
    name*: string
    layoutMode*: LayoutMode
    isActive*: bool
    focusedWindow*: WindowId
    occupied*: bool
    outputName*: string
    columns*: seq[ShellColumn]
    masterCount*: int
    masterSplitRatio*: float32
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32

  ShellWindow* = object
    id*: WindowId
    title*: string
    appId*: string
    tagId*: Option[uint32]
    workspaceIdx*: uint32
    outputName*: string
    colIdx*: uint32
    winIdx*: uint32
    isFocused*: bool
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    fullscreenOutput*: uint32
    widthProportion*: float32
    heightProportion*: float32
    actualW*: int32
    actualH*: int32
    floatingGeom*: Rect
    keyboardShortcutsInhibit*: bool

  ShellOutput* = object
    id*: uint32
    name*: string
    x*, y*, w*, h*: int32
    isPrimary*: bool

  ShellSnapshot* = object
    version*: uint32
    activeTag*: uint32
    activeWorkspaceIdx*: uint32
    overviewActive*: bool
    layoutCycle*: seq[LayoutMode]
    workspaces*: seq[ShellWorkspace]
    windows*: seq[ShellWindow]
    outputs*: seq[ShellOutput]

proc layoutModeId*(mode: LayoutMode): string =
  case mode
  of Scroller: "scroller"
  of VerticalScroller: "vertical-scroller"
  of MasterStack: "tile"
  of Grid: "grid"
  of Monocle: "monocle"
  of Deck: "deck"
  of CenterTile: "center-tile"
  of RightTile: "right-tile"
  of VerticalTile: "vertical-tile"
  of VerticalGrid: "vertical-grid"
  of VerticalDeck: "vertical-deck"

proc parseLayoutModeId*(value: string): Option[LayoutMode] =
  case value
  of "scroller": some(Scroller)
  of "vertical-scroller": some(VerticalScroller)
  of "tile": some(MasterStack)
  of "grid": some(Grid)
  of "monocle": some(Monocle)
  of "deck": some(Deck)
  of "center-tile": some(CenterTile)
  of "right-tile": some(RightTile)
  of "vertical-tile": some(VerticalTile)
  of "vertical-grid": some(VerticalGrid)
  of "vertical-deck": some(VerticalDeck)
  else: none(LayoutMode)
