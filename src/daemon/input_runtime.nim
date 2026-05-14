import std/[os, posix, tables]
import chronicles
import wayland/native/client
import wayland/native/common
import protocols/river_input_management/client as riverInput
import protocols/river_libinput_config/client as riverLibinput
import protocols/river_xkb_config/client as riverXkbConfig
import ../types/runtime_values
import input_device_classification, state, wayland_helpers

const
  RiverInputTypeKeyboard = 0'u32
  RiverInputTypePointer = 1'u32
  LibinputSendEventsEnabled = 0'u32
  LibinputSendEventsDisabled = 1'u32
  LibinputSendEventsDisabledOnExternalMouse = 2'u32
  LibinputBoolDisabled = 0'u32
  LibinputBoolEnabled = 1'u32
  LibinputDragLockDisabled = 0'u32
  LibinputDragLockEnabledTimeout = 1'u32
  LibinputAccelNone = 0'u32
  LibinputAccelFlat = 1'u32
  LibinputAccelAdaptive = 2'u32
  LibinputScrollNone = 0'u32
  LibinputScrollTwoFinger = 1'u32
  LibinputScrollEdge = 2'u32
  LibinputScrollOnButtonDown = 4'u32
  LibinputClickButtonAreas = 1'u32
  LibinputClickFinger = 2'u32
  LibinputButtonMapLrm = 0'u32
  LibinputButtonMapLmr = 1'u32
  XkbKeymapFormatTextV1 = 1'u32

type
  XkbContext {.importc: "struct xkb_context", header: "<xkbcommon/xkbcommon.h>".} = object
  XkbKeymap {.importc: "struct xkb_keymap", header: "<xkbcommon/xkbcommon.h>".} = object

  XkbRuleNames {.
    bycopy, importc: "struct xkb_rule_names", header: "<xkbcommon/xkbcommon.h>"
  .} = object
    rules: cstring
    model: cstring
    layout: cstring
    variant: cstring
    options: cstring

proc xkbContextNew(
  flags: cint
): ptr XkbContext {.importc: "xkb_context_new", dynlib: "libxkbcommon.so.0".}

proc xkbContextUnref(
  context: ptr XkbContext
) {.importc: "xkb_context_unref", dynlib: "libxkbcommon.so.0".}

proc xkbKeymapNewFromNames(
  context: ptr XkbContext, names: ptr XkbRuleNames, flags: cint
): ptr XkbKeymap {.importc: "xkb_keymap_new_from_names", dynlib: "libxkbcommon.so.0".}

proc xkbKeymapGetAsString(
  keymap: ptr XkbKeymap, format: cint
): cstring {.importc: "xkb_keymap_get_as_string", dynlib: "libxkbcommon.so.0".}

proc xkbKeymapUnref(
  keymap: ptr XkbKeymap
) {.importc: "xkb_keymap_unref", dynlib: "libxkbcommon.so.0".}

proc cFree(data: pointer) {.importc: "free", header: "<stdlib.h>".}

template currentModel(daemon: TriadDaemon): untyped =
  daemon.runtimeState.model

proc callbackDaemon(data: pointer, context: string): ptr TriadDaemon =
  result = daemonFromData(data)
  if result == nil:
    warn "Ignoring input callback without daemon context", callback = context

var inputDeviceListener*: riverInput.RiverInputDeviceV1Listener
var xkbKeymapListener*: riverXkbConfig.RiverXkbKeymapV1Listener
var xkbKeyboardListener*: riverXkbConfig.RiverXkbKeyboardV1Listener
var libinputDeviceListener*: riverLibinput.RiverLibinputDeviceV1Listener
var libinputResultListener*: riverLibinput.RiverLibinputResultV1Listener

template inputDevicePtr(
    runtime: InputDeviceRuntime
): ptr riverInput.RiverInputDeviceV1 =
  cast[ptr riverInput.RiverInputDeviceV1](runtime.pointer)

template libinputDevicePtr(
    runtime: LibinputDeviceRuntime
): ptr riverLibinput.RiverLibinputDeviceV1 =
  cast[ptr riverLibinput.RiverLibinputDeviceV1](runtime.pointer)

template xkbKeyboardPtr(
    runtime: XkbKeyboardRuntime
): ptr riverXkbConfig.RiverXkbKeyboardV1 =
  cast[ptr riverXkbConfig.RiverXkbKeyboardV1](runtime.pointer)

