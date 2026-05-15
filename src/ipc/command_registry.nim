import std/[options, strutils]
import ../types/ipc_commands

export ipc_commands

proc aliasMatches(aliases, action: string): bool =
  if aliases.len == 0:
    return false
  ("|" & aliases & "|").contains("|" & action & "|")

proc resolveCommandSpec*(action: string): Option[CommandSpec] =
  for spec in CommandSpecs:
    if action == spec.name or spec.aliases.aliasMatches(action):
      return some(spec)
  none(CommandSpec)

proc allCommandNames*(): seq[string] =
  for spec in CommandSpecs:
    result.add(spec.name)
    if spec.aliases.len > 0:
      for alias in spec.aliases.split('|'):
        result.add(alias)
