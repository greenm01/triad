import std/[options, sequtils, strutils]
import ../state/engine
import ../types/runtime_values
import binding_profiles

type ImportantHotkey = object
  command: string
  label: string

const ImportantHotkeys = [
  ImportantHotkey(command: "exit-session", label: "Exit Triad"),
  ImportantHotkey(command: "toggle-hotkey-overlay", label: "Show Important Hotkeys"),
  ImportantHotkey(command: "close-window", label: "Close Focused Window"),
  ImportantHotkey(command: "focus-left", label: "Focus Left"),
  ImportantHotkey(command: "focus-right", label: "Focus Right"),
  ImportantHotkey(command: "focus-up", label: "Focus Up"),
  ImportantHotkey(command: "focus-down", label: "Focus Down"),
  ImportantHotkey(command: "move-window-left", label: "Move Window Left"),
  ImportantHotkey(command: "move-window-right", label: "Move Window Right"),
  ImportantHotkey(command: "move-window-up", label: "Move Window Up"),
  ImportantHotkey(command: "move-window-down", label: "Move Window Down"),
  ImportantHotkey(command: "switch-layout", label: "Switch Layout"),
  ImportantHotkey(command: "maximize-column", label: "Maximize Column"),
  ImportantHotkey(
    command: "maximize-window-to-edges", label: "Maximize Window to Edges"
  ),
  ImportantHotkey(command: "fullscreen-window", label: "Fullscreen Window"),
  ImportantHotkey(command: "toggle-floating", label: "Toggle Floating"),
  ImportantHotkey(command: "toggle-overview", label: "Toggle Overview"),
  ImportantHotkey(command: "toggle-scratchpad", label: "Toggle Scratchpad"),
  ImportantHotkey(command: "screenshot", label: "Take a Screenshot"),
]

proc modifierNames(modifiers: uint32): seq[string] =
  if (modifiers and 64'u32) != 0:
    result.add("Super")
  if (modifiers and 4'u32) != 0:
    result.add("Ctrl")
  if (modifiers and 1'u32) != 0:
    result.add("Shift")
  if (modifiers and 8'u32) != 0:
    result.add("Alt")
  if (modifiers and 32'u32) != 0:
    result.add("Mod3")
  if (modifiers and 128'u32) != 0:
    result.add("Mod5")

proc prettyKeyName(key: string): string =
  case key
  of "Slash":
    "/"
  of "Question":
    "?"
  of "Return":
    "Enter"
  of "Print":
    "PrtSc"
  else:
    if key.len == 1:
      key.toUpperAscii()
    else:
      key

proc prettyBinding(binding: KeyBindingConfig): string =
  let parts = binding.modifiers.modifierNames()
  if parts.len == 0:
    binding.key.prettyKeyName()
  else:
    parts.join(" + ") & " + " & binding.key.prettyKeyName()

proc commandBase(command: string): string =
  let parts = command.strip().splitWhitespace()
  if parts.len == 0:
    ""
  else:
    parts[0]

proc defaultCommandLabel(command: string): string =
  case command.commandBase()
  of "show-hotkey-overlay", "toggle-hotkey-overlay":
    "Show Important Hotkeys"
  of "hide-hotkey-overlay":
    "Hide Important Hotkeys"
  of "spawn-terminal":
    "Open Terminal"
  of "spawn":
    let parts = command.strip().splitWhitespace()
    if parts.len >= 2:
      "Spawn " & parts[1]
    else:
      "Spawn Command"
  else:
    command.commandBase().replace("-", " ").capitalizeAscii()

proc findBindingForCommand(
    bindings: seq[KeyBindingConfig], command: string
): Option[KeyBindingConfig] =
  let target = command.commandBase()
  for binding in bindings:
    if binding.hotkeyOverlayTitleKind == HotkeyOverlayTitleKind.HotkeyTitleHidden:
      continue
    if binding.command.commandBase() == target:
      return some(binding)
  none(KeyBindingConfig)

proc rowForBinding(binding: KeyBindingConfig): HotkeyOverlayRow =
  let label =
    if binding.hotkeyOverlayTitleKind == HotkeyOverlayTitleKind.HotkeyTitleCustom:
      binding.hotkeyOverlayTitle
    else:
      binding.command.defaultCommandLabel()
  HotkeyOverlayRow(key: binding.prettyBinding(), label: label)

proc rowExists(rows: seq[HotkeyOverlayRow], row: HotkeyOverlayRow): bool =
  rows.anyIt(it.key == row.key and it.label == row.label)

proc addRow(rows: var seq[HotkeyOverlayRow], row: HotkeyOverlayRow) =
  if row.key.len > 0 and row.label.len > 0 and not rows.rowExists(row):
    rows.add(row)

proc hotkeyOverlayRows*(model: Model): seq[HotkeyOverlayRow] =
  let bindings = model.resolvedKeyBindings()

  for item in ImportantHotkeys:
    let binding = bindings.findBindingForCommand(item.command)
    if binding.isSome:
      var row = binding.get().rowForBinding()
      if binding.get().hotkeyOverlayTitleKind ==
          HotkeyOverlayTitleKind.HotkeyTitleDefault:
        row.label = item.label
      result.addRow(row)
    elif not model.hotkeyOverlay.hideNotBound:
      result.addRow(HotkeyOverlayRow(key: "(not bound)", label: item.label))

  for binding in bindings:
    if binding.hotkeyOverlayTitleKind == HotkeyOverlayTitleKind.HotkeyTitleCustom:
      result.addRow(binding.rowForBinding())

  for binding in bindings:
    if binding.command.commandBase() in ["spawn", "spawn-terminal"] and
        (binding.modifiers and 64'u32) != 0:
      result.addRow(binding.rowForBinding())
