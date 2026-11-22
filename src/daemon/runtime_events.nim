import std/[posix, selectors]

type
  RuntimeEvents* = object
    childReady*: bool

  RuntimeEventSource* = object
    signalFd*: int
    selector*: Selector[int]

proc initRuntimeEventSource*(): RuntimeEventSource =
  RuntimeEventSource(signalFd: -1)

proc openRuntimeEventSource*(): RuntimeEventSource =
  result = initRuntimeEventSource()
  result.selector = newSelector[int]()
  result.signalFd = result.selector.registerSignal(SIGCHLD, 0)

proc fd*(source: RuntimeEventSource): int =
  source.signalFd

proc drain*(source: var RuntimeEventSource): RuntimeEvents =
  if source.signalFd < 0:
    return

  var buffer: array[128, byte]
  while true:
    let count = posix.read(cint(source.signalFd), addr buffer, buffer.len)
    if count > 0:
      result.childReady = true
      continue
    if count == 0 or errno != EINTR:
      break

proc closeRuntimeEventSource*(source: var RuntimeEventSource) =
  if source.signalFd >= 0:
    discard posix.close(cint(source.signalFd))
    source.signalFd = -1
  if source.selector != nil:
    close(source.selector)
    source.selector = nil
