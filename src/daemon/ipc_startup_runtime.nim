import std/asyncdispatch

type
  IpcStartupGateStatus* {.pure.} = enum
    Pending
    Ready
    Timeout

  IpcStartupGate* = object
    listeners*: seq[Future[bool]]
    startedAtMs*: int64
    open*: bool
    timeoutLogged*: bool
    ready*: bool

proc initIpcStartupGate*(startedAtMs: int64): IpcStartupGate =
  IpcStartupGate(startedAtMs: startedAtMs)

proc addListener*(gate: var IpcStartupGate, listener: Future[bool]) =
  gate.listeners.add(listener)

proc pollIpcStartupGate*(
    gate: var IpcStartupGate, nowMs: int64, timeoutMs: int
): IpcStartupGateStatus =
  if gate.open:
    return if gate.ready: IpcStartupGateStatus.Ready else: IpcStartupGateStatus.Timeout

  var pending = false
  var allReady = true
  for listener in gate.listeners:
    if not listener.finished:
      pending = true
    elif listener.failed or not listener.read:
      allReady = false

  if not pending and allReady:
    gate.open = true
    gate.ready = true
    return IpcStartupGateStatus.Ready

  if nowMs - gate.startedAtMs >= int64(timeoutMs):
    gate.open = true
    gate.ready = false
    return IpcStartupGateStatus.Timeout

  IpcStartupGateStatus.Pending
