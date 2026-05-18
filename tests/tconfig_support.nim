import std/[options, os, sequtils, strutils, unittest]
import ../src/config/[apply, defaults, parser, reload_policy]
import ../src/core/[layout_selection_codec, native_layout_codec]
import ../src/core/msg
import ../src/ipc/commands
import ../src/state/[engine, invariants, snapshot]
import ../src/systems/[overview_hot_corners, runtime_facade, workspaces]
import ../src/types/[model, runtime_values]

export
  options, os, sequtils, strutils, unittest, apply, defaults, parser, reload_policy,
  msg, commands, engine, invariants, snapshot, overview_hot_corners, runtime_facade,
  workspaces, model, runtime_values

const
  Shift* = 1'u32
  Ctrl* = 4'u32
  Alt* = 8'u32
  Super* = 64'u32

proc commandForBinding*(
    config: Config, key: string, modifiers: uint32, mode = BindingMode.BindAlways
): string =
  for binding in config.keyBindings:
    if binding.key == key and binding.modifiers == modifiers and binding.mode == mode:
      return binding.command
  ""

proc msgKindForBinding*(
    config: Config, key: string, modifiers: uint32, mode = BindingMode.BindAlways
): MsgKind =
  let command = config.commandForBinding(key, modifiers, mode)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  parsed.get().kind

proc layoutForBinding*(config: Config, key: string, modifiers: uint32): LayoutMode =
  let command = config.commandForBinding(key, modifiers)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  check parsed.get().kind == MsgKind.CmdSetLayout
  parsed.get().newLayout

proc layoutIdForBinding*(config: Config, key: string, modifiers: uint32): string =
  let command = config.commandForBinding(key, modifiers)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  case parsed.get().kind
  of MsgKind.CmdSetLayout:
    result = $parsed.get().newLayout
  of MsgKind.CmdSetCustomLayout:
    result = parsed.get().customLayout.layoutIdString()
  of MsgKind.CmdSetNativeLayout:
    result = parsed.get().nativeLayout.nativeLayoutIdString()
  else:
    check false

proc spawnForBinding*(config: Config, key: string, modifiers: uint32): seq[string] =
  let command = config.commandForBinding(key, modifiers)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  check parsed.get().kind == MsgKind.CmdSpawn
  parsed.get().spawnCommand
