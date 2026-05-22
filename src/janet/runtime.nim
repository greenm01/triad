import std/[algorithm, options, os, sequtils, strutils, tables, times]
import chronicles
import ../core/layout_descriptor_codec
import ../core/msg
import ../types/[janet_layouts, janet_manifest, runtime_values, shell_snapshot]
import bundled_layouts, command_api, layout_api, snapshot_api, binding, prelude

type
  ScriptCacheEntry* = object
    path*: string
    modified*: Time
    source*: string
    script*: JanetScriptHandle
    failed*: bool
    error*: string

  ScriptEntryResult = tuple[entry: ScriptCacheEntry, reloaded: bool]

  JanetRuntimeDiagnosticCounts* = object
    enabled*: bool
    handleActive*: bool
    configuredLayouts*: int
    cachedScripts*: int
    cachedFailedScripts*: int
    cachedSourceBytes*: int
    runtimeActionCount*: int
    runtimeActionCapacity*: int
    runtimeLayoutInstructionCount*: int
    runtimeLayoutInstructionCapacity*: int
    runtimeEstimatedCBytes*: int
    scriptHandlerLists*: int
    scriptHandlerListCapacity*: int
    scriptHandlers*: int
    scriptHandlerCapacity*: int
    scriptLayouts*: int
    scriptLayoutCapacity*: int
    scriptLayoutMovements*: int
    scriptLayoutMovementCapacity*: int
    scriptWaiters*: int
    scriptWaiterCapacity*: int
    scriptEstimatedCBytes*: int

  JanetRuntime* = object
    handle*: JanetHandle
    config*: JanetConfig
    scripts*: Table[string, ScriptCacheEntry]

proc initJanetRuntime*(config: JanetConfig): JanetRuntime =
  result.config = config
  result.scripts = initTable[string, ScriptCacheEntry]()
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
  runtime.config = config
  runtime.clearScripts()
  if runtime.handle == nil:
    runtime.handle = triadJanetNew()

proc diagnosticCounts*(runtime: JanetRuntime): JanetRuntimeDiagnosticCounts =
  result.enabled = runtime.config.enabled
  result.handleActive = runtime.handle != nil
  result.configuredLayouts = runtime.config.layouts.len
  result.cachedScripts = runtime.scripts.len
  if runtime.handle != nil:
    result.runtimeActionCount = int(triadJanetActionCount(runtime.handle))
    result.runtimeActionCapacity = int(triadJanetRuntimeActionCapacity(runtime.handle))
    result.runtimeLayoutInstructionCount =
      int(triadJanetLayoutInstructionCount(runtime.handle))
    result.runtimeLayoutInstructionCapacity =
      int(triadJanetRuntimeLayoutInstructionCapacity(runtime.handle))
    result.runtimeEstimatedCBytes =
      int(triadJanetRuntimeEstimatedCBytes(runtime.handle))
  for _, entry in runtime.scripts.pairs:
    if entry.failed:
      inc result.cachedFailedScripts
    result.cachedSourceBytes += entry.source.len
    if entry.script == nil:
      continue
    result.scriptHandlerLists += int(triadJanetScriptHandlerListCount(entry.script))
    result.scriptHandlerListCapacity +=
      int(triadJanetScriptHandlerListCapacity(entry.script))
    result.scriptHandlers += int(triadJanetScriptHandlerCount(entry.script))
    result.scriptHandlerCapacity += int(triadJanetScriptHandlerCapacity(entry.script))
    result.scriptLayouts += int(triadJanetScriptLayoutCount(entry.script))
    result.scriptLayoutCapacity += int(triadJanetScriptLayoutCapacity(entry.script))
    result.scriptLayoutMovements +=
      int(triadJanetScriptLayoutMovementCount(entry.script))
    result.scriptLayoutMovementCapacity +=
      int(triadJanetScriptLayoutMovementCapacity(entry.script))
    result.scriptWaiters += int(triadJanetScriptWaiterCount(entry.script))
    result.scriptWaiterCapacity += int(triadJanetScriptWaiterCapacity(entry.script))
    result.scriptEstimatedCBytes += int(triadJanetScriptEstimatedCBytes(entry.script))

