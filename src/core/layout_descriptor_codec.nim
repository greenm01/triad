import std/options
import layout_mode_codec
import native_layout_codec
from ../types/runtime_values import LayoutKind, LayoutMode, LayoutSource

const BundledAlgorithmicLayoutIds* = [
  "tile", "grid", "monocle", "deck", "center-tile", "right-tile", "vertical-tile",
  "vertical-grid", "vertical-deck", "tgmix", "spiral",
]

const BundledFrameLayoutIds* = ["notion"]
const BundledBspLayoutIds* = ["bsp", "dwindle"]

proc layoutKindId*(kind: LayoutKind): string =
  case kind
  of LayoutKind.Algorithmic: "algorithmic"
  of LayoutKind.Scrolling: "scrolling"
  of LayoutKind.Frame: "frame"
  of LayoutKind.Bsp: "bsp"
  of LayoutKind.SplitTree: "split-tree"
  of LayoutKind.Float: "float"

proc layoutSourceId*(source: LayoutSource): string =
  case source
  of LayoutSource.Core: "core"
  of LayoutSource.BundledJanet: "bundled-janet"
  of LayoutSource.UserJanet: "user-janet"
  of LayoutSource.Native: "native"

proc isBundledAlgorithmicLayoutId*(id: string): bool =
  for candidate in BundledAlgorithmicLayoutIds:
    if id == candidate:
      return true
  false

proc isBundledFrameLayoutId*(id: string): bool =
  for candidate in BundledFrameLayoutIds:
    if id == candidate:
      return true
  false

proc isBundledBspLayoutId*(id: string): bool =
  for candidate in BundledBspLayoutIds:
    if id == candidate:
      return true
  false

proc isBundledLayoutId*(id: string): bool =
  id.isBundledAlgorithmicLayoutId() or id.isBundledFrameLayoutId() or
    id.isBundledBspLayoutId()

proc parseCoreLayoutModeId*(value: string): Option[LayoutMode] =
  case value
  of "scroller":
    some(LayoutMode.Scroller)
  of "vertical-scroller":
    some(LayoutMode.VerticalScroller)
  else:
    none(LayoutMode)

proc layoutKind*(mode: LayoutMode): LayoutKind =
  case mode
  of LayoutMode.Scroller, LayoutMode.VerticalScroller: LayoutKind.Scrolling
  else: LayoutKind.Algorithmic

proc layoutSource*(mode: LayoutMode): LayoutSource =
  case mode
  of LayoutMode.Scroller, LayoutMode.VerticalScroller: LayoutSource.Core
  else: LayoutSource.BundledJanet

proc layoutKindForId*(id: string): LayoutKind =
  if id.isBundledAlgorithmicLayoutId():
    return LayoutKind.Algorithmic
  if id.isBundledFrameLayoutId():
    return LayoutKind.Frame
  if id.isBundledBspLayoutId():
    return LayoutKind.Bsp
  if parseCoreLayoutModeId(id).isSome:
    return LayoutKind.Scrolling
  let native = parseNativeLayoutId(id)
  if native.isSome:
    if id == BspTreeLayoutId:
      return LayoutKind.Bsp
    if native.get().id.nativeLayoutIdString() == SplitTreeLayoutId:
      return LayoutKind.SplitTree
    return LayoutKind.Frame
  LayoutKind.Algorithmic

proc layoutSourceForId*(id: string): LayoutSource =
  if id.isBundledLayoutId():
    return LayoutSource.BundledJanet
  if parseCoreLayoutModeId(id).isSome:
    return LayoutSource.Core
  if parseNativeLayoutId(id).isSome:
    return LayoutSource.Native
  LayoutSource.UserJanet

proc layoutModeForBundledId*(id: string): Option[LayoutMode] =
  let parsed = parseLayoutModeId(id)
  if parsed.isSome and id.isBundledAlgorithmicLayoutId():
    return parsed
  none(LayoutMode)
