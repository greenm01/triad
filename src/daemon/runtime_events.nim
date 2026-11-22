import std/[posix, selectors]

type
  RuntimeEvents* = object
    childReady*: bool
    timerReady*: bool

  RuntimeEventSource* = object
    signalFd*: int
    timerFd*: int
    selector*: Selector[int]

const
  ClockMonotonic* = cint(1)
  TimerFdCloExec* = cint(0x80000)
  TimerFdNonBlock* = cint(0x800)

type
  Timespec* {.importc: "struct timespec", header: "<time.h>", bycopy.} = object
    tv_sec*: int64
    tv_nsec*: int64

  Itimerspec* {.importc: "struct itimerspec", header: "<time.h>", bycopy.} = object
    it_interval*: Timespec
    it_value*: Timespec

proc timerfdCreate(clockId, flags: cint): cint
    {.importc: "timerfd_create", header: "<sys/timerfd.h>".}
proc timerfdSetTime(fd, flags: cint, newValue, oldValue: ptr Itimerspec): cint
    {.importc: "timerfd_settime", header: "<sys/timerfd.h>".}

proc initRuntimeEventSource*(): RuntimeEventSource =
  RuntimeEventSource(signalFd: -1, timerFd: -1)

proc openRuntimeEventSource*(): RuntimeEventSource =
  result = initRuntimeEventSource()
  result.selector = newSelector[int]()
  result.signalFd = result.selector.registerSignal(SIGCHLD, 0)
  result.timerFd = timerfdCreate(ClockMonotonic, TimerFdCloExec or TimerFdNonBlock)

proc setTimer*(source: var RuntimeEventSource, delayMs: int64) =
  if source.timerFd < 0:
    return
  var value: Itimerspec
  if delayMs > 0:
    value.it_value.tv_sec = delayMs div 1000'i64
    value.it_value.tv_nsec = (delayMs mod 1000'i64) * 1_000_000'i64
  discard timerfdSetTime(cint(source.timerFd), 0, addr value, nil)

proc fd*(source: RuntimeEventSource): int =
  source.signalFd

proc timerFd*(source: RuntimeEventSource): int =
  source.timerFd

proc drain*(source: var RuntimeEventSource): RuntimeEvents =
  if source.signalFd >= 0:
    var buffer: array[128, byte]
    while true:
      let count = posix.read(cint(source.signalFd), addr buffer, buffer.len)
      if count > 0:
        result.childReady = true
        continue
      if count == 0 or errno != EINTR:
        break

  if source.timerFd >= 0:
    var counter: array[8, byte]
    while true:
      let count = posix.read(cint(source.timerFd), addr counter, counter.len)
      if count == counter.len:
        result.timerReady = true
        continue
      if count >= 0 or errno != EINTR:
        break

proc closeRuntimeEventSource*(source: var RuntimeEventSource) =
  if source.signalFd >= 0:
    discard posix.close(cint(source.signalFd))
    source.signalFd = -1
  if source.timerFd >= 0:
    discard posix.close(cint(source.timerFd))
    source.timerFd = -1
  if source.selector != nil:
    close(source.selector)
    source.selector = nil
