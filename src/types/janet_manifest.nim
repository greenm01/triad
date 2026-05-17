import std/options
import runtime_messages, shell_snapshot

type
  ManifestOutcome* {.pure.} = enum
    Disabled
    InvalidAppId
    Missing
    ReadFailed
    CachedFailed
    EvalFailed
    Evaluated

  ManifestEvalResult* = object
    appId*: string
    candidatePaths*: seq[string]
    path*: string
    outcome*: ManifestOutcome
    currentWindow*: Option[ShellWindow]
    messages*: seq[Msg]
    error*: string

  HookOutcome* {.pure.} = enum
    Disabled
    Missing
    ReadFailed
    CachedFailed
    EvalFailed
    Evaluated

  HookEvalResult* = object
    event*: string
    path*: string
    outcome*: HookOutcome
    currentWindow*: Option[ShellWindow]
    messages*: seq[Msg]
    error*: string
    durationMs*: int64
