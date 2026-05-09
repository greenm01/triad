const DefaultConfigReloadDebounceMs* = 200'i64

type
  ConfigReloadDebouncer* = object
    pending*: bool
    deadlineMs*: int64

proc schedule*(debouncer: var ConfigReloadDebouncer; nowMs: int64;
    debounceMs = DefaultConfigReloadDebounceMs) =
  debouncer.pending = true
  debouncer.deadlineMs = nowMs + max(0'i64, debounceMs)

proc takeDue*(debouncer: var ConfigReloadDebouncer; nowMs: int64): bool =
  if debouncer.pending and nowMs >= debouncer.deadlineMs:
    debouncer.pending = false
    return true
  false
