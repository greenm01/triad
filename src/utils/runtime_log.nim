import chronicles, options, os, strutils

export LogLevel

const DefaultLogLevel* = INFO

proc parseLogLevel*(value: string): Option[LogLevel] =
  case value.normalize()
  of "trace", "trc":
    some(TRACE)
  of "debug", "dbg":
    some(DEBUG)
  of "info", "inf":
    some(INFO)
  of "notice", "ntc":
    some(NOTICE)
  of "warn", "warning", "wrn":
    some(WARN)
  of "error", "err":
    some(ERROR)
  of "fatal", "fat":
    some(FATAL)
  else:
    none(LogLevel)

proc logLevelName*(level: LogLevel): string =
  case level
  of TRACE: "trace"
  of DEBUG: "debug"
  of INFO: "info"
  of NOTICE: "notice"
  of WARN: "warn"
  of ERROR: "error"
  of FATAL: "fatal"
  of NONE: "none"

proc configureLogging*() =
  let rawLevel = getEnv("TRIAD_LOG_LEVEL", "")
  if rawLevel.len == 0:
    setLogLevel(DefaultLogLevel)
    info "Logging initialized", level = DefaultLogLevel.logLevelName()
    return

  let parsed = parseLogLevel(rawLevel)
  if parsed.isSome:
    let level = parsed.get()
    setLogLevel(level)
    info "Logging initialized", level = level.logLevelName()
  else:
    setLogLevel(DefaultLogLevel)
    warn "Invalid TRIAD_LOG_LEVEL; using default",
      value = rawLevel, default = DefaultLogLevel.logLevelName()
