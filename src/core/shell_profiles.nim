import std/[options, strutils]
import ../types/runtime_values

proc shellProfile*(shells: ShellsConfig, name: string): Option[ShellProfileConfig] =
  for profile in shells.profiles:
    if profile.name == name:
      return some(profile)
  none(ShellProfileConfig)

proc hasShellProfile*(shells: ShellsConfig, name: string): bool =
  shells.shellProfile(name).isSome

proc firstShellProfileName*(shells: ShellsConfig): string =
  for name in shells.cycle:
    if shells.hasShellProfile(name):
      return name
  if shells.profiles.len > 0:
    return shells.profiles[0].name
  ""

proc normalizeShells*(shells: var ShellsConfig) =
  var names: seq[string] = @[]
  var profiles: seq[ShellProfileConfig] = @[]
  for profile in shells.profiles:
    let name = profile.name.strip()
    if name.len == 0 or profile.launch.len == 0:
      continue
    if names.find(name) >= 0:
      profiles[names.find(name)] = profile
    else:
      names.add(name)
      profiles.add(profile)
  shells.profiles = profiles

  var cycle: seq[string] = @[]
  for name in shells.cycle:
    if shells.hasShellProfile(name) and cycle.find(name) < 0:
      cycle.add(name)
  shells.cycle = cycle

  if shells.active.len == 0 or not shells.hasShellProfile(shells.active):
    shells.active = shells.firstShellProfileName()

  let fallback = shells.watchdog.fallback.strip()
  if fallback.len > 0 and not shells.hasShellProfile(fallback):
    shells.watchdog.fallback = ""

proc fallbackShellName*(shells: ShellsConfig): string =
  let fallback = shells.watchdog.fallback.strip()
  if fallback.len > 0 and shells.hasShellProfile(fallback):
    return fallback
  shells.firstShellProfileName()

proc shouldWatchShells*(shells: ShellsConfig): bool =
  shells.enabled and shells.watchdog.enabled and shells.profiles.len > 0

proc activeShellProfile*(shells: ShellsConfig): Option[ShellProfileConfig] =
  if not shells.enabled:
    return none(ShellProfileConfig)
  shells.shellProfile(shells.active)

proc nextShellName*(shells: ShellsConfig): string =
  if shells.profiles.len == 0:
    return ""
  let active = shells.active
  var ordered: seq[string] = @[]
  for name in shells.cycle:
    if shells.hasShellProfile(name) and ordered.find(name) < 0:
      ordered.add(name)
  if ordered.len == 0:
    for profile in shells.profiles:
      ordered.add(profile.name)

  let current = ordered.find(active)
  if current < 0:
    return ordered[0]
  ordered[(current + 1) mod ordered.len]

proc sameShellsConfig*(a, b: ShellsConfig): bool =
  a.configured == b.configured and a.enabled == b.enabled and a.active == b.active and
    a.cycle == b.cycle and a.profiles == b.profiles
