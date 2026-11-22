import std/[options, os, osproc, strutils, tables, times]
import chronicles
import ../state/engine
import ../systems/outputs
import ../types/core
import ../utils/process_options
import process_runner, state, tracked_child

type MirrorSpec = object
  sourceOutput: OutputId
  targetOutput: OutputId
  sourceName: string
  targetName: string

proc unixMs(): int64 =
  int64(epochTime() * 1000.0)

proc outputConnectorName(model: Model, outputId: OutputId): string =
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return ""
  result = outputOpt.get().name.strip()
  if result.len == 0:
    result = model.shellOutputName(outputId)

proc desiredScreenMirrors(model: Model): Table[OutputId, MirrorSpec] =
  for rule in model.outputRules:
    if not rule.mirrorSet:
      continue
    let targetOutput = model.outputForTarget(rule.target)
    let sourceOutput = model.outputForTarget(rule.mirrorSource)
    if targetOutput == NullOutputId or sourceOutput == NullOutputId or
        targetOutput == sourceOutput:
      continue
    let sourceName = model.outputConnectorName(sourceOutput)
    let targetName = model.outputConnectorName(targetOutput)
    if sourceName.len == 0 or targetName.len == 0:
      continue
    result[targetOutput] = MirrorSpec(
      sourceOutput: sourceOutput,
      targetOutput: targetOutput,
      sourceName: sourceName,
      targetName: targetName,
    )

proc closeMirrorChild(runtime: var ScreenMirrorRuntime) =
  if not runtime.hasChild:
    return
  try:
    runtime.child.process.close()
  except CatchableError:
    discard
  runtime.hasChild = false

proc stopMirror(runtime: var ScreenMirrorRuntime, reason: string) =
  if not runtime.hasChild or runtime.stopping:
    return
  runtime.stopping = true
  runtime.stopReason = reason
  runtime.child.beginTermination(unixMs(), 250'i64)
  info "Stopping screen mirror",
    pid = runtime.child.process.processID, target = runtime.targetName, reason = reason

proc startMirror(model: Model, spec: MirrorSpec): ScreenMirrorRuntime =
  result = ScreenMirrorRuntime(
    sourceOutput: spec.sourceOutput,
    targetOutput: spec.targetOutput,
    sourceName: spec.sourceName,
    targetName: spec.targetName,
  )
  var executable = getEnv("TRIAD_MIRROR_BIN", "").strip()
  if executable.len == 0:
    let sibling = getAppFilename().parentDir() / "triad_mirror"
    if fileExists(sibling):
      executable = sibling
    else:
      executable = findExe("triad_mirror")
  if executable.len == 0:
    result.failed = true
    result.retryAfterMs = unixMs() + 5_000
    warn "Configured screen mirror unavailable; bundled triad_mirror was not found",
      source = spec.sourceName, target = spec.targetName
    return
  try:
    let process = startProcess(
      executable,
      args = @[spec.sourceName, spec.targetName],
      env = model.configuredProcessEnv(),
      options = InheritedProcessOptions,
    )
    result.child = initTrackedChild(process, unixMs(), 250'i64)
    result.hasChild = true
    info "Started screen mirror",
      pid = process.processID, source = spec.sourceName, target = spec.targetName
  except CatchableError as e:
    result.failed = true
    result.retryAfterMs = unixMs() + 2_000
    warn "Unable to start screen mirror",
      source = spec.sourceName, target = spec.targetName, error = e.msg

proc sameMirror(runtime: ScreenMirrorRuntime, spec: MirrorSpec): bool =
  runtime.sourceOutput == spec.sourceOutput and runtime.targetOutput == spec.targetOutput and
    runtime.sourceName == spec.sourceName and runtime.targetName == spec.targetName

proc syncScreenMirrors*(daemon: var TriadDaemon) =
  let desired = daemon.runtimeState.model.desiredScreenMirrors()
  let nowMs = unixMs()
  var targets: seq[OutputId] = @[]
  for targetOutput in daemon.screenMirrors.keys:
    targets.add(targetOutput)

  for targetOutput in targets:
    if not daemon.screenMirrors.hasKey(targetOutput):
      continue
    let runtime = daemon.screenMirrors[targetOutput]
    if not desired.hasKey(targetOutput) or not runtime.sameMirror(desired[targetOutput]):
      var stale = daemon.screenMirrors[targetOutput]
      stale.stopMirror("configuration or outputs changed")
      daemon.screenMirrors[targetOutput] = stale

  for targetOutput in targets:
    if not daemon.screenMirrors.hasKey(targetOutput):
      continue
    var runtime = daemon.screenMirrors[targetOutput]
    if runtime.hasChild:
      let reaped = runtime.child.advanceTrackedChild(nowMs, 250'i64)
      if reaped:
        if runtime.stopping:
          info "Stopped screen mirror",
            pid = runtime.child.process.processID,
            target = runtime.targetName,
            reason = runtime.stopReason,
            exitCode = runtime.child.exitCode
          runtime.closeMirrorChild()
          daemon.screenMirrors.del(targetOutput)
        else:
          warn "Screen mirror exited",
            source = runtime.sourceName,
            target = runtime.targetName,
            exitCode = runtime.child.exitCode
          runtime.failed = true
          runtime.retryAfterMs = nowMs + 1_000
          runtime.closeMirrorChild()
          daemon.screenMirrors[targetOutput] = runtime
      else:
        daemon.screenMirrors[targetOutput] = runtime
    elif runtime.stopping:
      daemon.screenMirrors.del(targetOutput)
    elif not desired.hasKey(targetOutput) or
        not runtime.sameMirror(desired[targetOutput]):
      daemon.screenMirrors.del(targetOutput)
    elif runtime.failed and nowMs >= runtime.retryAfterMs and
        desired.hasKey(targetOutput):
      daemon.screenMirrors.del(targetOutput)
      daemon.screenMirrors[targetOutput] =
        daemon.runtimeState.model.startMirror(desired[targetOutput])

  for targetOutput, spec in desired.pairs:
    if not daemon.screenMirrors.hasKey(targetOutput):
      daemon.screenMirrors[targetOutput] =
        daemon.runtimeState.model.startMirror(spec)

proc stopScreenMirrors*(daemon: var TriadDaemon, reason: string) =
  for targetOutput in daemon.screenMirrors.keys:
    var runtime = daemon.screenMirrors[targetOutput]
    runtime.stopMirror(reason)
    daemon.screenMirrors[targetOutput] = runtime