template xkbKeymapPtr(runtime: XkbKeymapRuntime): ptr riverXkbConfig.RiverXkbKeymapV1 =
  cast[ptr riverXkbConfig.RiverXkbKeymapV1](runtime.pointer)

template riverInputManagerPtr(daemon: TriadDaemon): ptr riverInput.RiverInputManagerV1 =
  cast[ptr riverInput.RiverInputManagerV1](daemon.riverInputManager)

template riverLibinputConfigPtr(
    daemon: TriadDaemon
): ptr riverLibinput.RiverLibinputConfigV1 =
  cast[ptr riverLibinput.RiverLibinputConfigV1](daemon.riverLibinputConfig)

template riverXkbConfigPtr(daemon: TriadDaemon): ptr riverXkbConfig.RiverXkbConfigV1 =
  cast[ptr riverXkbConfig.RiverXkbConfigV1](daemon.riverXkbConfig)

proc xkbConfigured(config: InputXkbConfig): bool =
  config.rulesSet or config.modelSet or config.layoutSet or config.variantSet or
    config.optionsSet

proc cstringOrNil(value: string, set: bool): cstring =
  if set:
    cstring(value)
  else:
    nil

proc buildXkbKeymapText(config: InputXkbConfig): string =
  let context = xkbContextNew(0)
  if context == nil:
    return ""
  try:
    var names = XkbRuleNames(
      rules: config.rules.cstringOrNil(config.rulesSet),
      model: config.model.cstringOrNil(config.modelSet),
      layout: config.layout.cstringOrNil(config.layoutSet),
      variant: config.variant.cstringOrNil(config.variantSet),
      options: config.options.cstringOrNil(config.optionsSet),
    )
    let keymap = xkbKeymapNewFromNames(context, addr names, 0)
    if keymap == nil:
      return ""
    try:
      let raw = xkbKeymapGetAsString(keymap, cint(XkbKeymapFormatTextV1))
      if raw == nil:
        return ""
      try:
        result = $raw
      finally:
        cFree(raw)
    finally:
      xkbKeymapUnref(keymap)
  finally:
    xkbContextUnref(context)

proc writeKeymapFd(text: string): int32 =
  let path = getTempDir() / ("triad-xkb-keymap-" & $getCurrentProcessId())
  try:
    writeFile(path, text & "\0")
    result = posix.open(path.cstring, posix.O_RDONLY)
  except CatchableError as e:
    warn "Unable to write XKB keymap fd", path = path, error = e.msg
    result = -1
  finally:
    try:
      if fileExists(path):
        removeFile(path)
    except CatchableError:
      discard

proc accelProfileValue(profile: InputAccelProfile): uint32 =
  case profile
  of InputAccelProfile.AccelNone: LibinputAccelNone
  of InputAccelProfile.AccelFlat: LibinputAccelFlat
  of InputAccelProfile.AccelAdaptive: LibinputAccelAdaptive

proc scrollMethodValue(scrollMethod: InputScrollMethod): uint32 =
  case scrollMethod
  of InputScrollMethod.ScrollNone: LibinputScrollNone
  of InputScrollMethod.ScrollTwoFinger: LibinputScrollTwoFinger
  of InputScrollMethod.ScrollEdge: LibinputScrollEdge
  of InputScrollMethod.ScrollOnButtonDown: LibinputScrollOnButtonDown

proc clickMethodValue(clickMethod: InputClickMethod): uint32 =
  case clickMethod
  of InputClickMethod.ClickButtonAreas: LibinputClickButtonAreas
  of InputClickMethod.ClickFinger: LibinputClickFinger

proc buttonMapValue(map: InputButtonMap): uint32 =
  case map
  of InputButtonMap.ButtonMapLeftRightMiddle: LibinputButtonMapLrm
  of InputButtonMap.ButtonMapLeftMiddleRight: LibinputButtonMapLmr

proc boolState(enabled: bool): uint32 =
  if enabled: LibinputBoolEnabled else: LibinputBoolDisabled

proc fixedFromFloat(value: float32): Fixed =
  Fixed(int32(cdouble(value) * 256.0))

proc inputDeviceName(daemon: TriadDaemon, inputDeviceId: uint32): string =
  if daemon.inputDevices.hasKey(inputDeviceId):
    daemon.inputDevices[inputDeviceId].name
  else:
    ""

proc inputDeviceType(daemon: TriadDaemon, inputDeviceId: uint32): uint32 =
  if daemon.inputDevices.hasKey(inputDeviceId):
    daemon.inputDevices[inputDeviceId].deviceType
  else:
    high(uint32)

