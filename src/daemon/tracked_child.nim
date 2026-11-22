import std/[osproc, posix]

type
  TrackedChildPhase* {.pure.} = enum
    Starting
    Running
    Terminating
    Killing
    Reaped

  TrackedChild* = object
    process*: Process
    phase*: TrackedChildPhase
    deadlineMs*: int64
    termSent*: bool
    killSent*: bool
    exitCode*: int

proc initTrackedChild*(process: Process, nowMs, timeoutMs: int64): TrackedChild =
  TrackedChild(
    process: process,
    phase: TrackedChildPhase.Starting,
    deadlineMs: nowMs + timeoutMs,
  )

proc beginTermination*(child: var TrackedChild, nowMs, timeoutMs: int64) =
  if child.process == nil or child.phase == TrackedChildPhase.Reaped:
    return
  if not child.termSent:
    try:
      child.process.terminate()
    except CatchableError:
      discard
    child.termSent = true
  child.phase = TrackedChildPhase.Terminating
  child.deadlineMs = nowMs + timeoutMs

proc advanceTrackedChild*(child: var TrackedChild, nowMs, killTimeoutMs: int64): bool =
  if child.process == nil or child.phase == TrackedChildPhase.Reaped:
    return false

  let code = child.process.peekExitCode()
  if code != -1:
    child.exitCode = code
    child.phase = TrackedChildPhase.Reaped
    return true

  case child.phase
  of TrackedChildPhase.Starting:
    if nowMs >= child.deadlineMs:
      child.phase = TrackedChildPhase.Running
  of TrackedChildPhase.Terminating:
    if nowMs >= child.deadlineMs and not child.killSent:
      try:
        child.process.kill()
      except CatchableError:
        discard
      child.killSent = true
      child.phase = TrackedChildPhase.Killing
      child.deadlineMs = nowMs + killTimeoutMs
  else:
    discard
  false

proc reapReleasedPid*(pid: int32): bool =
  var status: cint
  posix.waitpid(Pid(pid), status, WNOHANG) == Pid(pid)
