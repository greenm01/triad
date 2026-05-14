import std/strutils

type PointerDeviceClass* {.pure.} = enum
  Mouse
  Touchpad
  Trackpoint
  Trackball

proc pointerClassFor*(
    deviceName: string, tapFingerCount: int32, dwtSupport, dwtpSupport: bool
): PointerDeviceClass =
  let name = deviceName.toLowerAscii()
  if "trackball" in name:
    PointerDeviceClass.Trackball
  elif "trackpoint" in name or "pointing stick" in name:
    PointerDeviceClass.Trackpoint
  elif tapFingerCount > 0 or dwtSupport or dwtpSupport or "touchpad" in name:
    PointerDeviceClass.Touchpad
  else:
    PointerDeviceClass.Mouse