proc pointerConfigFor(
    config: InputConfig, class: PointerDeviceClass
): InputPointerConfig =
  case class
  of PointerDeviceClass.Mouse: config.mouse
  of PointerDeviceClass.Touchpad: config.touchpad.pointer
  of PointerDeviceClass.Trackpoint: config.trackpoint
  of PointerDeviceClass.Trackball: config.trackball

proc addResultListener(
  daemon: var TriadDaemon,
  result: ptr riverLibinput.RiverLibinputResultV1,
  description: string,
)

proc applyPointerCommon(
    daemon: var TriadDaemon,
    libinputId: uint32,
    runtime: LibinputDeviceRuntime,
    pointerConfig: InputPointerConfig,
) =
  let device = runtime.libinputDevicePtr()
  if device == nil:
    return

  if pointerConfig.offSet and
      (runtime.sendEventsSupport and LibinputSendEventsDisabled) != 0:
    let mode =
      if pointerConfig.off: LibinputSendEventsDisabled else: LibinputSendEventsEnabled
    daemon.addResultListener(device.setSendEvents(mode), "input send-events")
  if pointerConfig.naturalScrollSet and runtime.naturalScrollSupport:
    daemon.addResultListener(
      device.setNaturalScroll(pointerConfig.naturalScroll.boolState()),
      "input natural-scroll",
    )
  if pointerConfig.leftHandedSet and runtime.leftHandedSupport:
    daemon.addResultListener(
      device.setLeftHanded(pointerConfig.leftHanded.boolState()), "input left-handed"
    )
  if pointerConfig.middleEmulationSet and runtime.middleEmulationSupport:
    daemon.addResultListener(
      device.setMiddleEmulation(pointerConfig.middleEmulation.boolState()),
      "input middle-emulation",
    )
  if pointerConfig.accelProfileSet:
    let profile = pointerConfig.accelProfile.accelProfileValue()
    if (runtime.accelProfilesSupport and profile) != 0 or profile == LibinputAccelNone:
      daemon.addResultListener(device.setAccelProfile(profile), "input accel-profile")
  if pointerConfig.accelSpeedSet:
    var array: Array
    array.init()
    try:
      let speed = array.add(cdouble)
      speed[] = cdouble(pointerConfig.accelSpeed)
      daemon.addResultListener(device.setAccelSpeed(addr array), "input accel-speed")
    finally:
      array.release()
  if pointerConfig.scrollMethodSet:
    let scrollMethod = pointerConfig.scrollMethod.scrollMethodValue()
    if (runtime.scrollMethodsSupport and scrollMethod) != 0 or
        scrollMethod == LibinputScrollNone:
      daemon.addResultListener(
        device.setScrollMethod(scrollMethod), "input scroll-method"
      )
  if pointerConfig.scrollButtonSet:
    daemon.addResultListener(
      device.setScrollButton(pointerConfig.scrollButton), "input scroll-button"
    )
  if pointerConfig.scrollButtonLockSet:
    daemon.addResultListener(
      device.setScrollButtonLock(pointerConfig.scrollButtonLock.boolState()),
      "input scroll-button-lock",
    )
  if pointerConfig.scrollFactorSet and daemon.inputDevices.hasKey(runtime.inputDeviceId):
    daemon.inputDevices[runtime.inputDeviceId].inputDevicePtr().setScrollFactor(
      pointerConfig.scrollFactor.fixedFromFloat()
    )

proc applyTouchpadExtras(
    daemon: var TriadDaemon, runtime: LibinputDeviceRuntime, config: InputTouchpadConfig
) =
  let device = runtime.libinputDevicePtr()
  if device == nil:
    return
  if config.disabledOnExternalMouseSet and
      (runtime.sendEventsSupport and LibinputSendEventsDisabledOnExternalMouse) != 0:
    let mode =
      if config.disabledOnExternalMouse:
        LibinputSendEventsDisabledOnExternalMouse
      else:
        LibinputSendEventsEnabled
    daemon.addResultListener(
      device.setSendEvents(mode), "input disabled-on-external-mouse"
    )
  if config.tapSet and runtime.tapFingerCount > 0:
    daemon.addResultListener(device.setTap(config.tap.boolState()), "input tap")
  if config.tapButtonMapSet and runtime.tapFingerCount > 0:
    daemon.addResultListener(
      device.setTapButtonMap(config.tapButtonMap.buttonMapValue()),
      "input tap-button-map",
    )
  if config.dragSet and runtime.tapFingerCount > 0:
    daemon.addResultListener(device.setDrag(config.drag.boolState()), "input drag")
  if config.dragLockSet and runtime.tapFingerCount > 0:
    daemon.addResultListener(
      device.setDragLock(
        if config.dragLock: LibinputDragLockEnabledTimeout else: LibinputDragLockDisabled
      ),
      "input drag-lock",
    )
  if config.dwtSet and runtime.dwtSupport:
    daemon.addResultListener(device.setDwt(config.dwt.boolState()), "input dwt")
  if config.dwtpSet and runtime.dwtpSupport:
    daemon.addResultListener(device.setDwtp(config.dwtp.boolState()), "input dwtp")
  if config.clickMethodSet:
    let clickMethod = config.clickMethod.clickMethodValue()
    if (runtime.clickMethodsSupport and clickMethod) != 0:
      daemon.addResultListener(device.setClickMethod(clickMethod), "input click-method")

