import std/[strutils, tables]
import chronicles
import wayland/native/client
import protocols/wlr_output_management/client as wlrOutput
import ../types/[model, runtime_values]
import state, wayland_helpers

const OutputModeRefreshTolerance = 1000'i32

var wlrOutputManagerListener*: wlrOutput.ZwlrOutputManagerV1Listener
var wlrOutputHeadListener*: wlrOutput.ZwlrOutputHeadV1Listener
var wlrOutputModeListener*: wlrOutput.ZwlrOutputModeV1Listener
var wlrOutputConfigListener*: wlrOutput.ZwlrOutputConfigurationV1Listener

proc fixedFromFloat(value: float32): Fixed =
  Fixed(int32(cdouble(value) * 256.0))

proc fixedToFloat(value: Fixed): float32 =
  float32(float64(value) / 256.0)

proc outputTransformValue(transform: OutputConfigTransform): int32 =
  case transform
  of OutputConfigTransform.OutputTransformNormal: 0
  of OutputConfigTransform.OutputTransform90: 1
  of OutputConfigTransform.OutputTransform180: 2
  of OutputConfigTransform.OutputTransform270: 3
  of OutputConfigTransform.OutputTransformFlipped: 4
  of OutputConfigTransform.OutputTransformFlipped90: 5
  of OutputConfigTransform.OutputTransformFlipped180: 6
  of OutputConfigTransform.OutputTransformFlipped270: 7

proc floatChanged(a, b: float32): bool =
  abs(a - b) > 0.0001'f32

proc hasOutputManagementConfig(model: Model): bool =
  for rule in model.outputRules:
    if rule.modeSet or rule.scaleSet or rule.positionSet or rule.transformSet or
        rule.adaptiveSyncSet:
      return true
  false

proc headMatchesTarget(head: OutputManagementHeadRuntime, target: string): bool =
  let wanted = target.strip()
  if wanted.len == 0:
    return false
  if head.name.cmpIgnoreCase(wanted) == 0:
    return true
  if head.description.len > 0 and head.description.cmpIgnoreCase(wanted) == 0:
    return true

  let make = head.make.strip()
  let modelName = head.modelName.strip()
  if make.len > 0 or modelName.len > 0:
    let serial =
      if head.serialNumber.strip().len > 0:
        head.serialNumber.strip()
      else:
        "Unknown"
    let stableName =
      (if make.len > 0: make else: "Unknown") & " " &
      (if modelName.len > 0: modelName else: "Unknown") & " " & serial
    if stableName.cmpIgnoreCase(wanted) == 0:
      return true
    let legacyStableName =
      (if make.len > 0: make else: "Unknown") & " " &
      (if modelName.len > 0: modelName else: "Unknown") & " Unknown"
    if legacyStableName.cmpIgnoreCase(wanted) == 0:
      return true

  false

proc outputRuleForHead(
    model: Model, head: OutputManagementHeadRuntime
): tuple[found: bool, rule: OutputRuleData] =
  for rule in model.outputRules:
    if head.headMatchesTarget(rule.target):
      result = (true, rule)

proc findMode(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    width, height, refresh: int32,
): uint32 =
  var bestId = 0'u32
  var bestDelta = high(int32)
  for modeId in head.modeIds:
    if not daemon.wlrOutputModes.hasKey(modeId):
      continue
    let mode = daemon.wlrOutputModes[modeId]
    if mode.finished or mode.width != width or mode.height != height:
      continue
    let delta = abs(mode.refresh - refresh)
    if delta <= OutputModeRefreshTolerance and delta < bestDelta:
      bestId = modeId
      bestDelta = delta
  bestId

proc selectedModeId(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
): uint32 =
  result = head.currentModeId
  if not ruleOpt.found or not ruleOpt.rule.modeSet:
    return
  let modeId = daemon.findMode(
    head, ruleOpt.rule.modeWidth, ruleOpt.rule.modeHeight, ruleOpt.rule.modeRefresh
  )
  if modeId == 0'u32:
    warn "Configured output mode is not advertised; keeping current mode",
      output = head.name,
      width = ruleOpt.rule.modeWidth,
      height = ruleOpt.rule.modeHeight,
      refresh = ruleOpt.rule.modeRefresh
    return
  result = modeId

proc needsOutputApply(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
    modeId: uint32,
): bool =
  if not ruleOpt.found:
    return false
  let rule = ruleOpt.rule
  if rule.modeSet and modeId != 0'u32 and modeId != head.currentModeId:
    return true
  if rule.positionSet and (head.x != rule.positionX or head.y != rule.positionY):
    return true
  if rule.transformSet and head.transform != rule.transform.outputTransformValue():
    return true
  if rule.scaleSet and (not head.scaleSet or head.scale.floatChanged(rule.scale)):
    return true
  if rule.adaptiveSyncSet and
      (not head.adaptiveSyncSet or head.adaptiveSync != rule.adaptiveSync):
    return true
  false

