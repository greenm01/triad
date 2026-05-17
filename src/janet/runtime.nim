import std/[algorithm, options, os, sequtils, strutils, tables, times]
import chronicles
import ../core/msg
import ../types/[janet_manifest, runtime_values, shell_snapshot]
import command_api, snapshot_api, binding, prelude

type
  ScriptCacheEntry* = object
    path*: string
    modified*: Time
    source*: string
    script*: JanetScriptHandle
    failed*: bool
    error*: string

  ScriptEntryResult = tuple[entry: ScriptCacheEntry, reloaded: bool]

  JanetRuntime* = object
    handle*: JanetHandle
    config*: JanetConfig
    scripts*: Table[string, ScriptCacheEntry]

proc initJanetRuntime*(config: JanetConfig): JanetRuntime =
  result.config = config
  result.scripts = initTable[string, ScriptCacheEntry]()
  if config.enabled:
    result.handle = triadJanetNew()

proc freeScript(entry: var ScriptCacheEntry) =
  if entry.script != nil:
    triadJanetScriptFree(entry.script)
    entry.script = nil

proc clearScripts(runtime: var JanetRuntime) =
  for path in runtime.scripts.keys.toSeq:
    var entry = runtime.scripts[path]
    entry.freeScript()
  runtime.scripts.clear()

proc close*(runtime: var JanetRuntime) =
  runtime.clearScripts()
  if runtime.handle != nil:
    triadJanetFree(runtime.handle)
    runtime.handle = nil

proc configure*(runtime: var JanetRuntime, config: JanetConfig) =
  let wasEnabled = runtime.handle != nil
  if wasEnabled and not config.enabled:
    runtime.close()
    runtime.config = config
    return
  runtime.config = config
  runtime.clearScripts()
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
    let error = $triadJanetLastError(runtime.handle)
    return (false, @[], if error.len > 0: error else: "Janet evaluation failed")

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

proc loadScriptEntry(
    runtime: var JanetRuntime, path: string, snapshot: ShellSnapshot
): ScriptEntryResult =
  let modified = getLastModificationTime(path)
  if runtime.scripts.hasKey(path):
    let cached = runtime.scripts[path]
    if cached.modified == modified:
      return (cached, false)
    var stale = cached
    stale.freeScript()

  result.entry = ScriptCacheEntry(path: path, modified: modified)
  result.reloaded = true
  try:
    result.entry.source = readFile(path)
  except CatchableError as e:
    result.entry.failed = true
    result.entry.error = e.msg
    warn "Failed to read Janet script", path = path, error = e.msg
    runtime.scripts[path] = result.entry
    return

  let bootstrapSource =
    snapshot.janetSnapshotSource(none(ShellWindow), "nil") & JanetPersistentPreludeSource
  result.entry.script = triadJanetScriptLoad(
    runtime.handle,
    cstring(bootstrapSource),
    cstring(result.entry.source),
    cstring(path),
    runtime.config.fuelLimit,
  )
  if result.entry.script == nil:
    let error = $triadJanetLastError(runtime.handle)
    result.entry.failed = true
    result.entry.error = if error.len > 0: error else: "Janet script load failed"
    warn "Janet script failed", path = path, error = result.entry.error
  runtime.scripts[path] = result.entry

proc evictMissingScripts(runtime: var JanetRuntime, paths: seq[string]) =
  for path in runtime.scripts.keys.toSeq:
    if path notin paths:
      var entry = runtime.scripts[path]
      entry.freeScript()
      runtime.scripts.del(path)

proc evalScriptsDetailed*(
    runtime: var JanetRuntime,
    event: string,
    eventSource: string,
    snapshot: ShellSnapshot,
    currentWindow = none(ShellWindow),
): seq[ScriptEvalResult] =
  if runtime.handle == nil:
    return @[]

  let paths = runtime.scriptPaths()
  runtime.evictMissingScripts(paths)

  for path in paths:
    let started = epochTime()
    let loaded = runtime.loadScriptEntry(path, snapshot)
    let entry = loaded.entry
    var evalResult =
      ScriptEvalResult(event: event, path: path, currentWindow: currentWindow)
    if entry.failed:
      evalResult.outcome =
        if entry.source.len == 0:
          ScriptOutcome.ReadFailed
        elif loaded.reloaded:
          ScriptOutcome.EvalFailed
        else:
          ScriptOutcome.CachedFailed
      evalResult.error = entry.error
    else:
      let eventSnapshotSource = snapshot.janetSnapshotSource(currentWindow, eventSource)
      let evaluated =
        triadJanetScriptDispatch(
          runtime.handle,
          entry.script,
          cstring(event),
          cstring(eventSnapshotSource),
          cstring(entry.path),
          runtime.config.fuelLimit,
        ) == 1
      if evaluated:
        evalResult.outcome = ScriptOutcome.Evaluated
        for index in 0 ..< int(triadJanetActionCount(runtime.handle)):
          let msg = runtime.handle.actionMsg(index)
          if msg.isSome:
            evalResult.messages.add(msg.get())
      else:
        let error = $triadJanetLastError(runtime.handle)
        warn "Janet script failed", event = event, path = entry.path, error = error
        var failedEntry = entry
        failedEntry.freeScript()
        failedEntry.failed = true
        failedEntry.error = if error.len > 0: error else: "Janet event dispatch failed"
        runtime.scripts[failedEntry.path] = failedEntry
        evalResult.outcome = ScriptOutcome.EvalFailed
        evalResult.error = failedEntry.error
    evalResult.durationMs = int64((epochTime() - started) * 1000)
    result.add(evalResult)