proc applyLibinputDevice*(daemon: var TriadDaemon, libinputId: uint32) =
  if not daemon.libinputDevices.hasKey(libinputId):
    return
  let runtime = daemon.libinputDevices[libinputId]
  if runtime.pointer == nil:
    return
  if daemon.inputDeviceType(runtime.inputDeviceId) != RiverInputTypePointer:
    return
  let class = daemon.inputDeviceName(runtime.inputDeviceId).pointerClassFor(
      runtime.tapFingerCount, runtime.dwtSupport, runtime.dwtpSupport
    )
  let pointerConfig = daemon.currentModel.input.pointerConfigFor(class)
  daemon.applyPointerCommon(libinputId, runtime, pointerConfig)
  if class == PointerDeviceClass.Touchpad:
    daemon.applyTouchpadExtras(runtime, daemon.currentModel.input.touchpad)

proc applyInputDevice*(daemon: var TriadDaemon, inputDeviceId: uint32) =
  if not daemon.inputDevices.hasKey(inputDeviceId):
    return
  let runtime = daemon.inputDevices[inputDeviceId]
  if runtime.pointer == nil:
    return
  if runtime.deviceType == RiverInputTypeKeyboard:
    let keyboard = daemon.currentModel.input.keyboard
    if keyboard.repeatRateSet or keyboard.repeatDelaySet:
      runtime.inputDevicePtr().setRepeatInfo(
        if keyboard.repeatRateSet: keyboard.repeatRate else: 25'i32,
        if keyboard.repeatDelaySet: keyboard.repeatDelay else: 600'i32,
      )
  elif runtime.deviceType == RiverInputTypePointer:
    for libinputId, libinputRuntime in daemon.libinputDevices.pairs:
      if libinputRuntime.inputDeviceId == inputDeviceId:
        daemon.applyLibinputDevice(libinputId)

proc applyXkbKeyboard(daemon: var TriadDaemon, keyboardId: uint32) =
  if not daemon.xkbConfigKeyboards.hasKey(keyboardId):
    return
  let keyboard = daemon.xkbConfigKeyboards[keyboardId].xkbKeyboardPtr()
  if keyboard == nil:
    return
  if daemon.xkbConfigKeymap.pointer != nil and daemon.xkbConfigKeymap.successful:
    keyboard.setKeymap(daemon.xkbConfigKeymap.xkbKeymapPtr())
  let config = daemon.currentModel.input.keyboard
  if config.numlockSet:
    if config.numlock:
      keyboard.numlockEnable()
    else:
      keyboard.numlockDisable()
  if config.capslockSet:
    if config.capslock:
      keyboard.capslockEnable()
    else:
      keyboard.capslockDisable()

proc applyAllInputConfig*(daemon: var TriadDaemon, reason: string) =
  debug "Applying input config", reason = reason
  for inputDeviceId in daemon.inputDevices.keys:
    daemon.applyInputDevice(inputDeviceId)
  for keyboardId in daemon.xkbConfigKeyboards.keys:
    daemon.applyXkbKeyboard(keyboardId)
  for libinputId in daemon.libinputDevices.keys:
    daemon.applyLibinputDevice(libinputId)

proc resetXkbKeymap(daemon: var TriadDaemon) =
  if daemon.xkbConfigKeymap.pointer != nil:
    daemon.xkbConfigKeymap.xkbKeymapPtr().destroy()
  if daemon.xkbConfigKeymap.fd >= 0:
    discard posix.close(daemon.xkbConfigKeymap.fd)
  daemon.xkbConfigKeymap = XkbKeymapRuntime(fd: -1)

