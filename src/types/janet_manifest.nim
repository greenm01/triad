import std/options
import runtime_messages, shell_snapshot

type
  ScriptOutcome* {.pure.} = enum
    Disabled
    Missing
    ReadFailed
    CachedFailed
    EvalFailed
    Evaluated

  ScriptEvalResult* = object
    event*: string
    path*: string
    outcome*: ScriptOutcome
    currentWindow*: Option[ShellWindow]
    messages*: seq[Msg]
    error*: string
    durationMs*: int64
