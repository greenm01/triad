import ../types/runtime_values

const
  DefaultCursorSize* = 24'u32
  CursorShakeMaxSize* = 512'u32
  CursorShakeMinDelta = 16'i32
  CursorShakeMaxGapMs = 180'i64
  CursorShakeWindowMs = 650'i64
  CursorShakeRestoreDelayMs* = 700'i64
  CursorShakeTriggerReversals = 3

type
  CursorShakeAction* {.pure.} = enum
    None
    Enlarge
    Restore

  CursorShakeState* = object
    hasLast*: bool
    lastX*: int32
    lastY*: int32
    lastMotionMs*: int64
    shakeStartMs*: int64
    axis*: int
    sign*: int
    reversals*: int
    enlarged*: bool
    restoreDueMs*: int64
    restoreTheme*: string
    restoreSize*: uint32

proc cursorBaseSize*(config: CursorConfig): uint32 =
  if config.size == 0: DefaultCursorSize else: config.size

proc cursorShakeEnabled*(config: CursorConfig): bool =
  config.shakeToFind and config.theme.len > 0

proc cursorHideInactiveEnabled*(config: CursorConfig): bool =
  config.hideAfterInactiveMs > 0

proc cursorShakeSize*(baseSize: uint32): uint32 =
  min(max(baseSize * 2, baseSize + 24), CursorShakeMaxSize)

proc cursorShakeSize*(config: CursorConfig): uint32 =
  config.cursorBaseSize().cursorShakeSize()

proc clearShakeGesture(state: var CursorShakeState) =
  state.shakeStartMs = 0
  state.axis = 0
  state.sign = 0
  state.reversals = 0

proc observeCursorMotion*(
    state: var CursorShakeState, config: CursorConfig, x, y: int32, nowMs: int64
): CursorShakeAction =
  if not config.cursorShakeEnabled():
    if state.enlarged:
      state.enlarged = false
      result = CursorShakeAction.Restore
    state.hasLast = false
    state.clearShakeGesture()
    return result

  if state.enlarged:
    state.restoreDueMs = nowMs + CursorShakeRestoreDelayMs

  if not state.hasLast:
    state.hasLast = true
    state.lastX = x
    state.lastY = y
    state.lastMotionMs = nowMs
    return CursorShakeAction.None

  let dx = x - state.lastX
  let dy = y - state.lastY
  let absDx = abs(dx)
  let absDy = abs(dy)
  if max(absDx, absDy) < CursorShakeMinDelta:
    return CursorShakeAction.None

  let axis = if absDx >= absDy: 1 else: 2
  let sign =
    if axis == 1:
      if dx > 0: 1 else: -1
    else:
      if dy > 0: 1 else: -1
  let gap = nowMs - state.lastMotionMs
  state.lastX = x
  state.lastY = y
  state.lastMotionMs = nowMs

  if gap > CursorShakeMaxGapMs or state.axis == 0 or state.axis != axis:
    state.clearShakeGesture()
    state.axis = axis
    state.sign = sign
    state.shakeStartMs = nowMs
    return CursorShakeAction.None

  if state.sign == sign:
    return CursorShakeAction.None

  if state.shakeStartMs == 0 or nowMs - state.shakeStartMs > CursorShakeWindowMs:
    state.shakeStartMs = nowMs
    state.reversals = 1
  else:
    inc state.reversals
  state.sign = sign

  if state.reversals >= CursorShakeTriggerReversals:
    state.restoreDueMs = nowMs + CursorShakeRestoreDelayMs
    state.restoreTheme = config.theme
    state.restoreSize = config.cursorBaseSize()
    state.clearShakeGesture()
    if not state.enlarged:
      state.enlarged = true
      return CursorShakeAction.Enlarge

  CursorShakeAction.None

proc tickCursorShake*(
    state: var CursorShakeState, config: CursorConfig, nowMs: int64
): CursorShakeAction =
  if not state.enlarged:
    return CursorShakeAction.None
  if not config.cursorShakeEnabled() or nowMs >= state.restoreDueMs:
    state.enlarged = false
    state.clearShakeGesture()
    return CursorShakeAction.Restore
  CursorShakeAction.None