proc configureXkbKeymap*(daemon: var TriadDaemon, reason: string) =
  daemon.resetXkbKeymap()
  if daemon.riverXkbConfig == nil:
    return
  let config = daemon.currentModel.input.keyboard.xkb
  if not config.xkbConfigured():
    return
  let text = config.buildXkbKeymapText()
  if text.len == 0:
    warn "Unable to build XKB keymap from input config", reason = reason
    return
  let fd = text.writeKeymapFd()
  if fd < 0:
    return
  let keymap = daemon.riverXkbConfigPtr().createKeymap(fd, XkbKeymapFormatTextV1)
  daemon.xkbConfigKeymap = XkbKeymapRuntime(pointer: cast[pointer](keymap), fd: fd)
  discard keymap.addListener(xkbKeymapListener.addr, daemonData(daemon))

proc applyInputConfigReloadHook(data: pointer, reason: string) =
  let daemon = cast[ptr TriadDaemon](data)
  if daemon == nil:
    return
  daemon[].configureXkbKeymap(reason)
  daemon[].applyAllInputConfig(reason)

proc installInputRuntimeHooks*(daemon: var TriadDaemon) =
  daemon.inputConfigReloadHook = applyInputConfigReloadHook

proc onInputManagerFinished(
    data: pointer, manager: ptr riverInput.RiverInputManagerV1
) =
  let daemon = callbackDaemon(data, "input manager finished")
  if daemon == nil:
    return
  manager.destroy()
  daemon.riverInputManager = nil

proc onInputDevice(
    data: pointer,
    manager: ptr riverInput.RiverInputManagerV1,
    device: ptr riverInput.RiverInputDeviceV1,
) =
  let daemon = callbackDaemon(data, "input device")
  if daemon == nil:
    return
  daemon.inputDevices[device.id()] = InputDeviceRuntime(pointer: cast[pointer](device))
  discard device.addListener(inputDeviceListener.addr, daemonData(daemon[]))

var inputManagerListener* = riverInput.RiverInputManagerV1Listener(
  finished: onInputManagerFinished, inputDevice: onInputDevice
)

proc onInputDeviceRemoved(data: pointer, device: ptr riverInput.RiverInputDeviceV1) =
  let daemon = callbackDaemon(data, "input device removed")
  if daemon == nil:
    return
  let id = device.id()
  daemon.inputDevices.del(id)
  device.destroy()

proc onInputDeviceType(
    data: pointer, device: ptr riverInput.RiverInputDeviceV1, deviceType: uint32
) =
  let daemon = callbackDaemon(data, "input device type")
  if daemon == nil:
    return
  var runtime = daemon.inputDevices.getOrDefault(device.id())
  runtime.pointer = cast[pointer](device)
  runtime.deviceType = deviceType
  daemon.inputDevices[device.id()] = runtime

proc onInputDeviceName(
    data: pointer, device: ptr riverInput.RiverInputDeviceV1, name: cstring
) =
  let daemon = callbackDaemon(data, "input device name")
  if daemon == nil:
    return
  var runtime = daemon.inputDevices.getOrDefault(device.id())
  runtime.pointer = cast[pointer](device)
  runtime.name = $name
  daemon.inputDevices[device.id()] = runtime

proc onInputDeviceDone(data: pointer, device: ptr riverInput.RiverInputDeviceV1) =
  let daemon = callbackDaemon(data, "input device done")
  if daemon == nil:
    return
  daemon[].applyInputDevice(device.id())

inputDeviceListener = riverInput.RiverInputDeviceV1Listener(
  removed: onInputDeviceRemoved,
  `type`: onInputDeviceType,
  name: onInputDeviceName,
  done: onInputDeviceDone,
)

proc onXkbConfigFinished(data: pointer, config: ptr riverXkbConfig.RiverXkbConfigV1) =
  let daemon = callbackDaemon(data, "xkb config finished")
  if daemon == nil:
    return
  config.destroy()
  daemon.riverXkbConfig = nil

proc onXkbKeyboard(
    data: pointer,
    config: ptr riverXkbConfig.RiverXkbConfigV1,
    keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1,
) =
  let daemon = callbackDaemon(data, "xkb keyboard")
  if daemon == nil:
    return
  daemon.xkbConfigKeyboards[keyboard.id()] =
    XkbKeyboardRuntime(pointer: cast[pointer](keyboard))
  discard keyboard.addListener(xkbKeyboardListener.addr, daemonData(daemon[]))

