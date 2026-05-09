import options
from ../types/runtime_values import CenterTile, Deck, Grid, LayoutMode,
  MasterStack, Monocle, RightTile, Scroller, VerticalDeck, VerticalGrid,
  VerticalScroller, VerticalTile

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
