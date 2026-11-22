import std/osproc

type ProcessHandle* = ref object
  process*: Process
  pid*: int
  fake*: bool
  fakeExitCode*: int

proc newProcessHandle*(process: Process): ProcessHandle =
  if process == nil: nil else: ProcessHandle(process: process)

proc newFakeProcessHandle*(pid: int): ProcessHandle =
  ProcessHandle(pid: pid, fake: true, fakeExitCode: -1)

proc processID*(handle: ProcessHandle): int =
  if handle == nil:
    return -1
  if handle.fake:
    handle.pid
  elif handle.process != nil:
    handle.process.processID
  else:
    -1

proc peekExitCode*(handle: ProcessHandle): int =
  if handle == nil:
    return -1
  if handle.fake:
    handle.fakeExitCode
  elif handle.process != nil:
    handle.process.peekExitCode()
  else:
    -1

proc setFakeExitCode*(handle: ProcessHandle, code: int) =
  if handle != nil:
    handle.fakeExitCode = code

proc terminateProcess*(handle: ProcessHandle) =
  if handle == nil or handle.fake or handle.process == nil:
    return
  handle.process.terminate()

proc killProcess*(handle: ProcessHandle) =
  if handle == nil or handle.fake or handle.process == nil:
    return
  handle.process.kill()

proc closeProcessHandle*(handle: ProcessHandle) =
  if handle == nil or handle.fake or handle.process == nil:
    return
  handle.process.close()
