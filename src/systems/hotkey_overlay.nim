import std/[options, sequtils, strutils]
import ../state/engine
import ../types/runtime_values
import ../ipc/command_registry
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

proc defaultCommandLabel(binding: KeyBindingConfig): string =
  let id = binding.resolvedCommandId()
  if id.isNone:
    return binding.command.commandBase().replace("-", " ").capitalizeAscii()
  case id.unsafeGet()
  of CommandId.ShowHotkeyOverlay, CommandId.ToggleHotkeyOverlay:
    "Show Important Hotkeys"
  of CommandId.HideHotkeyOverlay:
    "Hide Important Hotkeys"
  of CommandId.SpawnTerminal:
    "Open Terminal"
  of CommandId.Spawn:
    let parts = binding.command.strip().splitWhitespace()
    if parts.len >= 2:
      "Spawn " & parts[1]
    else:
      "Spawn Command"
  else:
    commandName(id.unsafeGet()).replace("-", " ").capitalizeAscii()

proc findBindingForCommand(
    bindings: seq[KeyBindingConfig], command: string
): Option[KeyBindingConfig] =
  let target = resolveCommandId(command)
  if target.isNone:
    return none(KeyBindingConfig)
  for binding in bindings:
    if binding.hotkeyOverlayTitleKind == HotkeyOverlayTitleKind.HotkeyTitleHidden:
      continue
    let id = binding.resolvedCommandId()
    if id.isSome and id.unsafeGet() == target.unsafeGet():
      return some(binding)
  none(KeyBindingConfig)

proc rowForBinding(binding: KeyBindingConfig): HotkeyOverlayRow =
  let label =
    if binding.hotkeyOverlayTitleKind == HotkeyOverlayTitleKind.HotkeyTitleCustom:
      binding.hotkeyOverlayTitle
    else:
      binding.defaultCommandLabel()
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
    let id = binding.resolvedCommandId()
    if id.isSome and id.unsafeGet() in {CommandId.Spawn, CommandId.SpawnTerminal} and
        (binding.modifiers and 64'u32) != 0:
      result.addRow(binding.rowForBinding())
