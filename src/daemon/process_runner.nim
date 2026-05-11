import std/[os, osproc, times]
import chronicles
import ../types/model
from ../types/runtime_values import WindowId
import ../utils/terminal

proc commandArgs(command: seq[string]): seq[string] =
  if command.len > 1:
    command[1..^1]
  else:
    @[]

proc pollProcessExitCode*(p: Process; timeoutMs: int; pollMs = 25): int =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  result = p.peekExitCode()
  while result == -1 and epochTime() < deadline:
    let remainingMs = int(max(1.0, (deadline - epochTime()) * 1000.0))
    sleep(min(pollMs, remainingMs))
    result = p.peekExitCode()

proc spawnStartupCommands*(model: Model) =
  for cmd in model.startupCommands:
    if cmd.len > 0:
      try:
        let p = startProcess(cmd[0], args = cmd.commandArgs(),
          options = {poUsePath})
        info "Spawned startup command", cmd = cmd[0], pid = p.processID
      except CatchableError as e:
        warn "Failed to spawn startup command", cmd = cmd[0], error = e.msg

proc spawnScreenLock*(command: seq[string]) =
  if command.len == 0:
    warn "Screen lock command is not configured"
    return

  try:
    let p = startProcess(command[0], args = command.commandArgs(),
      options = {poUsePath})
    info "Spawned screen lock", cmd = command[0], pid = p.processID
  except CatchableError as e:
    warn "Failed to spawn screen lock", cmd = command[0], error = e.msg

proc spawnWindowMenu*(
    command: seq[string]; windowId: WindowId; x, y: int32) =
  if command.len == 0:
    warn "Window menu command is not configured"
    return

  try:
    let p = startProcess(command[0], args = command.commandArgs(),
      options = {poUsePath})
    info "Spawned window menu", cmd = command[0], pid = p.processID,
        windowId = windowId, x = x, y = y
  except CatchableError as e:
    warn "Failed to spawn window menu", cmd = command[0],
      windowId = windowId, error = e.msg

proc spawnTerminal*(model: Model) =
  for command in terminalCandidates(model.terminal.command):
    if command.len == 0 or not commandExists(command[0]):
      continue
    try:
      let p = startProcess(command[0], args = command.commandArgs(),
        options = {poUsePath})
      info "Spawned terminal", terminal = command[0], pid = p.processID
      return
    except CatchableError as e:
      trace "Terminal candidate failed", terminal = command[0], error = e.msg

  warn "No terminal command could be spawned"

proc spawnCommand*(command: seq[string]) =
  if command.len == 0:
    warn "Spawn command is empty"
    return

  try:
    let p = startProcess(command[0], args = command.commandArgs(),
      options = {poUsePath})
    info "Spawned command", cmd = command[0], pid = p.processID
  except CatchableError as e:
    warn "Failed to spawn command", cmd = command[0], error = e.msg
