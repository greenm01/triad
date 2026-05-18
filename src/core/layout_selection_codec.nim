import std/options
import layout_descriptor_codec
import layout_mode_codec
import native_layout_codec
from ../types/runtime_values import
  JanetLayoutConfig, JanetLayoutId, LayoutMode, LayoutSelection, LayoutSelectionKind,
  NativeLayoutId

proc janetLayoutId*(value: string): JanetLayoutId =
  JanetLayoutId(value)

proc layoutIdString*(layoutId: JanetLayoutId): string =
  string(layoutId)

proc builtinSelection*(mode: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Builtin, builtin: mode)

proc customSelection*(id: JanetLayoutId, fallback: LayoutSelection): LayoutSelection =
  LayoutSelection(
    kind: LayoutSelectionKind.Custom,
    builtin: fallback.builtin,
    customId: id,
    nativeId:
      if fallback.kind == LayoutSelectionKind.Native:
        fallback.nativeId
      else:
        NativeLayoutId(""),
  )

proc customSelection*(id: JanetLayoutId, fallback: LayoutMode): LayoutSelection =
  customSelection(id, builtinSelection(fallback))

proc nativeSelection*(id: NativeLayoutId, fallback: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Native, builtin: fallback, nativeId: id)

proc selectionId*(selection: LayoutSelection): string =
  case selection.kind
  of LayoutSelectionKind.Builtin:
    layoutModeId(selection.builtin)
  of LayoutSelectionKind.Custom:
    selection.customId.layoutIdString()
  of LayoutSelectionKind.Native:
    selection.nativeId.nativeLayoutIdString()

proc selectionFallback*(selection: LayoutSelection): LayoutMode =
  selection.builtin

proc selectionFallbackId*(selection: LayoutSelection): string =
  case selection.kind
  of LayoutSelectionKind.Custom:
    selection.customId.layoutIdString()
  of LayoutSelectionKind.Native:
    selection.nativeId.nativeLayoutIdString()
  of LayoutSelectionKind.Builtin:
    layoutModeId(selection.builtin)

proc findCustomLayout*(
    layouts: openArray[JanetLayoutConfig], id: JanetLayoutId
): Option[JanetLayoutConfig] =
  for layout in layouts:
    if layout.id.layoutIdString() == id.layoutIdString():
      return some(layout)
  none(JanetLayoutConfig)

proc parseCustomLayoutId*(value: string): JanetLayoutId =
  janetLayoutId(value)

proc parseLayoutSelectionId*(
    value: string, customLayouts: openArray[JanetLayoutConfig]
): Option[LayoutSelection] =
  let builtin = parseCoreLayoutModeId(value)
  if builtin.isSome:
    return some(builtinSelection(builtin.get()))

  let customId = parseCustomLayoutId(value)
  let custom = customLayouts.findCustomLayout(customId)
  if custom.isSome:
    return some(customSelection(customId, custom.get().fallback))

  let native = parseNativeLayoutId(value)
  if native.isSome:
    return some(nativeSelection(native.get().id, native.get().fallback.builtin))

  none(LayoutSelection)