proc evalSource*(
    runtime: var JanetRuntime,
    snapshot: ShellSnapshot,
    source: string,
    path = "<janet>",
    currentWindow = none(ShellWindow),
    currentEvent = "nil",
): tuple[ok: bool, messages: seq[Msg], error: string] =
  if not runtime.config.enabled or runtime.handle == nil:
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
  let expanded = runtime.config.automationDir.expandJanetDir()
  if expanded.len == 0 or not dirExists(expanded):
    return @[]
  for path in walkFiles(expanded / "*.janet"):
    result.add(path)
  result.sort()

proc layoutScriptPath(runtime: JanetRuntime, layoutId: string): string =
  if layoutId.contains("/") or layoutId.contains("\\"):
    return ""
  let expanded = runtime.config.layoutDir.expandJanetDir()
  if expanded.len == 0:
    return ""
  expanded / (layoutId & ".janet")

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

proc loadBundledLayoutEntry(
    runtime: var JanetRuntime, layoutId: string, snapshot: ShellSnapshot
): ScriptEntryResult =
  let path = bundledLayoutPath(layoutId)
  if runtime.scripts.hasKey(path):
    return (runtime.scripts[path], false)

  let source = bundledLayoutSource(layoutId)
  result.entry = ScriptCacheEntry(path: path, modified: Time())
  result.reloaded = true
  if source.isNone:
    result.entry.failed = true
    result.entry.error = "unknown bundled Janet layout: " & layoutId
    runtime.scripts[path] = result.entry
    return
  result.entry.source = source.get()
  let bootstrapSource =
    snapshot.janetSnapshotSource(none(ShellWindow), "nil") & JanetPersistentPreludeSource
  result.entry.script = triadJanetScriptLoad(
    runtime.handle,
    cstring(bootstrapSource),
    cstring(result.entry.source),
    cstring(result.entry.path),
    runtime.config.fuelLimit,
  )
  if result.entry.script == nil:
    let error = $triadJanetLastError(runtime.handle)
    result.entry.failed = true
    result.entry.error =
      if error.len > 0: error else: "Bundled Janet layout load failed"
    warn "Bundled Janet layouts failed", error = result.entry.error
  runtime.scripts[path] = result.entry

proc isBundledLayoutPath(path: string): bool =
  path.startsWith(BundledLayoutsPathPrefix)

proc evictMissingScripts(runtime: var JanetRuntime, paths: seq[string]) =
  for path in runtime.scripts.keys.toSeq:
    if path.isBundledLayoutPath():
      continue
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
  if not runtime.config.enabled or runtime.handle == nil:
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
      if triadJanetScriptInterestedInEvent(entry.script, cstring(event)) != 1:
        evalResult.outcome = ScriptOutcome.Evaluated
        evalResult.durationMs = int64((epochTime() - started) * 1000)
        result.add(evalResult)
        continue
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

proc tiledWindowCount(context: JanetLayoutContext): int =
  for column in context.tag.columns:
    result += column.windows.len

proc leafFrameCount(context: JanetLayoutContext): int =
  for frame in context.tag.frames:
    if frame.kind == FrameNodeKind.Leaf:
      inc result

proc leafBspNodeCount(context: JanetLayoutContext): int =
  for node in context.tag.bspNodes:
    if node.kind == FrameNodeKind.Leaf:
      inc result

proc leafSplitNodeCount(context: JanetLayoutContext): int =
  for node in context.tag.splitNodes:
    if node.kind == FrameNodeKind.Leaf:
      inc result

proc fallbackLayoutResult(
    context: JanetLayoutContext,
    outcome: JanetLayoutOutcome,
    reason: string,
    started: float,
    path = "",
    error = "",
): JanetLayoutEvalResult =
  JanetLayoutEvalResult(
    layoutId: context.layoutId,
    path: path,
    outcome: outcome,
    error: error,
    fallbackReason: reason,
    durationMs: int64((epochTime() - started) * 1000),
    inputWindowCount: context.tiledWindowCount(),
    inputFrameCount: context.leafFrameCount(),
    inputBspNodeCount: context.leafBspNodeCount(),
    inputSplitNodeCount: context.leafSplitNodeCount(),
  )