var xkbConfigListener* = riverXkbConfig.RiverXkbConfigV1Listener(
  finished: onXkbConfigFinished, xkbKeyboard: onXkbKeyboard
)

proc onXkbKeymapSuccess(data: pointer, keymap: ptr riverXkbConfig.RiverXkbKeymapV1) =
  let daemon = callbackDaemon(data, "xkb keymap success")
  if daemon == nil:
    return
  daemon.xkbConfigKeymap.successful = true
  for keyboardId in daemon.xkbConfigKeyboards.keys:
    daemon[].applyXkbKeyboard(keyboardId)

proc onXkbKeymapFailure(
    data: pointer, keymap: ptr riverXkbConfig.RiverXkbKeymapV1, errorMsg: cstring
) =
  let daemon = callbackDaemon(data, "xkb keymap failure")
  if daemon == nil:
    return
  warn "River rejected XKB keymap", error = $errorMsg
  daemon[].resetXkbKeymap()

xkbKeymapListener = riverXkbConfig.RiverXkbKeymapV1Listener(
  success: onXkbKeymapSuccess, failure: onXkbKeymapFailure
)

proc onXkbKeyboardRemoved(
    data: pointer, keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1
) =
  let daemon = callbackDaemon(data, "xkb keyboard removed")
  if daemon == nil:
    return
  daemon.xkbConfigKeyboards.del(keyboard.id())
  keyboard.destroy()

proc onXkbKeyboardInputDevice(
    data: pointer,
    keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1,
    device: ptr riverInput.RiverInputDeviceV1,
) =
  let daemon = callbackDaemon(data, "xkb keyboard input device")
  if daemon == nil:
    return
  var runtime = daemon.xkbConfigKeyboards.getOrDefault(keyboard.id())
  runtime.pointer = cast[pointer](keyboard)
  runtime.inputDeviceId = device.id()
  daemon.xkbConfigKeyboards[keyboard.id()] = runtime

proc onXkbKeyboardLayout(
    data: pointer,
    keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1,
    index: uint32,
    name: cstring,
) =
  discard

proc onXkbKeyboardLock(data: pointer, keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1) =
  discard

proc onXkbKeyboardDone(data: pointer, keyboard: ptr riverXkbConfig.RiverXkbKeyboardV1) =
  let daemon = callbackDaemon(data, "xkb keyboard done")
  if daemon == nil:
    return
  daemon[].applyXkbKeyboard(keyboard.id())

xkbKeyboardListener = riverXkbConfig.RiverXkbKeyboardV1Listener(
  removed: onXkbKeyboardRemoved,
  inputDevice: onXkbKeyboardInputDevice,
  layout: onXkbKeyboardLayout,
  capslockEnabled: onXkbKeyboardLock,
  capslockDisabled: onXkbKeyboardLock,
  numlockEnabled: onXkbKeyboardLock,
  numlockDisabled: onXkbKeyboardLock,
  done: onXkbKeyboardDone,
)

proc onLibinputConfigFinished(
    data: pointer, config: ptr riverLibinput.RiverLibinputConfigV1
) =
  let daemon = callbackDaemon(data, "libinput config finished")
  if daemon == nil:
    return
  config.destroy()
  daemon.riverLibinputConfig = nil

proc onLibinputDevice(
    data: pointer,
    config: ptr riverLibinput.RiverLibinputConfigV1,
    device: ptr riverLibinput.RiverLibinputDeviceV1,
) =
  let daemon = callbackDaemon(data, "libinput device")
  if daemon == nil:
    return
  daemon.libinputDevices[device.id()] =
    LibinputDeviceRuntime(pointer: cast[pointer](device))
  discard device.addListener(libinputDeviceListener.addr, daemonData(daemon[]))

var libinputConfigListener* = riverLibinput.RiverLibinputConfigV1Listener(
  finished: onLibinputConfigFinished, libinputDevice: onLibinputDevice
)

proc onLibinputRemoved(data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1) =
  let daemon = callbackDaemon(data, "libinput device removed")
  if daemon == nil:
    return
  daemon.libinputDevices.del(device.id())
  device.destroy()

