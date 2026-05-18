import std/options
from ../types/runtime_values import
  LayoutMode, LayoutSelection, LayoutSelectionKind, NativeLayoutConfig, NativeLayoutId

const FrameTreeLayoutId* = "frame-tree"
const BspTreeLayoutId* = "bsp-tree"
const SplitTreeLayoutId* = "i3"
const LegacySplitTreeLayoutId* = "split-tree"

proc nativeLayoutId*(value: string): NativeLayoutId =
  NativeLayoutId(value)

proc nativeLayoutIdString*(layoutId: NativeLayoutId): string =
  string(layoutId)

proc builtinSelection(mode: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Builtin, builtin: mode)

proc nativeLayouts*(): seq[NativeLayoutConfig] =
  @[
    NativeLayoutConfig(
      id: nativeLayoutId(FrameTreeLayoutId),
      fallback: builtinSelection(LayoutMode.Scroller),
    ),
    NativeLayoutConfig(
      id: nativeLayoutId(BspTreeLayoutId),
      fallback: builtinSelection(LayoutMode.Scroller),
    ),
    NativeLayoutConfig(
      id: nativeLayoutId(SplitTreeLayoutId),
      fallback: builtinSelection(LayoutMode.Scroller),
    ),
  ]

proc parseNativeLayoutId*(value: string): Option[NativeLayoutConfig] =
  for layout in nativeLayouts():
    if layout.id.nativeLayoutIdString() == value or (
      layout.id.nativeLayoutIdString() == SplitTreeLayoutId and
      value == LegacySplitTreeLayoutId
    ):
      return some(layout)
  none(NativeLayoutConfig)
