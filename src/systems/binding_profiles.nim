import std/[options, strutils]
import ../config/keysyms
import ../core/layout_mode_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../state/engine
import ../types/[model, runtime_values]

proc tagLayoutBindingId*(tag: TagData): string =
  let customId = tag.customLayoutId.layoutIdString()
  if customId.len > 0:
    return customId

  let nativeId = tag.nativeLayoutId.nativeLayoutIdString()
  if nativeId.len > 0:
    return nativeId

  layoutModeId(tag.layoutMode)

proc activeLayoutBindingId*(model: Model): string =
  let tag = model.tagData(model.activeTag)
  if tag.isSome:
    tag.get().tagLayoutBindingId()
  else:
    ""

proc samePhysicalKeySlot*(a, b: KeyBindingConfig): bool =
  if a.modifiers != b.modifiers or a.mode != b.mode:
    return false

  let aSym = keySymForBinding(a.key, a.modifiers)
  let bSym = keySymForBinding(b.key, b.modifiers)
  if aSym != 0 and bSym != 0:
    aSym == bSym
  else:
    a.key.toLowerAscii() == b.key.toLowerAscii()

proc bindingMatchesActiveLayout*(model: Model, binding: KeyBindingConfig): bool =
  binding.layoutScope.len == 0 or binding.layoutScope == model.activeLayoutBindingId()

proc resolvedKeyBindings*(model: Model): seq[KeyBindingConfig] =
  let activeLayoutId = model.activeLayoutBindingId()

  for binding in model.keyBindings:
    if binding.layoutScope.len == 0:
      result.add(binding)

  if activeLayoutId.len == 0:
    return

  for binding in model.keyBindings:
    if binding.layoutScope != activeLayoutId:
      continue
    var i = 0
    while i < result.len:
      if result[i].samePhysicalKeySlot(binding):
        result.delete(i)
      else:
        inc i
    result.add(binding)