proc onLibinputInputDevice(
    data: pointer,
    device: ptr riverLibinput.RiverLibinputDeviceV1,
    inputDevice: ptr riverInput.RiverInputDeviceV1,
) =
  let daemon = callbackDaemon(data, "libinput input device")
  if daemon == nil:
    return
  var runtime = daemon.libinputDevices.getOrDefault(device.id())
  runtime.pointer = cast[pointer](device)
  runtime.inputDeviceId = inputDevice.id()
  daemon.libinputDevices[device.id()] = runtime

proc setLibinputRuntime(
    daemon: ptr TriadDaemon,
    device: ptr riverLibinput.RiverLibinputDeviceV1,
    update: proc(runtime: var LibinputDeviceRuntime),
) =
  if daemon == nil:
    return
  var runtime = daemon.libinputDevices.getOrDefault(device.id())
  runtime.pointer = cast[pointer](device)
  update(runtime)
  daemon.libinputDevices[device.id()] = runtime

proc onLibinputSendEventsSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, modes: uint32
) =
  callbackDaemon(data, "libinput send-events support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.sendEventsSupport = modes,
  )

proc onLibinputTapSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, fingerCount: int32
) =
  callbackDaemon(data, "libinput tap support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.tapFingerCount = fingerCount,
  )

proc onLibinputAccelSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, profiles: uint32
) =
  callbackDaemon(data, "libinput accel support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.accelProfilesSupport = profiles,
  )

proc onLibinputNaturalScrollSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, supported: int32
) =
  callbackDaemon(data, "libinput natural-scroll support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.naturalScrollSupport = supported != 0,
  )

proc onLibinputLeftHandedSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, supported: int32
) =
  callbackDaemon(data, "libinput left-handed support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.leftHandedSupport = supported != 0,
  )

proc onLibinputClickSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, methods: uint32
) =
  callbackDaemon(data, "libinput click support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.clickMethodsSupport = methods,
  )

proc onLibinputMiddleSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, supported: int32
) =
  callbackDaemon(data, "libinput middle-emulation support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.middleEmulationSupport = supported != 0,
  )

proc onLibinputScrollSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, methods: uint32
) =
  callbackDaemon(data, "libinput scroll support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.scrollMethodsSupport = methods,
  )

proc onLibinputDwtSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, supported: int32
) =
  callbackDaemon(data, "libinput dwt support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.dwtSupport = supported != 0,
  )

proc onLibinputDwtpSupport(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, supported: int32
) =
  callbackDaemon(data, "libinput dwtp support").setLibinputRuntime(
    device,
    proc(runtime: var LibinputDeviceRuntime) =
      runtime.dwtpSupport = supported != 0,
  )

proc onLibinputDone(data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1) =
  let daemon = callbackDaemon(data, "libinput done")
  if daemon == nil:
    return
  daemon[].applyLibinputDevice(device.id())

proc ignoreLibinputUint(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, value: uint32
) =
  discard

proc ignoreLibinputInt(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, value: int32
) =
  discard

proc ignoreLibinputArray(
    data: pointer, device: ptr riverLibinput.RiverLibinputDeviceV1, value: ptr Array
) =
  discard

