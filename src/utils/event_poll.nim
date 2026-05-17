import std/os

from posix import EINTR, POLLERR, POLLHUP, POLLIN, POLLNVAL, TPollfd, Tnfds, errno, poll

type RuntimeEventPollResult* = object
  waylandReady*: bool
  asyncReady*: bool
  switchReady*: bool
  interrupted*: bool
  failed*: bool
  errorCode*: OSErrorCode

proc addPollFd(fds: var seq[TPollfd], fd: int): int =
  if fd < 0:
    return -1
  result = fds.len
  fds.add(TPollfd(fd: cint(fd), events: POLLIN, revents: 0))

proc fdReady(fds: seq[TPollfd], idx: int): bool =
  if idx < 0 or idx >= fds.len:
    return false
  (fds[idx].revents and (POLLIN or POLLERR or POLLHUP or POLLNVAL)) != 0

proc waitForRuntimeEventFds*(
    fds: var seq[TPollfd],
    waylandFd: int,
    asyncFd: int,
    switchFds: openArray[int32],
    timeoutMs: int,
): RuntimeEventPollResult =
  fds.setLen(0)
  let waylandIdx = fds.addPollFd(waylandFd)
  let asyncIdx = fds.addPollFd(asyncFd)
  let switchStart = fds.len
  for fd in switchFds:
    discard fds.addPollFd(fd)

  if fds.len == 0:
    return

  let ready = poll(addr fds[0], Tnfds(fds.len), cint(timeoutMs))
  if ready < 0:
    if errno == EINTR:
      result.interrupted = true
      return
    result.failed = true
    result.errorCode = OSErrorCode(errno)
    return

  result.waylandReady = fds.fdReady(waylandIdx)
  result.asyncReady = fds.fdReady(asyncIdx)
  for idx in switchStart ..< fds.len:
    if fds.fdReady(idx):
      result.switchReady = true
      break
