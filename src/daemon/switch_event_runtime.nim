import std/[algorithm, os, posix]
import chronicles
import ../types/runtime_values
import bindings_runtime, state

const
  EvdevDeviceGlob = "/dev/input/event*"
  EvdevEventSwitch = 0x05'u16
  EvdevSwitchLid = 0x00'u16
  EvdevSwitchTabletMode = 0x01'u16

type EvdevInputEvent = object
  time: Timeval
  eventType: uint16
  code: uint16
  value: cint

proc switchEventKindForEvdev*(eventType, code: uint16, value: cint): SwitchEventKind =
  if eventType != EvdevEventSwitch:
    return SwitchEventKind.SwitchNone
  case code
  of EvdevSwitchLid:
    if value == 0: SwitchEventKind.SwitchLidOpen else: SwitchEventKind.SwitchLidClose
  of EvdevSwitchTabletMode:
    if value == 0:
      SwitchEventKind.SwitchTabletModeOff
    else:
      SwitchEventKind.SwitchTabletModeOn
  else:
    SwitchEventKind.SwitchNone

proc dispatchEvdevSwitchEvent*(
    daemon: var TriadDaemon, eventType, code: uint16, value: cint
): bool =
  let kind = switchEventKindForEvdev(eventType, code, value)
  if kind == SwitchEventKind.SwitchNone:
    return false
  daemon.dispatchSwitchEvent(kind)

proc closeSwitchEventDevices*(daemon: var TriadDaemon) =
  for device in daemon.switchEventDevices:
    if device.fd >= 0:
      discard posix.close(cint(device.fd))
  daemon.switchEventDevices.setLen(0)

proc switchEventDevicePaths(): seq[string] =
  for path in walkFiles(EvdevDeviceGlob):
    result.add(path)
  result.sort()

proc openSwitchEventDevice(path: string): int32 =
  let fd =
    posix.open(path.cstring, posix.O_RDONLY or posix.O_NONBLOCK or posix.O_CLOEXEC)
  if fd < 0:
    return -1
  int32(fd)

proc configureSwitchEventRuntime*(daemon: var TriadDaemon, reason: string) =
  daemon.closeSwitchEventDevices()
  if daemon.runtimeState.model.switchEvents.len == 0:
    return

  var opened = 0
  for path in switchEventDevicePaths():
    let fd = openSwitchEventDevice(path)
    if fd < 0:
      debug "Unable to open switch-event input device",
        path = path, reason = reason, error = osErrorMsg(OSErrorCode(errno))
      continue
    daemon.switchEventDevices.add(SwitchEventDeviceRuntime(fd: fd, path: path))
    inc opened

  if opened == 0:
    warn "No readable switch-event input devices",
      reason = reason, configuredEvents = daemon.runtimeState.model.switchEvents.len
  else:
    info "Switch-event input devices configured", reason = reason, devices = opened

proc removeSwitchEventDevice(daemon: var TriadDaemon, idx: int, reason: string) =
  let device = daemon.switchEventDevices[idx]
  if device.fd >= 0:
    discard posix.close(cint(device.fd))
  warn "Switch-event input device disabled", path = device.path, reason = reason
  daemon.switchEventDevices.delete(idx)

proc pollSwitchEventDevice(daemon: var TriadDaemon, idx: int): bool =
  var event = EvdevInputEvent()
  let bytesRead = posix.read(
    cint(daemon.switchEventDevices[idx].fd), addr event, sizeof(EvdevInputEvent)
  )
  if bytesRead == sizeof(EvdevInputEvent):
    discard daemon.dispatchEvdevSwitchEvent(event.eventType, event.code, event.value)
    return true
  if bytesRead == 0:
    daemon.removeSwitchEventDevice(idx, "eof")
    return false
  if bytesRead < 0:
    let err = errno
    if err in [EAGAIN, EWOULDBLOCK, EINTR]:
      return false
    daemon.removeSwitchEventDevice(idx, osErrorMsg(OSErrorCode(err)))
    return false
  daemon.removeSwitchEventDevice(idx, "partial read")
  false

proc pollSwitchEventDevices*(daemon: var TriadDaemon) =
  var i = 0
  while i < daemon.switchEventDevices.len:
    let before = daemon.switchEventDevices.len
    while i < daemon.switchEventDevices.len and daemon.pollSwitchEventDevice(i):
      discard
    if daemon.switchEventDevices.len == before:
      inc i