proc configureHead(
    daemon: TriadDaemon,
    config: ptr wlrOutput.ZwlrOutputConfigurationV1,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
    modeId: uint32,
) =
  if not head.enabledSet or not head.enabled:
    config.disableHead(head.pointer)
    return

  let headConfig = config.enableHead(head.pointer)
  if modeId != 0'u32 and daemon.wlrOutputModes.hasKey(modeId):
    headConfig.setMode(daemon.wlrOutputModes[modeId].pointer)

  let x =
    if ruleOpt.found and ruleOpt.rule.positionSet: ruleOpt.rule.positionX else: head.x
  let y =
    if ruleOpt.found and ruleOpt.rule.positionSet: ruleOpt.rule.positionY else: head.y
  headConfig.setPosition(x, y)

  let transform =
    if ruleOpt.found and ruleOpt.rule.transformSet:
      ruleOpt.rule.transform.outputTransformValue()
    else:
      head.transform
  headConfig.setTransform(transform)

  let scale =
    if ruleOpt.found and ruleOpt.rule.scaleSet:
      ruleOpt.rule.scale
    elif head.scaleSet:
      head.scale
    else:
      1.0'f32
  headConfig.setScale(scale.fixedFromFloat())

  let canSetAdaptiveSync =
    daemon.wlrOutputManager != nil and daemon.wlrOutputManager.getVersion() >= 4'u32
  if ruleOpt.found and ruleOpt.rule.adaptiveSyncSet:
    if canSetAdaptiveSync:
      headConfig.setAdaptiveSync(if ruleOpt.rule.adaptiveSync: 1'u32 else: 0'u32)
    else:
      warn "Configured adaptive-sync ignored; output-management v4 is unavailable",
        output = head.name
  elif head.adaptiveSyncSet and canSetAdaptiveSync:
    headConfig.setAdaptiveSync(if head.adaptiveSync: 1'u32 else: 0'u32)

proc destroyOutputConfig*(daemon: var TriadDaemon) =
  if daemon.wlrOutputConfig != nil:
    daemon.wlrOutputConfig.destroy()
  daemon.wlrOutputConfig = nil
  daemon.wlrOutputConfigListenerData = nil

proc applyOutputManagementConfig*(daemon: var TriadDaemon, reason: string) =
  if daemon.wlrOutputManager == nil:
    if daemon.runtimeState.model.hasOutputManagementConfig():
      warn "Output-management config ignored; compositor protocol is unavailable",
        reason = reason
    return
  if not daemon.wlrOutputReady or daemon.wlrOutputApplyInFlight:
    return
  if not daemon.runtimeState.model.hasOutputManagementConfig():
    return

  var anyChange = false
  var selectedModes: Table[uint32, uint32]
  var matchedTargets: Table[string, bool]
  for headId, head in daemon.wlrOutputHeads.pairs:
    if head.finished:
      continue
    let ruleOpt = daemon.runtimeState.model.outputRuleForHead(head)
    if ruleOpt.found:
      matchedTargets[ruleOpt.rule.target] = true
    let modeId = daemon.selectedModeId(head, ruleOpt)
    selectedModes[headId] = modeId
    if daemon.needsOutputApply(head, ruleOpt, modeId):
      anyChange = true

  for rule in daemon.runtimeState.model.outputRules:
    if (
      rule.modeSet or rule.scaleSet or rule.positionSet or rule.transformSet or
      rule.adaptiveSyncSet
    ) and not matchedTargets.getOrDefault(rule.target, false):
      warn "Configured output target is not available", target = rule.target

  if not anyChange:
    daemon.wlrOutputRetryPending = false
    daemon.wlrOutputRetryCount = 0
    return

  let config = daemon.wlrOutputManager.createConfiguration(daemon.wlrOutputSerial)
  daemon.destroyOutputConfig()
  daemon.wlrOutputConfig = config
  daemon.wlrOutputConfigListenerData = new(WlrOutputConfigListenerData)
  daemon.wlrOutputConfigListenerData[] =
    WlrOutputConfigListenerData(daemon: addr daemon, serial: daemon.wlrOutputSerial)
  discard config.addListener(
    wlrOutputConfigListener.addr, cast[pointer](daemon.wlrOutputConfigListenerData)
  )

  for headId, head in daemon.wlrOutputHeads.pairs:
    if head.finished:
      continue
    let ruleOpt = daemon.runtimeState.model.outputRuleForHead(head)
    daemon.configureHead(config, head, ruleOpt, selectedModes.getOrDefault(headId, 0))

  daemon.wlrOutputApplyInFlight = true
  info "Applying output-management config",
    reason = reason, serial = daemon.wlrOutputSerial
  config.apply()

