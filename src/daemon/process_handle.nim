import std/osproc

type ProcessHandle* = ref object
  process*: Process
  pid*: int
  fake*: bool
  fakeExitCode*: int

proc newProcessHandle*(process: Process): ProcessHandle =
  ProcessHandle(process: process)

proc newFakeProcessHandle*(pid: int): ProcessHandle =
  ProcessHandle(pid: pid, fake: true, fakeExitCode: -1)

proc processID*(handle: ProcessHandle): int =
  if handle.fake:
    handle.pid
  else:
    handle.process.processID

proc peekExitCode*(handle: ProcessHandle): int =
  if handle.fake:
    handle.fakeExitCode
  else:
    handle.process.peekExitCode()

proc setFakeExitCode*(handle: ProcessHandle, code: int) =
  handle.fakeExitCode = code

proc terminateProcess*(handle: ProcessHandle) =
  if not handle.fake:
    handle.process.terminate()

proc killProcess*(handle: ProcessHandle) =
  if not handle.fake:
    handle.process.kill()

proc closeProcessHandle*(handle: ProcessHandle) =
  if not handle.fake and handle.process != nil:
    handle.process.close()
