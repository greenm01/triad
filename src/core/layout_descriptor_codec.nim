import std/options
import layout_mode_codec
import native_layout_codec
from ../types/runtime_values import LayoutKind, LayoutMode, LayoutSource

const BundledAlgorithmicLayoutIds* = [
  "tile", "grid", "monocle", "deck", "center-tile", "right-tile", "vertical-tile",
  "vertical-grid", "vertical-deck", "tgmix",
]

proc layoutKindId*(kind: LayoutKind): string =
  case kind
  of LayoutKind.Algorithmic: "algorithmic"
  of LayoutKind.Scrolling: "scrolling"
  of LayoutKind.Frame: "frame"
  of LayoutKind.Bsp: "bsp"
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
  if parseCoreLayoutModeId(id).isSome:
    return LayoutKind.Scrolling
  if parseNativeLayoutId(id).isSome:
    return LayoutKind.Frame
  LayoutKind.Algorithmic

proc layoutSourceForId*(id: string): LayoutSource =
  if id.isBundledAlgorithmicLayoutId():
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
