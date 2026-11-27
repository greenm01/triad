import std/tables
import chronicles
import wayland/native/client
import protocols/river/client as river
import protocols/river_layer_shell/client as riverLayer
import wayland/protocols/wayland/client as wlCore
import ../core/msg
import capture_sessions_runtime, message_queue, state, wayland_helpers

proc callbackDaemon(data: pointer, context: string): ptr TriadDaemon =
  result = daemonFromData(data)
  if result == nil:
    warn "Ignoring River output callback without daemon context", context = context

proc onOutputDimensions(
    data: pointer, output: ptr RiverOutputV1, width: int32, height: int32
) =
  let daemon = callbackDaemon(data, "output dimensions")
  if daemon == nil:
    return
  info "Output dimensions changed",
    outputId = output.id(), width = width, height = height
  daemon.enqueue(
    Msg(
      kind: MsgKind.WlOutputDimensions,
      outputId: output.id(),
      width: width,
      height: height,
    )
  )

proc queueOutputRemoval*(daemon: var TriadDaemon, id: uint32) =
  if daemon.outputPointers.len == 0:
    daemon.deferOutputRemovals(id)
    warn "All River outputs disappeared; deferring model output removals",
      outputId = id, deferredRemovals = daemon.deferredOutputRemovals.len
  elif id notin daemon.deferredOutputRemovals:
    daemon.enqueue(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: id))

proc flushDeferredOutputRemovals*(daemon: var TriadDaemon) =
  if daemon.outputPointers.len == 0 or daemon.deferredOutputRemovals.len == 0:
    return
  # River has sent the returning outputs' state before manage_start. Let the
  # model add those outputs first so removed workspaces have a fallback.
  for id in daemon.deferredOutputRemovals:
    if not daemon.outputPointers.hasKey(id):
      daemon.enqueue(Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: id))
  daemon.deferredOutputRemovals.setLen(0)

proc onOutputRemoved(data: pointer, output: ptr RiverOutputV1) =
  let daemon = callbackDaemon(data, "output removed")
  if daemon == nil:
    return
  let id = output.id()
  info "Output removed", outputId = id
  let hadCaptureSessions = daemon.outputCaptureSessions.hasKey(id)
  let captureSessionsWereActive = daemon[].captureSessionsActive()
  daemon[].clearOutputCaptureSessions(id)
  if hadCaptureSessions:
    daemon[].handleCaptureSessionsChanged(captureSessionsWereActive)
  if daemon.layerOutputPointers.hasKey(id):
    let layerOutput = daemon.layerOutputPointers[id]
    daemon.layerOutputOwners.del(layerOutput.id())
    daemon.layerOutputPointers.del(id)
    layerOutput.destroy()
  daemon.outputPointers.del(id)
  if daemon.outputWlNames.hasKey(id):
    let globalName = daemon.outputWlNames[id]
    daemon.outputGlobalOwners.del(globalName)
    daemon.outputGlobalNames.del(globalName)
    daemon.outputGlobalIdentities.del(globalName)
    daemon.outputGlobalDescriptions.del(globalName)
    daemon.outputGlobalRefreshRates.del(globalName)
    daemon.outputGlobalPhysicalMetadata.del(globalName)
    daemon.outputGlobalScales.del(globalName)
    daemon.outputWlNames.del(id)
  daemon[].queueOutputRemoval(id)
  output.destroy()

proc onOutputWlOutput(data: pointer, output: ptr RiverOutputV1, name: uint32) =
  let daemon = callbackDaemon(data, "output wl_output")
  if daemon == nil:
    return
  let outputId = output.id()
  daemon.outputWlNames[outputId] = name
  daemon.outputGlobalOwners[name] = outputId
  trace "Output wl_output received", outputId = outputId, name = name
  if daemon.outputGlobalNames.hasKey(name):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputName,
        nameOutputId: outputId,
        outputName: daemon.outputGlobalNames[name],
      )
    )
  if daemon.outputGlobalIdentities.hasKey(name):
    let identity = daemon.outputGlobalIdentities[name]
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: outputId,
        outputMake: identity.make,
        outputModel: identity.modelName,
      )
    )
  if daemon.outputGlobalDescriptions.hasKey(name):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: outputId,
        outputDescription: daemon.outputGlobalDescriptions[name],
      )
    )
  if daemon.outputGlobalRefreshRates.hasKey(name):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputRefreshRate,
        refreshOutputId: outputId,
        outputRefreshRate: daemon.outputGlobalRefreshRates[name],
      )
    )
  if daemon.outputGlobalPhysicalMetadata.hasKey(name):
    let metadata = daemon.outputGlobalPhysicalMetadata[name]
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputPhysicalMetadata,
        metadataOutputId: outputId,
        outputPhysicalWidth: metadata.physicalWidth,
        outputPhysicalHeight: metadata.physicalHeight,
        outputTransform: metadata.transform,
      )
    )
  if daemon.outputGlobalScales.hasKey(name):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputScale,
        scaleOutputId: outputId,
        outputScale: daemon.outputGlobalScales[name],
      )
    )