proc resetOutputManagementRetry*(daemon: var TriadDaemon) =
  daemon.wlrOutputRetryPending = false
  daemon.wlrOutputRetryCount = 0

proc onOutputManagerHead(
    data: pointer,
    manager: ptr wlrOutput.ZwlrOutputManagerV1,
    head: ptr wlrOutput.ZwlrOutputHeadV1,
) =
  let daemon = daemonFromData(data)
  if daemon == nil:
    warn "Ignoring output-management head without daemon context"
    return
  let headId = head.id()
  daemon.wlrOutputHeads[headId] =
    OutputManagementHeadRuntime(pointer: head, modeIds: @[])
  daemon.wlrOutputHeadListenerData[headId] = new(WlrOutputHeadListenerData)
  daemon.wlrOutputHeadListenerData[headId][] =
    WlrOutputHeadListenerData(daemon: daemon, headId: headId)
  discard head.addListener(
    wlrOutputHeadListener.addr, cast[pointer](daemon.wlrOutputHeadListenerData[headId])
  )
  debug "Output-management head advertised", headId = headId

proc onOutputManagerDone(
    data: pointer, manager: ptr wlrOutput.ZwlrOutputManagerV1, serial: uint32
) =
  let daemon = daemonFromData(data)
  if daemon == nil:
    warn "Ignoring output-management done without daemon context"
    return
  daemon.wlrOutputSerial = serial
  daemon.wlrOutputReady = true
  debug "Output-management state ready", serial = serial
  if daemon.wlrOutputRetryPending:
    daemon.wlrOutputRetryPending = false
    daemon[].applyOutputManagementConfig("output-management retry")
  else:
    daemon[].applyOutputManagementConfig("output-management state")

proc onOutputManagerFinished(
    data: pointer, manager: ptr wlrOutput.ZwlrOutputManagerV1
) =
  let daemon = daemonFromData(data)
  if daemon == nil:
    return
  warn "Output-management manager finished"
  daemon.wlrOutputManager = nil
  daemon.wlrOutputReady = false

proc onHeadName(data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, name: cstring) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].name = name.cstringOrEmpty()

proc onHeadDescription(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, description: cstring
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].description =
      description.cstringOrEmpty()

proc onHeadPhysicalSize(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, width, height: int32
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].physicalWidth = width
    listenerData.daemon.wlrOutputHeads[listenerData.headId].physicalHeight = height

proc onHeadMode(
    data: pointer,
    head: ptr wlrOutput.ZwlrOutputHeadV1,
    mode: ptr wlrOutput.ZwlrOutputModeV1,
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  let daemon = listenerData.daemon
  let modeId = mode.id()
  daemon.wlrOutputModes[modeId] =
    OutputManagementModeRuntime(pointer: mode, headId: listenerData.headId)
  if daemon.wlrOutputHeads.hasKey(listenerData.headId):
    daemon.wlrOutputHeads[listenerData.headId].modeIds.add(modeId)
  daemon.wlrOutputModeListenerData[modeId] = new(WlrOutputModeListenerData)
  daemon.wlrOutputModeListenerData[modeId][] =
    WlrOutputModeListenerData(daemon: daemon, modeId: modeId)
  discard mode.addListener(
    wlrOutputModeListener.addr, cast[pointer](daemon.wlrOutputModeListenerData[modeId])
  )

proc onHeadEnabled(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, enabled: int32
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].enabled = enabled != 0
    listenerData.daemon.wlrOutputHeads[listenerData.headId].enabledSet = true

proc onHeadCurrentMode(
    data: pointer,
    head: ptr wlrOutput.ZwlrOutputHeadV1,
    mode: ptr wlrOutput.ZwlrOutputModeV1,
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].currentModeId = mode.id()

proc onHeadPosition(data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, x, y: int32) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].x = x
    listenerData.daemon.wlrOutputHeads[listenerData.headId].y = y
    listenerData.daemon.wlrOutputHeads[listenerData.headId].positionSet = true

proc onHeadTransform(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, transform: int32
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].transform = transform
    listenerData.daemon.wlrOutputHeads[listenerData.headId].transformSet = true

proc onHeadScale(data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, scale: Fixed) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].scale = scale.fixedToFloat()
    listenerData.daemon.wlrOutputHeads[listenerData.headId].scaleSet = true

proc onHeadFinished(data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].finished = true

proc onHeadMake(data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, make: cstring) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].make = make.cstringOrEmpty()

proc onHeadModel(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, modelName: cstring
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].modelName =
      modelName.cstringOrEmpty()

proc onHeadSerialNumber(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, serialNumber: cstring
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].serialNumber =
      serialNumber.cstringOrEmpty()