libinputDeviceListener = riverLibinput.RiverLibinputDeviceV1Listener(
  removed: onLibinputRemoved,
  inputDevice: onLibinputInputDevice,
  sendEventsSupport: onLibinputSendEventsSupport,
  sendEventsDefault: ignoreLibinputUint,
  sendEventsCurrent: ignoreLibinputUint,
  tapSupport: onLibinputTapSupport,
  tapDefault: ignoreLibinputUint,
  tapCurrent: ignoreLibinputUint,
  tapButtonMapDefault: ignoreLibinputUint,
  tapButtonMapCurrent: ignoreLibinputUint,
  dragDefault: ignoreLibinputUint,
  dragCurrent: ignoreLibinputUint,
  dragLockDefault: ignoreLibinputUint,
  dragLockCurrent: ignoreLibinputUint,
  threeFingerDragSupport: ignoreLibinputInt,
  threeFingerDragDefault: ignoreLibinputUint,
  threeFingerDragCurrent: ignoreLibinputUint,
  calibrationMatrixSupport: ignoreLibinputInt,
  calibrationMatrixDefault: ignoreLibinputArray,
  calibrationMatrixCurrent: ignoreLibinputArray,
  accelProfilesSupport: onLibinputAccelSupport,
  accelProfileDefault: ignoreLibinputUint,
  accelProfileCurrent: ignoreLibinputUint,
  accelSpeedDefault: ignoreLibinputArray,
  accelSpeedCurrent: ignoreLibinputArray,
  naturalScrollSupport: onLibinputNaturalScrollSupport,
  naturalScrollDefault: ignoreLibinputUint,
  naturalScrollCurrent: ignoreLibinputUint,
  leftHandedSupport: onLibinputLeftHandedSupport,
  leftHandedDefault: ignoreLibinputUint,
  leftHandedCurrent: ignoreLibinputUint,
  clickMethodSupport: onLibinputClickSupport,
  clickMethodDefault: ignoreLibinputUint,
  clickMethodCurrent: ignoreLibinputUint,
  clickfingerButtonMapDefault: ignoreLibinputUint,
  clickfingerButtonMapCurrent: ignoreLibinputUint,
  middleEmulationSupport: onLibinputMiddleSupport,
  middleEmulationDefault: ignoreLibinputUint,
  middleEmulationCurrent: ignoreLibinputUint,
  scrollMethodSupport: onLibinputScrollSupport,
  scrollMethodDefault: ignoreLibinputUint,
  scrollMethodCurrent: ignoreLibinputUint,
  scrollButtonDefault: ignoreLibinputUint,
  scrollButtonCurrent: ignoreLibinputUint,
  scrollButtonLockDefault: ignoreLibinputUint,
  scrollButtonLockCurrent: ignoreLibinputUint,
  dwtSupport: onLibinputDwtSupport,
  dwtDefault: ignoreLibinputUint,
  dwtCurrent: ignoreLibinputUint,
  dwtpSupport: onLibinputDwtpSupport,
  dwtpDefault: ignoreLibinputUint,
  dwtpCurrent: ignoreLibinputUint,
  rotationSupport: ignoreLibinputInt,
  rotationDefault: ignoreLibinputUint,
  rotationCurrent: ignoreLibinputUint,
  done: onLibinputDone,
)

proc onLibinputResultSuccess(
    data: pointer, result: ptr riverLibinput.RiverLibinputResultV1
) =
  let daemon = callbackDaemon(data, "libinput result success")
  if daemon == nil:
    return
  daemon.libinputResultDescriptions.del(result.id())

proc onLibinputResultUnsupported(
    data: pointer, result: ptr riverLibinput.RiverLibinputResultV1
) =
  let daemon = callbackDaemon(data, "libinput result unsupported")
  if daemon == nil:
    return
  warn "Libinput setting unsupported",
    setting = daemon.libinputResultDescriptions.getOrDefault(result.id(), "")
  daemon.libinputResultDescriptions.del(result.id())

proc onLibinputResultInvalid(
    data: pointer, result: ptr riverLibinput.RiverLibinputResultV1
) =
  let daemon = callbackDaemon(data, "libinput result invalid")
  if daemon == nil:
    return
  warn "Libinput setting invalid",
    setting = daemon.libinputResultDescriptions.getOrDefault(result.id(), "")
  daemon.libinputResultDescriptions.del(result.id())

libinputResultListener = riverLibinput.RiverLibinputResultV1Listener(
  success: onLibinputResultSuccess,
  unsupported: onLibinputResultUnsupported,
  invalid: onLibinputResultInvalid,
)

proc addResultListener(
    daemon: var TriadDaemon,
    result: ptr riverLibinput.RiverLibinputResultV1,
    description: string,
) =
  if result == nil:
    return
  daemon.libinputResultDescriptions[result.id()] = description
  discard result.addListener(libinputResultListener.addr, daemonData(daemon))

proc destroyInputRuntime*(daemon: var TriadDaemon) =
  for runtime in daemon.libinputDevices.values:
    if runtime.pointer != nil:
      runtime.libinputDevicePtr().destroy()
  daemon.libinputDevices.clear()
  for runtime in daemon.xkbConfigKeyboards.values:
    if runtime.pointer != nil:
      runtime.xkbKeyboardPtr().destroy()
  daemon.xkbConfigKeyboards.clear()
  daemon.resetXkbKeymap()
  for runtime in daemon.inputDevices.values:
    if runtime.pointer != nil:
      runtime.inputDevicePtr().destroy()
  daemon.inputDevices.clear()
  daemon.libinputResultDescriptions.clear()
  if daemon.riverLibinputConfig != nil:
    daemon.riverLibinputConfigPtr().stop()
    daemon.riverLibinputConfig = nil
  if daemon.riverXkbConfig != nil:
    daemon.riverXkbConfigPtr().stop()
    daemon.riverXkbConfig = nil
  if daemon.riverInputManager != nil:
    daemon.riverInputManagerPtr().stop()
    daemon.riverInputManager = nil
