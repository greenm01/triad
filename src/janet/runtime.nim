import std/[algorithm, options, os, strutils, tables, times]
import chronicles
import ../core/msg
import ../types/[janet_manifest, runtime_values, shell_snapshot]
import command_api, snapshot_api, binding, prelude

type
  ScriptCacheEntry* = object
    path*: string
    modified*: Time
    source*: string
    failed*: bool
    error*: string

  JanetRuntime* = object
    handle*: JanetHandle
    config*: JanetConfig
    scripts*: Table[string, ScriptCacheEntry]

proc initJanetRuntime*(config: JanetConfig): JanetRuntime =
  result.config = config
  result.scripts = initTable[string, ScriptCacheEntry]()
  if config.enabled:
    result.handle = triadJanetNew()

proc close*(runtime: var JanetRuntime) =
  if runtime.handle != nil:
    triadJanetFree(runtime.handle)
    runtime.handle = nil
  runtime.scripts.clear()

proc configure*(runtime: var JanetRuntime, config: JanetConfig) =
  let wasEnabled = runtime.handle != nil
  if wasEnabled and not config.enabled:
    runtime.close()
    runtime.config = config
    return
  runtime.config = config
  runtime.scripts.clear()
  if config.enabled and runtime.handle == nil:
    runtime.handle = triadJanetNew()

proc evalSource*(
    runtime: var JanetRuntime,
    snapshot: ShellSnapshot,
    source: string,
    path = "<janet>",
    currentWindow = none(ShellWindow),
    currentEvent = "nil",
): tuple[ok: bool, messages: seq[Msg], error: string] =
  if runtime.handle == nil:
    return (true, @[], "")

  let snapshotSource =
    snapshot.janetSnapshotSource(currentWindow, currentEvent) & JanetPreludeSource
  let ok =
    triadJanetEval(
      runtime.handle,
      cstring(snapshotSource),
      cstring(source),
      cstring(path),
      runtime.config.fuelLimit,
    ) == 1
  if not ok:
    return (false, @[], $triadJanetLastError(runtime.handle))

  for index in 0 ..< int(triadJanetActionCount(runtime.handle)):
    let msg = runtime.handle.actionMsg(index)
    if msg.isSome:
      result.messages.add(msg.get())
  result.ok = true

proc expandJanetDir(path: string): string =
  let stripped = path.strip()
  if stripped == "~":
    getHomeDir()
  elif stripped.startsWith("~/"):
    getHomeDir() / stripped[2 ..^ 1]
  else:
    stripped

proc scriptPaths(runtime: JanetRuntime): seq[string] =
  let expanded = runtime.config.scriptDir.expandJanetDir()
  if expanded.len == 0 or not dirExists(expanded):
    return @[]
  for path in walkFiles(expanded / "*.janet"):
    result.add(path)
  result.sort()

proc scriptEntry(runtime: var JanetRuntime, path: string): ScriptCacheEntry =
  let modified = getLastModificationTime(path)
  if runtime.scripts.hasKey(path):
    let cached = runtime.scripts[path]
    if cached.modified == modified:
      return cached

  result = ScriptCacheEntry(path: path, modified: modified)
  try:
    result.source = readFile(path)
  except CatchableError as e:
    result.failed = true
    result.error = e.msg
    warn "Failed to read Janet script", path = path, error = e.msg
  runtime.scripts[path] = result

proc evalScriptsDetailed*(
    runtime: var JanetRuntime,
    event: string,
    eventSource: string,
    snapshot: ShellSnapshot,
    currentWindow = none(ShellWindow),
): seq[ScriptEvalResult] =
  if runtime.handle == nil:
    return @[]

  for path in runtime.scriptPaths():
    let started = epochTime()
    let entry = runtime.scriptEntry(path)
    var evalResult =
      ScriptEvalResult(event: event, path: path, currentWindow: currentWindow)
    if entry.failed:
      evalResult.outcome =
        if entry.source.len == 0:
          ScriptOutcome.ReadFailed
        else:
          ScriptOutcome.CachedFailed
      evalResult.error = entry.error
    else:
      let evaluated = runtime.evalSource(
        snapshot, entry.source, entry.path, currentWindow, eventSource
      )
      if evaluated.ok:
        evalResult.outcome = ScriptOutcome.Evaluated
        evalResult.messages = evaluated.messages
      else:
        warn "Janet script failed",
          event = event, path = entry.path, error = evaluated.error
        var failedEntry = entry
        failedEntry.failed = true
        failedEntry.error = evaluated.error
        runtime.scripts[failedEntry.path] = failedEntry
        evalResult.outcome = ScriptOutcome.EvalFailed
        evalResult.error = evaluated.error
    evalResult.durationMs = int64((epochTime() - started) * 1000)
    result.add(evalResult)