proc onHeadAdaptiveSync(
    data: pointer, head: ptr wlrOutput.ZwlrOutputHeadV1, state: uint32
) =
  let listenerData = cast[ptr WlrOutputHeadListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputHeads.hasKey(listenerData.headId):
    listenerData.daemon.wlrOutputHeads[listenerData.headId].adaptiveSync = state != 0
    listenerData.daemon.wlrOutputHeads[listenerData.headId].adaptiveSyncSet = true

proc onModeSize(
    data: pointer, mode: ptr wlrOutput.ZwlrOutputModeV1, width, height: int32
) =
  let listenerData = cast[ptr WlrOutputModeListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputModes.hasKey(listenerData.modeId):
    listenerData.daemon.wlrOutputModes[listenerData.modeId].width = width
    listenerData.daemon.wlrOutputModes[listenerData.modeId].height = height

proc onModeRefresh(
    data: pointer, mode: ptr wlrOutput.ZwlrOutputModeV1, refresh: int32
) =
  let listenerData = cast[ptr WlrOutputModeListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputModes.hasKey(listenerData.modeId):
    listenerData.daemon.wlrOutputModes[listenerData.modeId].refresh = refresh

proc onModePreferred(data: pointer, mode: ptr wlrOutput.ZwlrOutputModeV1) =
  let listenerData = cast[ptr WlrOutputModeListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputModes.hasKey(listenerData.modeId):
    listenerData.daemon.wlrOutputModes[listenerData.modeId].preferred = true

proc onModeFinished(data: pointer, mode: ptr wlrOutput.ZwlrOutputModeV1) =
  let listenerData = cast[ptr WlrOutputModeListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  if listenerData.daemon.wlrOutputModes.hasKey(listenerData.modeId):
    listenerData.daemon.wlrOutputModes[listenerData.modeId].finished = true

proc onConfigSucceeded(data: pointer, config: ptr wlrOutput.ZwlrOutputConfigurationV1) =
  let listenerData = cast[ptr WlrOutputConfigListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  let daemon = listenerData.daemon
  info "Output-management config applied", serial = listenerData.serial
  daemon.wlrOutputApplyInFlight = false
  daemon.wlrOutputRetryPending = false
  daemon.wlrOutputRetryCount = 0
  daemon[].destroyOutputConfig()

proc onConfigFailed(data: pointer, config: ptr wlrOutput.ZwlrOutputConfigurationV1) =
  let listenerData = cast[ptr WlrOutputConfigListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  let daemon = listenerData.daemon
  warn "Output-management config failed; keeping current output state",
    serial = listenerData.serial
  daemon.wlrOutputApplyInFlight = false
  daemon.wlrOutputRetryPending = false
  daemon[].destroyOutputConfig()

proc onConfigCancelled(data: pointer, config: ptr wlrOutput.ZwlrOutputConfigurationV1) =
  let listenerData = cast[ptr WlrOutputConfigListenerData](data)
  if listenerData == nil or listenerData.daemon == nil:
    return
  let daemon = listenerData.daemon
  warn "Output-management config cancelled",
    serial = listenerData.serial, retryCount = daemon.wlrOutputRetryCount
  daemon.wlrOutputApplyInFlight = false
  daemon[].destroyOutputConfig()
  if daemon.wlrOutputRetryCount == 0:
    daemon.wlrOutputRetryCount = 1
    daemon.wlrOutputRetryPending = true
  else:
    daemon.wlrOutputRetryPending = false

wlrOutputManagerListener = wlrOutput.ZwlrOutputManagerV1Listener(
  head: onOutputManagerHead,
  done: onOutputManagerDone,
  finished: onOutputManagerFinished,
)

wlrOutputHeadListener = wlrOutput.ZwlrOutputHeadV1Listener(
  name: onHeadName,
  description: onHeadDescription,
  physicalSize: onHeadPhysicalSize,
  mode: onHeadMode,
  enabled: onHeadEnabled,
  currentMode: onHeadCurrentMode,
  position: onHeadPosition,
  transform: onHeadTransform,
  scale: onHeadScale,
  finished: onHeadFinished,
  make: onHeadMake,
  model: onHeadModel,
  serialNumber: onHeadSerialNumber,
  adaptiveSync: onHeadAdaptiveSync,
)

wlrOutputModeListener = wlrOutput.ZwlrOutputModeV1Listener(
  size: onModeSize,
  refresh: onModeRefresh,
  preferred: onModePreferred,
  finished: onModeFinished,
)

wlrOutputConfigListener = wlrOutput.ZwlrOutputConfigurationV1Listener(
  succeeded: onConfigSucceeded, failed: onConfigFailed, cancelled: onConfigCancelled
)