proc evalLoadedLayout(
    runtime: var JanetRuntime,
    context: JanetLayoutContext,
    entry: ScriptCacheEntry,
    started: float,
    evalFailureReason: string,
): JanetLayoutEvalResult =
  let evaluated =
    triadJanetScriptEvalLayout(
      runtime.handle,
      entry.script,
      cstring(context.layoutId.layoutIdString()),
      cstring(context.layoutContextSource()),
      cstring(entry.path),
      runtime.config.fuelLimit,
    ) == 1
  if not evaluated:
    let error = $triadJanetLastError(runtime.handle)
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.EvalFailed,
      evalFailureReason,
      started,
      entry.path,
      if error.len > 0: error else: evalFailureReason,
    )
    result.logLayoutEval()
    return

  let instructions = runtime.handle.extractedLayoutInstructions()
  let validation = context.validateLayoutInstructions(instructions)
  if not validation.ok:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.Invalid, validation.error, started, entry.path,
      validation.error,
    )
    result.instructionCount = instructions.len
    result.outputTargetKind = validation.outputTargetKind
    result.logLayoutEval()
    return

  result = JanetLayoutEvalResult(
    layoutId: context.layoutId,
    path: entry.path,
    outcome: JanetLayoutOutcome.Applied,
    durationMs: int64((epochTime() - started) * 1000),
    inputWindowCount: context.tiledWindowCount(),
    inputFrameCount: context.leafFrameCount(),
    inputBspNodeCount: context.leafBspNodeCount(),
    inputSplitNodeCount: context.leafSplitNodeCount(),
    instructionCount: instructions.len,
    outputTargetKind: validation.outputTargetKind,
    instructions: validation.instructions,
    frameInstructions:
      if validation.outputTargetKind == JanetLayoutTargetKind.Frame:
        instructions
      else:
        @[],
  )
  result.logLayoutEval()

proc missingMovementResult(
    context: JanetLayoutContext, started: float
): JanetLayoutMovementEvalResult =
  JanetLayoutMovementEvalResult(
    layoutId: context.layoutId,
    handled: false,
    ok: false,
    durationMs: int64((epochTime() - started) * 1000),
  )

proc failedMovementResult(
    context: JanetLayoutContext, started: float, path: string, error: string
): JanetLayoutMovementEvalResult =
  JanetLayoutMovementEvalResult(
    layoutId: context.layoutId,
    path: path,
    handled: true,
    ok: false,
    error: error,
    durationMs: int64((epochTime() - started) * 1000),
  )

proc evalLoadedLayoutMovement(
    runtime: var JanetRuntime,
    context: JanetLayoutContext,
    direction: Direction,
    entry: ScriptCacheEntry,
    started: float,
): JanetLayoutMovementEvalResult =
  let evaluated =
    triadJanetScriptEvalLayoutMovement(
      runtime.handle,
      entry.script,
      cstring(context.layoutId.layoutIdString()),
      cstring(context.layoutContextSource()),
      cstring(direction.directionName()),
      cstring(entry.path),
      runtime.config.fuelLimit,
    ) == 1
  if not evaluated:
    let error = $triadJanetLastError(runtime.handle)
    return context.failedMovementResult(
      started, entry.path, if error.len > 0: error else: "Janet movement eval failed"
    )
  let movement = runtime.handle.extractedLayoutMovement()
  if not movement.ok:
    return context.failedMovementResult(
      started, entry.path, "Janet layout movement returned invalid result"
    )
  JanetLayoutMovementEvalResult(
    layoutId: context.layoutId,
    path: entry.path,
    handled: true,
    ok: true,
    durationMs: int64((epochTime() - started) * 1000),
    op: movement.op,
    delta: movement.delta,
  )

