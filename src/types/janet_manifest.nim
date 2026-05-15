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
