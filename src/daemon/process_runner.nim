import std/[os, osproc, strtabs, strutils, times]
import chronicles
import ../types/model
from ../types/runtime_values import ConfigNotificationEvent
import ../utils/process_options
import ../utils/terminal

proc commandArgs(command: seq[string]): seq[string] =
  if command.len > 1:
    command[1 ..^ 1]
  else:
    @[]

proc pollProcessExitCode*(p: Process, timeoutMs: int, pollMs = 25): int =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  result = p.peekExitCode()
  while result == -1 and epochTime() < deadline:
    let remainingMs = int(max(1.0, (deadline - epochTime()) * 1000.0))
    sleep(min(pollMs, remainingMs))
    result = p.peekExitCode()

proc configuredProcessEnv*(
    model: Model, baseEnv: StringTableRef = nil
): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  if baseEnv == nil:
    for key, value in envPairs():
      result[key] = value
  else:
    for key, value in baseEnv.pairs:
      result[key] = value

  for entry in model.environment:
    if entry.unset:
      result.del(entry.name)
    else:
      result[entry.name] = entry.value

proc commandExistsInEnv(command: string, env: StringTableRef): bool =
  if command.len == 0:
    return false
  if command.contains($DirSep) or (AltSep != '\0' and command.contains($AltSep)):
    return fileExists(command)
  let path = env.getOrDefault("PATH", getEnv("PATH", ""))
  for dir in path.split(PathSep):
    if dir.len > 0 and fileExists(dir / command):
      return true
  false

proc spawnStartupCommands*(model: Model): seq[Process] =
  let env = model.configuredProcessEnv()
  for cmd in model.startupCommands:
    if cmd.len > 0:
      try:
        let p = startProcess(
          cmd[0], args = cmd.commandArgs(), env = env, options = InheritedProcessOptions
        )
        info "Spawned startup command", cmd = cmd[0], pid = p.processID
        result.add(p)
      except CatchableError as e:
        warn "Failed to spawn startup command", cmd = cmd[0], error = e.msg

proc spawnScreenLock*(model: Model, command: seq[string]): Process =
  if command.len == 0:
    warn "Screen lock command is not configured"
    return

  try:
    let p = startProcess(
      command[0],
      args = command.commandArgs(),
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    info "Spawned screen lock", cmd = command[0], pid = p.processID
    result = p
  except CatchableError as e:
    warn "Failed to spawn screen lock", cmd = command[0], error = e.msg

proc spawnWindowMenu*(
    model: Model, command: seq[string], windowId: uint32, x, y: int32
): Process =
  if command.len == 0:
    warn "Window menu command is not configured"
    return

  try:
    let p = startProcess(
      command[0],
      args = command.commandArgs(),
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    info "Spawned window menu",
      cmd = command[0], pid = p.processID, windowId = windowId, x = x, y = y
    result = p
  except CatchableError as e:
    warn "Failed to spawn window menu",
      cmd = command[0], windowId = windowId, error = e.msg

proc spawnConfigNotification*(
    model: Model, event: ConfigNotificationEvent, command: seq[string]
): Process =
  if command.len == 0:
    return

  try:
    let p = startProcess(
      command[0],
      args = command.commandArgs(),
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    info "Spawned config notification",
      event = $event, cmd = command[0], pid = p.processID
    result = p
  except CatchableError as e:
    warn "Failed to spawn config notification",
      event = $event, cmd = command[0], error = e.msg

proc spawnTerminal*(model: Model): Process =
  let env = model.configuredProcessEnv()
  for command in terminalCandidates(model.terminal.command):
    if command.len == 0 or not commandExistsInEnv(command[0], env):
      continue
    try:
      let p = startProcess(
        command[0],
        args = command.commandArgs(),
        env = env,
        options = InheritedProcessOptions,
      )
      info "Spawned terminal", terminal = command[0], pid = p.processID
      return p
    except CatchableError as e:
      trace "Terminal candidate failed", terminal = command[0], error = e.msg

  warn "No terminal command could be spawned"

proc spawnCommand*(model: Model, command: seq[string]): Process =
  if command.len == 0:
    warn "Spawn command is empty"
    return

  try:
    let p = startProcess(
      command[0],
      args = command.commandArgs(),
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    info "Spawned command", cmd = command[0], pid = p.processID
    result = p
  except CatchableError as e:
    warn "Failed to spawn command", cmd = command[0], error = e.msg