proc evalLayoutDetailed*(
    runtime: var JanetRuntime, snapshot: ShellSnapshot, context: JanetLayoutContext
): JanetLayoutEvalResult =
  let started = epochTime()
  if runtime.handle == nil:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.Disabled, "janet runtime disabled", started
    )
    result.logLayoutEval()
    return

  let layoutId = context.layoutId.layoutIdString()
  if layoutId.isBundledLayoutId():
    let bundled = runtime.loadBundledLayoutEntry(layoutId, snapshot)
    if not bundled.entry.failed and
        triadJanetScriptHasLayout(bundled.entry.script, cstring(layoutId)) == 1:
      return runtime.evalLoadedLayout(
        context, bundled.entry, started, "bundled janet layout evaluation failed"
      )

  if not runtime.config.enabled:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.Disabled, "user janet runtime disabled", started
    )
    result.logLayoutEval()
    return

  let directLayoutPath = runtime.layoutScriptPath(layoutId)
  if directLayoutPath.len > 0 and fileExists(directLayoutPath):
    let loaded = runtime.loadScriptEntry(directLayoutPath, snapshot)
    let entry = loaded.entry
    if entry.failed:
      result = context.fallbackLayoutResult(
        JanetLayoutOutcome.LoadFailed, "janet layout script failed to load", started,
        entry.path, entry.error,
      )
      result.logLayoutEval()
      return
    if triadJanetScriptHasLayout(entry.script, cstring(layoutId)) != 1:
      result = context.fallbackLayoutResult(
        JanetLayoutOutcome.Missing, "janet layout file did not register layout",
        started, entry.path,
      )
      result.logLayoutEval()
      return
    return runtime.evalLoadedLayout(
      context, entry, started, "janet layout evaluation failed"
    )

  let paths = runtime.scriptPaths()
  runtime.evictMissingScripts(paths)
  if paths.len == 0:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.Missing, "no janet layout scripts found", started
    )
    result.logLayoutEval()
    return

  var firstLoadError = ""
  var firstLoadPath = ""
  for path in paths:
    let loaded = runtime.loadScriptEntry(path, snapshot)
    let entry = loaded.entry
    if entry.failed:
      if firstLoadError.len == 0:
        firstLoadError = entry.error
        firstLoadPath = entry.path
      continue
    if triadJanetScriptHasLayout(
      entry.script, cstring(context.layoutId.layoutIdString())
    ) != 1:
      continue

    return runtime.evalLoadedLayout(
      context, entry, started, "janet layout evaluation failed"
    )

  if firstLoadError.len > 0:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.LoadFailed, "janet layout script failed to load", started,
      firstLoadPath, firstLoadError,
    )
  else:
    result = context.fallbackLayoutResult(
      JanetLayoutOutcome.Missing, "janet layout is not registered", started
    )
  result.logLayoutEval()

proc evalLayoutMovementDetailed*(
    runtime: var JanetRuntime,
    snapshot: ShellSnapshot,
    context: JanetLayoutContext,
    direction: Direction,
): JanetLayoutMovementEvalResult =
  let started = epochTime()
  if runtime.handle == nil:
    return context.missingMovementResult(started)

  let layoutId = context.layoutId.layoutIdString()
  if layoutId.isBundledLayoutId():
    let bundled = runtime.loadBundledLayoutEntry(layoutId, snapshot)
    if not bundled.entry.failed and
        triadJanetScriptHasLayoutMovement(bundled.entry.script, cstring(layoutId)) == 1:
      return
        runtime.evalLoadedLayoutMovement(context, direction, bundled.entry, started)

  if not runtime.config.enabled:
    return context.missingMovementResult(started)

  let directLayoutPath = runtime.layoutScriptPath(layoutId)
  if directLayoutPath.len > 0 and fileExists(directLayoutPath):
    let loaded = runtime.loadScriptEntry(directLayoutPath, snapshot)
    let entry = loaded.entry
    if entry.failed:
      return context.failedMovementResult(
        started,
        entry.path,
        if entry.error.len > 0: entry.error else: "Janet movement load failed",
      )
    if triadJanetScriptHasLayoutMovement(entry.script, cstring(layoutId)) == 1:
      return runtime.evalLoadedLayoutMovement(context, direction, entry, started)
    return context.missingMovementResult(started)

  let paths = runtime.scriptPaths()
  runtime.evictMissingScripts(paths)
  for path in paths:
    let loaded = runtime.loadScriptEntry(path, snapshot)
    let entry = loaded.entry
    if not entry.failed and
        triadJanetScriptHasLayoutMovement(entry.script, cstring(layoutId)) == 1:
      return runtime.evalLoadedLayoutMovement(context, direction, entry, started)

  context.missingMovementResult(started)
