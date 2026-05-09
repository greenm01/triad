import os, strutils

const CommonTerminalCommands* = [
  "kgx",
  "gnome-terminal",
  "konsole",
  "xfce4-terminal",
  "mate-terminal",
  "lxterminal",
  "foot",
  "kitty",
  "alacritty",
  "wezterm",
  "ghostty",
  "xterm"
]

proc commandExists*(command: string): bool =
  if command.len == 0:
    return false
  if command.isAbsolute or command.contains(DirSep):
    return fileExists(command)
  findExe(command).len > 0

proc commandVector(value: string): seq[string] =
  let stripped = value.strip()
  if stripped.len == 0:
    return @[]
  stripped.splitWhitespace()

proc terminalCandidates*(configured = getEnv("TERMINAL", "")): seq[seq[string]] =
  let terminal = commandVector(configured)
  if terminal.len > 0:
    result.add(terminal)

  result.add(@["xdg-terminal-exec"])
  result.add(@["x-terminal-emulator"])

  for command in CommonTerminalCommands:
    result.add(@[command])

proc terminalCandidates*(configuredCommand: seq[string]; envTerminal = getEnv(
    "TERMINAL", "")): seq[seq[string]] =
  if configuredCommand.len > 0:
    result.add(configuredCommand)
  for candidate in terminalCandidates(envTerminal):
    result.add(candidate)

proc resolveTerminalCommand*(configured = getEnv("TERMINAL", "");
    exists: proc(command: string): bool {.closure.} = commandExists): seq[string] =
  for candidate in terminalCandidates(configured):
    if candidate.len > 0 and exists(candidate[0]):
      return candidate

proc resolveTerminalCommand*(configuredCommand: seq[string];
    envTerminal = getEnv("TERMINAL", "");

exists: proc(command: string): bool {.closure.} = commandExists): seq[string] =
  for candidate in terminalCandidates(configuredCommand, envTerminal):
    if candidate.len > 0 and exists(candidate[0]):
      return candidate
