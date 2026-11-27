import std/[options, strutils]
import ../types/ipc_commands
import ../types/runtime_values

export ipc_commands

type CommandView* = object
  id*: CommandId
  name*: string
  argShape*: CommandArgShape

proc resolveCommandId*(text: string): Option[CommandId] =
  for row in CommandSpellings:
    if text == row.text:
      return some row.id
  none CommandId

proc resolveCommandLine*(text: string): Option[CommandId] =
  let parts = text.strip().splitWhitespace()
  if parts.len == 0:
    return none CommandId
  resolveCommandId(parts[0])

proc resolvedCommandId*(binding: KeyBindingConfig): Option[CommandId] =
  if binding.commandId.isSome:
    binding.commandId
  else:
    resolveCommandLine(binding.command)

proc commandName*(id: CommandId): string =
  for row in CommandSpellings:
    if row.canonical and row.id == id:
      return row.text
  ""

proc commandArgShape*(id: CommandId): CommandArgShape =
  CommandMetas[id].argShape

iterator commandAliases*(id: CommandId): string =
  for row in CommandSpellings:
    if not row.canonical and row.id == id:
      yield row.text

proc commandSpec*(id: CommandId): CommandView =
  CommandView(id: id, name: commandName(id), argShape: commandArgShape(id))

proc aliasesFor*(spec: CommandView): seq[string] =
  for alias in commandAliases(spec.id):
    result.add(alias)

proc allCommandNames*(): seq[string] =
  for row in CommandSpellings:
    result.add(row.text)
