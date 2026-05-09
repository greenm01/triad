import options
from ../types/runtime_values import LayoutMode

proc layoutModeId*(mode: LayoutMode): string =
  case mode
  of LayoutMode.Scroller: "scroller"
  of LayoutMode.VerticalScroller: "vertical-scroller"
  of LayoutMode.MasterStack: "tile"
  of LayoutMode.Grid: "grid"
  of LayoutMode.Monocle: "monocle"
  of LayoutMode.Deck: "deck"
  of LayoutMode.CenterTile: "center-tile"
  of LayoutMode.RightTile: "right-tile"
  of LayoutMode.VerticalTile: "vertical-tile"
  of LayoutMode.VerticalGrid: "vertical-grid"
  of LayoutMode.VerticalDeck: "vertical-deck"

proc parseLayoutModeId*(value: string): Option[LayoutMode] =
  case value
  of "scroller": some(LayoutMode.Scroller)
  of "vertical-scroller": some(LayoutMode.VerticalScroller)
  of "tile": some(LayoutMode.MasterStack)
  of "grid": some(LayoutMode.Grid)
  of "monocle": some(LayoutMode.Monocle)
  of "deck": some(LayoutMode.Deck)
  of "center-tile": some(LayoutMode.CenterTile)
  of "right-tile": some(LayoutMode.RightTile)
  of "vertical-tile": some(LayoutMode.VerticalTile)
  of "vertical-grid": some(LayoutMode.VerticalGrid)
  of "vertical-deck": some(LayoutMode.VerticalDeck)
  else: none(LayoutMode)