proc onWlOutputGeometry(
    data: pointer,
    output: ptr Output,
    x: int32,
    y: int32,
    physicalWidth: int32,
    physicalHeight: int32,
    subpixel: int32,
    make: cstring,
    model: cstring,
    transform: int32,
) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output geometry without daemon context"
    return
  let daemon = listenerData.daemon
  let globalName = listenerData.globalName
  daemon.outputGlobalIdentities[globalName] = (make: $make, modelName: $model)
  daemon.outputGlobalPhysicalMetadata[globalName] =
    (physicalWidth: physicalWidth, physicalHeight: physicalHeight, transform: transform)
  if daemon.outputGlobalOwners.hasKey(globalName):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputIdentity,
        identityOutputId: daemon.outputGlobalOwners[globalName],
        outputMake: $make,
        outputModel: $model,
      )
    )
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputPhysicalMetadata,
        metadataOutputId: daemon.outputGlobalOwners[globalName],
        outputPhysicalWidth: physicalWidth,
        outputPhysicalHeight: physicalHeight,
        outputTransform: transform,
      )
    )

proc onWlOutputMode(
    data: pointer,
    output: ptr Output,
    flags: uint32,
    width: int32,
    height: int32,
    refresh: int32,
) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output mode without daemon context"
    return
  let daemon = listenerData.daemon
  let globalName = listenerData.globalName
  if refresh <= 0:
    return
  if (flags and 1'u32) != 0'u32 or not daemon.outputGlobalRefreshRates.hasKey(
    globalName
  ):
    daemon.outputGlobalRefreshRates[globalName] = refresh
    if daemon.outputGlobalOwners.hasKey(globalName):
      daemon.enqueue(
        Msg(
          kind: MsgKind.WlOutputRefreshRate,
          refreshOutputId: daemon.outputGlobalOwners[globalName],
          outputRefreshRate: refresh,
        )
      )

proc onWlOutputDone(data: pointer, output: ptr Output) =
  discard

proc onWlOutputScale(data: pointer, output: ptr Output, factor: int32) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output scale without daemon context"
    return
  if factor <= 0:
    return
  let daemon = listenerData.daemon
  let globalName = listenerData.globalName
  daemon.outputGlobalScales[globalName] = float32(factor)
  if daemon.outputGlobalOwners.hasKey(globalName):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputScale,
        scaleOutputId: daemon.outputGlobalOwners[globalName],
        outputScale: float32(factor),
      )
    )

proc onWlOutputName(data: pointer, output: ptr Output, name: cstring) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output name without daemon context"
    return
  let daemon = listenerData.daemon
  let globalName = listenerData.globalName
  let outputName = $name
  daemon.outputGlobalNames[globalName] = outputName
  trace "wl_output name received", globalName = globalName, outputName = outputName
  if daemon.outputGlobalOwners.hasKey(globalName):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputName,
        nameOutputId: daemon.outputGlobalOwners[globalName],
        outputName: outputName,
      )
    )

proc onWlOutputDescription(data: pointer, output: ptr Output, description: cstring) =
  let listenerData = cast[ptr WlOutputListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    warn "Ignoring wl_output description without daemon context"
    return
  let daemon = listenerData.daemon
  let globalName = listenerData.globalName
  daemon.outputGlobalDescriptions[globalName] = $description
  if daemon.outputGlobalOwners.hasKey(globalName):
    daemon.enqueue(
      Msg(
        kind: MsgKind.WlOutputDescription,
        descriptionOutputId: daemon.outputGlobalOwners[globalName],
        outputDescription: $description,
      )
    )

proc onOutputPosition(data: pointer, output: ptr RiverOutputV1, x: int32, y: int32) =
  let daemon = callbackDaemon(data, "output position")
  if daemon == nil:
    return
  info "Output position changed", outputId = output.id(), x = x, y = y
  daemon.enqueue(
    Msg(
      kind: MsgKind.WlOutputPosition,
      positionOutputId: output.id(),
      outputX: x,
      outputY: y,
    )
  )

proc onOutputCaptureSessions(data: pointer, output: ptr RiverOutputV1, count: uint32) =
  let daemon = callbackDaemon(data, "output capture sessions")
  if daemon == nil:
    return
  let id = output.id()
  trace "Output capture sessions changed", outputId = id, count = count
  let wasActive = daemon[].captureSessionsActive()
  daemon[].setOutputCaptureSessions(id, count)
  daemon[].handleCaptureSessionsChanged(wasActive)

var riverOutputListener* = RiverOutputV1Listener(
  removed: onOutputRemoved,
  output: onOutputWlOutput,
  position: onOutputPosition,
  dimensions: onOutputDimensions,
  captureSessions: onOutputCaptureSessions,
)

var wlOutputListener* = wlCore.OutputListener(
  geometry: onWlOutputGeometry,
  mode: onWlOutputMode,
  done: onWlOutputDone,
  scale: onWlOutputScale,
  name: onWlOutputName,
  description: onWlOutputDescription,
)
