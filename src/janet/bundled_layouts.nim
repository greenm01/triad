import std/options
import ../core/layout_descriptor_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
from ../types/runtime_values import JanetLayoutConfig, LayoutMode

const BundledLayoutsPathPrefix* = "<triad-bundled-layout:"

const BundledLayoutCommonSource = staticRead("bundled_layouts/common.janet")
const TileLayoutSource = staticRead("bundled_layouts/tile.janet")
const GridLayoutSource = staticRead("bundled_layouts/grid.janet")
const MonocleLayoutSource = staticRead("bundled_layouts/monocle.janet")
const DeckLayoutSource = staticRead("bundled_layouts/deck.janet")
const CenterTileLayoutSource = staticRead("bundled_layouts/center-tile.janet")
const RightTileLayoutSource = staticRead("bundled_layouts/right-tile.janet")
const VerticalTileLayoutSource = staticRead("bundled_layouts/vertical-tile.janet")
const VerticalGridLayoutSource = staticRead("bundled_layouts/vertical-grid.janet")
const VerticalDeckLayoutSource = staticRead("bundled_layouts/vertical-deck.janet")
const TgmixLayoutSource = staticRead("bundled_layouts/tgmix.janet")
const NotionLayoutSource = staticRead("bundled_layouts/notion.janet")

proc bundledLayoutPath*(id: string): string =
  BundledLayoutsPathPrefix & id & ">"

proc bundledSource(parts: varargs[string]): string =
  result = BundledLayoutCommonSource
  for part in parts:
    result.add("\n")
    result.add(part)

proc bundledLayoutSource*(id: string): Option[string] =
  let source =
    case id
    of "tile":
      bundledSource(TileLayoutSource)
    of "grid":
      bundledSource(GridLayoutSource)
    of "monocle":
      bundledSource(MonocleLayoutSource)
    of "deck":
      bundledSource(DeckLayoutSource)
    of "center-tile":
      bundledSource(CenterTileLayoutSource)
    of "right-tile":
      bundledSource(RightTileLayoutSource)
    of "vertical-tile":
      bundledSource(VerticalTileLayoutSource)
    of "vertical-grid":
      bundledSource(GridLayoutSource, VerticalGridLayoutSource)
    of "vertical-deck":
      bundledSource(VerticalTileLayoutSource, VerticalDeckLayoutSource)
    of "tgmix":
      bundledSource(TileLayoutSource, GridLayoutSource, TgmixLayoutSource)
    of "notion":
      bundledSource(NotionLayoutSource)
    else:
      ""
  if source.len == 0:
    none(string)
  else:
    some(source)

proc bundledLayoutConfigs*(): seq[JanetLayoutConfig] =
  for id in BundledAlgorithmicLayoutIds:
    result.add(
      JanetLayoutConfig(
        id: janetLayoutId(id), fallback: builtinSelection(LayoutMode.Scroller)
      )
    )
  for id in BundledFrameLayoutIds:
    result.add(
      JanetLayoutConfig(
        id: janetLayoutId(id),
        fallback:
          nativeSelection(nativeLayoutId(FrameTreeLayoutId), LayoutMode.Scroller),
      )
    )
