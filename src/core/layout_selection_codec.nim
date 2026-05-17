import std/options
import layout_mode_codec
from ../types/runtime_values import
  JanetLayoutConfig, JanetLayoutId, LayoutMode, LayoutSelection, LayoutSelectionKind

proc janetLayoutId*(value: string): JanetLayoutId =
  JanetLayoutId(value)

proc layoutIdString*(layoutId: JanetLayoutId): string =
  string(layoutId)

proc builtinSelection*(mode: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Builtin, builtin: mode)

proc customSelection*(id: JanetLayoutId, fallback: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Custom, builtin: fallback, customId: id)

proc selectionId*(selection: LayoutSelection): string =
  case selection.kind
  of LayoutSelectionKind.Builtin:
    layoutModeId(selection.builtin)
  of LayoutSelectionKind.Custom:
    selection.customId.layoutIdString()

proc selectionFallback*(selection: LayoutSelection): LayoutMode =
  selection.builtin

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
  let builtin = parseLayoutModeId(value)
  if builtin.isSome:
    return some(builtinSelection(builtin.get()))

  let customId = parseCustomLayoutId(value)
  let custom = customLayouts.findCustomLayout(customId)
  if custom.isSome:
    return some(customSelection(customId, custom.get().fallback))

  none(LayoutSelection)
