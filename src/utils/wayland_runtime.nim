import wayland/native/client
from posix import TFdSet, FD_ZERO, FD_SET, FD_ISSET, Timeval, Time, Suseconds, select

proc dispatchPendingWayland*(display: ptr Display): bool =
  if display == nil:
    return false

  while true:
    let dispatched = display.dispatch_pending()
    if dispatched == -1:
      return false
    if dispatched == 0:
      return true

proc prepareWaylandRead*(display: ptr Display): bool =
  if display == nil:
    return false

  while display.prepare_read() != 0:
    let dispatched = display.dispatch_pending()
    if dispatched == -1:
      return false
  true

proc waitForWaylandEvents*(display: ptr Display; timeoutMs: int): bool =
  if display == nil:
    return false

  let fd = display.get_fd()
  if fd < 0:
    return false

  var readfds: TFdSet
  FD_ZERO(readfds)
  FD_SET(fd, readfds)
  var timeout = Timeval(
    tv_sec: Time(timeoutMs div 1000),
    tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
  let ready = select(fd + 1, addr readfds, nil, nil, addr timeout)
  ready > 0 and FD_ISSET(fd, readfds) != 0
