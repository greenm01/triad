import std/[algorithm, strutils, tables]
import chronicles
import wayland/native/client
import protocols/wlr_output_management/client as wlrOutput
import ../types/[model, runtime_values]
import state, wayland_helpers

const OutputModeRefreshTolerance = 1000'i32

type
  SelectedOutputMode* = object
    modeId*: uint32
    custom*: bool
    width*: int32
    height*: int32
    refresh*: int32

  ProposedHead* = object
    headId*: uint32
    head*: OutputManagementHeadRuntime
    ruleOpt*: tuple[found: bool, rule: OutputRuleData]
    mode*: SelectedOutputMode
    enabled*: bool
    width*: int32
    height*: int32
    x*: int32
    y*: int32
    positionSet*: bool

var wlrOutputManagerListener*: wlrOutput.ZwlrOutputManagerV1Listener
var wlrOutputHeadListener*: wlrOutput.ZwlrOutputHeadV1Listener
var wlrOutputModeListener*: wlrOutput.ZwlrOutputModeV1Listener
var wlrOutputConfigListener*: wlrOutput.ZwlrOutputConfigurationV1Listener

proc destroyOutputConfig*(daemon: var TriadDaemon)

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
  if model.outputLayoutRows.len > 0:
    return true
  for rule in model.outputRules:
    if rule.modeSet or rule.scaleSet or rule.positionSet or rule.transformSet or
        rule.adaptiveSyncSet or rule.enabledSet:
      return true
  false

proc headMatchesTarget(head: OutputManagementHeadRuntime, target: string): bool =
  let wanted = target.strip()
  if wanted.len == 0:
    return false
  if wanted.startsWith("desc:"):
    let description = wanted[5 ..^ 1].strip()
    return head.description.len > 0 and head.description.cmpIgnoreCase(description) == 0
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
  var fallback: tuple[found: bool, rule: OutputRuleData]
  for rule in model.outputRules:
    if rule.target.len == 0:
      fallback = (true, rule)
    elif head.headMatchesTarget(rule.target):
      result = (true, rule)
      return
  fallback

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

proc modeScore(
    mode: OutputManagementModeRuntime, kind: OutputModeKind
): tuple[a, b, c: int64] =
  let area = int64(mode.width) * int64(mode.height)
  case kind
  of OutputModeKind.OutputModeHighRes:
    (area, int64(mode.refresh), int64(mode.width))
  of OutputModeKind.OutputModeHighRr:
    (int64(mode.refresh), area, int64(mode.width))
  of OutputModeKind.OutputModeMaxWidth:
    (int64(mode.width), int64(mode.height), int64(mode.refresh))
  else:
    (0'i64, 0'i64, 0'i64)

proc betterMode(
    daemon: TriadDaemon, currentId, candidateId: uint32, kind: OutputModeKind
): bool =
  if not daemon.wlrOutputModes.hasKey(candidateId):
    return false
  if currentId == 0'u32 or not daemon.wlrOutputModes.hasKey(currentId):
    return true
  let candidate = daemon.wlrOutputModes[candidateId]
  let current = daemon.wlrOutputModes[currentId]
  candidate.modeScore(kind) > current.modeScore(kind)

proc preferredMode(daemon: TriadDaemon, head: OutputManagementHeadRuntime): uint32 =
  for modeId in head.modeIds:
    if daemon.wlrOutputModes.hasKey(modeId):
      let mode = daemon.wlrOutputModes[modeId]
      if not mode.finished and mode.preferred:
        return modeId

proc bestMode(
    daemon: TriadDaemon, head: OutputManagementHeadRuntime, kind: OutputModeKind
): uint32 =
  for modeId in head.modeIds:
    if not daemon.wlrOutputModes.hasKey(modeId):
      continue
    let mode = daemon.wlrOutputModes[modeId]
    if mode.finished:
      continue
    if daemon.betterMode(result, modeId, kind):
      result = modeId

proc selectedModeId(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
): SelectedOutputMode =
  result = SelectedOutputMode(modeId: head.currentModeId)
  if not ruleOpt.found or not ruleOpt.rule.modeSet:
    return
  let rule = ruleOpt.rule
  case rule.modeKind
  of OutputModeKind.OutputModeExplicit:
    let modeId =
      daemon.findMode(head, rule.modeWidth, rule.modeHeight, rule.modeRefresh)
    if modeId != 0'u32:
      result.modeId = modeId
      return
    if rule.modeCustomAllowed:
      result = SelectedOutputMode(
        custom: true,
        width: rule.modeWidth,
        height: rule.modeHeight,
        refresh: rule.modeRefresh,
      )
      return
    warn "Configured output mode is not advertised; keeping current mode",
      output = head.name,
      width = rule.modeWidth,
      height = rule.modeHeight,
      refresh = rule.modeRefresh
  of OutputModeKind.OutputModePreferred:
    let modeId = daemon.preferredMode(head)
    if modeId != 0'u32:
      result.modeId = modeId
  of OutputModeKind.OutputModeHighRes, OutputModeKind.OutputModeHighRr,
      OutputModeKind.OutputModeMaxWidth:
    let modeId = daemon.bestMode(head, rule.modeKind)
    if modeId != 0'u32:
      result.modeId = modeId

proc needsOutputApply(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
    selectedMode: SelectedOutputMode,
    positionSet: bool,
    positionX, positionY: int32,
): bool =
  if not ruleOpt.found:
    return positionSet and (head.x != positionX or head.y != positionY)
  let rule = ruleOpt.rule
  if rule.enabledSet and (not head.enabledSet or head.enabled != rule.enabled):
    return true
  if selectedMode.custom:
    if head.currentModeId != 0'u32 and daemon.wlrOutputModes.hasKey(head.currentModeId):
      let current = daemon.wlrOutputModes[head.currentModeId]
      if current.width != selectedMode.width or current.height != selectedMode.height or
          abs(current.refresh - selectedMode.refresh) > OutputModeRefreshTolerance:
        return true
    else:
      return true
  elif rule.modeSet and selectedMode.modeId != 0'u32 and
      selectedMode.modeId != head.currentModeId:
    return true
  if positionSet and (head.x != positionX or head.y != positionY):
    return true
  if rule.transformSet and head.transform != rule.transform.outputTransformValue():
    return true
  if rule.scaleSet and not rule.scaleAuto and
      (not head.scaleSet or head.scale.floatChanged(rule.scale)):
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
    selectedMode: SelectedOutputMode,
    positionSet: bool,
    positionX, positionY: int32,
) =
  if ruleOpt.found and ruleOpt.rule.enabledSet and not ruleOpt.rule.enabled:
    config.disableHead(head.pointer)
    return
  if not head.enabledSet or not head.enabled:
    if not ruleOpt.found or not ruleOpt.rule.enabledSet or not ruleOpt.rule.enabled:
      config.disableHead(head.pointer)
      return

  let headConfig = config.enableHead(head.pointer)
  if selectedMode.custom:
    headConfig.setCustomMode(
      selectedMode.width, selectedMode.height, selectedMode.refresh
    )
  elif selectedMode.modeId != 0'u32 and daemon.wlrOutputModes.hasKey(
    selectedMode.modeId
  ):
    headConfig.setMode(daemon.wlrOutputModes[selectedMode.modeId].pointer)

  let x = if positionSet: positionX else: head.x
  let y = if positionSet: positionY else: head.y
  headConfig.setPosition(x, y)

  let transform =
    if ruleOpt.found and ruleOpt.rule.transformSet:
      ruleOpt.rule.transform.outputTransformValue()
    else:
      head.transform
  headConfig.setTransform(transform)

  let scale =
    if ruleOpt.found and ruleOpt.rule.scaleSet and not ruleOpt.rule.scaleAuto:
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

proc headRuntimeEnabled(head: OutputManagementHeadRuntime): bool =
  not head.enabledSet or head.enabled

proc restoreContains(daemon: TriadDaemon, headId: uint32): bool =
  for restoredId in daemon.monitorPowerRestoreHeadIds:
    if restoredId == headId:
      return true
  false

proc addRestoreHead(headIds: var seq[uint32], headId: uint32) =
  for existing in headIds:
    if existing == headId:
      return
  headIds.add(headId)

proc containsHead(headIds: seq[uint32], headId: uint32): bool =
  for existing in headIds:
    if existing == headId:
      return true
  false

proc restoreAfterPowerOn(restoreIds, enabledIds: seq[uint32]): seq[uint32] =
  for restoreId in restoreIds:
    if not enabledIds.containsHead(restoreId):
      result.add(restoreId)

proc targetPowerEnabled(
    daemon: TriadDaemon,
    headId: uint32,
    currentlyEnabled: bool,
    selectedHeadIds: seq[uint32],
    enabled: bool,
    restoreAll: bool,
    targeted: bool,
): bool =
  if not selectedHeadIds.containsHead(headId):
    return currentlyEnabled
  if enabled:
    return restoreAll or targeted or daemon.restoreContains(headId)
  false

proc configureHeadPower(
    daemon: TriadDaemon,
    config: ptr wlrOutput.ZwlrOutputConfigurationV1,
    head: OutputManagementHeadRuntime,
    enabled: bool,
) =
  if not enabled:
    config.disableHead(head.pointer)
    return

  let headConfig = config.enableHead(head.pointer)
  let modeId =
    if head.currentModeId != 0'u32:
      head.currentModeId
    else:
      daemon.preferredMode(head)
  if modeId != 0'u32 and daemon.wlrOutputModes.hasKey(modeId):
    headConfig.setMode(daemon.wlrOutputModes[modeId].pointer)

  headConfig.setPosition(head.x, head.y)
  headConfig.setTransform(head.transform)
  headConfig.setScale((if head.scaleSet: head.scale else: 1.0'f32).fixedFromFloat())

  let canSetAdaptiveSync =
    daemon.wlrOutputManager != nil and daemon.wlrOutputManager.getVersion() >= 4'u32
  if head.adaptiveSyncSet and canSetAdaptiveSync:
    headConfig.setAdaptiveSync(if head.adaptiveSync: 1'u32 else: 0'u32)

proc applyMonitorPower*(daemon: var TriadDaemon, enabled: bool, target = "") =
  if daemon.wlrOutputManager == nil:
    warn "Monitor power request ignored; output-management protocol is unavailable",
      enabled = enabled, target = target
    return
  if not daemon.wlrOutputReady or daemon.wlrOutputApplyInFlight:
    warn "Monitor power request ignored; output-management state is not ready",
      enabled = enabled,
      target = target,
      ready = daemon.wlrOutputReady,
      inFlight = daemon.wlrOutputApplyInFlight
    return

  let wanted = target.strip()
  var heads: seq[tuple[headId: uint32, head: OutputManagementHeadRuntime]] = @[]
  for headId, head in daemon.wlrOutputHeads.pairs:
    if not head.finished and head.pointer != nil:
      heads.add((headId: headId, head: head))
  heads.sort(
    proc(a, b: tuple[headId: uint32, head: OutputManagementHeadRuntime]): int =
      result = cmp(a.head.name, b.head.name)
      if result == 0:
        result = cmp(a.headId, b.headId)
  )

  if heads.len == 0:
    warn "Monitor power request ignored; no outputs are advertised",
      enabled = enabled, target = wanted
    return

  var selectedHeadIds: seq[uint32] = @[]
  for item in heads:
    if wanted.len == 0 or item.head.headMatchesTarget(wanted):
      selectedHeadIds.add(item.headId)

  if selectedHeadIds.len == 0:
    warn "Monitor power request ignored; output target is not available",
      enabled = enabled, target = wanted
    return

  var nextRestoreHeadIds = daemon.monitorPowerRestoreHeadIds
  if not enabled:
    for item in heads:
      if selectedHeadIds.containsHead(item.headId) and item.head.headRuntimeEnabled():
        nextRestoreHeadIds.addRestoreHead(item.headId)
    if nextRestoreHeadIds.len == daemon.monitorPowerRestoreHeadIds.len:
      warn "Monitor power-off request ignored; no selected enabled outputs were found",
        target = wanted
      return
  else:
    nextRestoreHeadIds =
      daemon.monitorPowerRestoreHeadIds.restoreAfterPowerOn(selectedHeadIds)

  let restoreAll =
    enabled and wanted.len == 0 and daemon.monitorPowerRestoreHeadIds.len == 0
  var anyChange = false
  for item in heads:
    let targetEnabled = daemon.targetPowerEnabled(
      item.headId,
      item.head.headRuntimeEnabled(),
      selectedHeadIds,
      enabled,
      restoreAll,
      wanted.len > 0,
    )
    if item.head.headRuntimeEnabled() != targetEnabled:
      anyChange = true
      break

  if not anyChange:
    daemon.monitorPowerRestoreHeadIds = nextRestoreHeadIds
    daemon.monitorPowerOffActive = daemon.monitorPowerRestoreHeadIds.len > 0
    return

  let config = daemon.wlrOutputManager.createConfiguration(daemon.wlrOutputSerial)
  daemon.destroyOutputConfig()
  daemon.wlrOutputConfig = config
  daemon.wlrOutputConfigListenerData = new(WlrOutputConfigListenerData)
  daemon.wlrOutputConfigListenerData[] = WlrOutputConfigListenerData(
    daemon: addr daemon,
    serial: daemon.wlrOutputSerial,
    monitorPowerCompletionSet: true,
    monitorPowerRestoreHeadIds: nextRestoreHeadIds,
  )
  discard config.addListener(
    wlrOutputConfigListener.addr, cast[pointer](daemon.wlrOutputConfigListenerData)
  )

  for item in heads:
    let targetEnabled = daemon.targetPowerEnabled(
      item.headId,
      item.head.headRuntimeEnabled(),
      selectedHeadIds,
      enabled,
      restoreAll,
      wanted.len > 0,
    )
    daemon.configureHeadPower(config, item.head, targetEnabled)

  daemon.wlrOutputApplyInFlight = true
  info "Applying monitor power request",
    enabled = enabled, target = wanted, serial = daemon.wlrOutputSerial
  config.apply()

proc selectedModeSize(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    selectedMode: SelectedOutputMode,
): tuple[w, h: int32] =
  if selectedMode.custom:
    return (selectedMode.width, selectedMode.height)
  if selectedMode.modeId != 0'u32 and daemon.wlrOutputModes.hasKey(selectedMode.modeId):
    let mode = daemon.wlrOutputModes[selectedMode.modeId]
    return (mode.width, mode.height)
  if head.currentModeId != 0'u32 and daemon.wlrOutputModes.hasKey(head.currentModeId):
    let mode = daemon.wlrOutputModes[head.currentModeId]
    return (mode.width, mode.height)
  (0'i32, 0'i32)

proc logicalHeadSize(
    daemon: TriadDaemon,
    head: OutputManagementHeadRuntime,
    ruleOpt: tuple[found: bool, rule: OutputRuleData],
    selectedMode: SelectedOutputMode,
): tuple[w, h: int32] =
  let size = daemon.selectedModeSize(head, selectedMode)
  var w = size.w
  var h = size.h
  let transform =
    if ruleOpt.found and ruleOpt.rule.transformSet:
      ruleOpt.rule.transform.outputTransformValue()
    else:
      head.transform
  if transform in [1'i32, 3'i32, 5'i32, 7'i32]:
    swap(w, h)
  let scale =
    if ruleOpt.found and ruleOpt.rule.scaleSet and not ruleOpt.rule.scaleAuto:
      ruleOpt.rule.scale
    elif head.scaleSet:
      head.scale
    else:
      1.0'f32
  (
    max(1'i32, int32(float32(w) / max(0.01'f32, scale))),
    max(1'i32, int32(float32(h) / max(0.01'f32, scale))),
  )

proc findLayoutHead(
    heads: seq[ProposedHead], target: string, used: openArray[bool]
): int =
  for idx, proposed in heads:
    if used[idx] or not proposed.enabled:
      continue
    if proposed.head.headMatchesTarget(target):
      return idx
  -1

proc resolveLayoutPositions*(model: Model, heads: var seq[ProposedHead]) =
  if model.outputLayoutRows.len == 0:
    return

  var used = newSeq[bool](heads.len)
  var rows: seq[
    tuple[indices: seq[int], align: OutputLayoutRowAlign, width: int32, height: int32]
  ]
  var matrixWidth = 0'i32

  for row in model.outputLayoutRows:
    var indices: seq[int]
    var rowWidth = 0'i32
    var rowHeight = 0'i32
    for target in row.targets:
      let idx = heads.findLayoutHead(target, used)
      if idx < 0:
        warn "Configured output layout target is not available", target = target
        continue
      used[idx] = true
      indices.add(idx)
      rowWidth += heads[idx].width
      rowHeight = max(rowHeight, heads[idx].height)
    if indices.len > 0:
      rows.add((indices: indices, align: row.align, width: rowWidth, height: rowHeight))
      matrixWidth = max(matrixWidth, rowWidth)

  var y = 0'i32
  for row in rows:
    var x =
      case row.align
      of OutputLayoutRowAlign.Left:
        0'i32
      of OutputLayoutRowAlign.Center:
        (matrixWidth - row.width) div 2
      of OutputLayoutRowAlign.Right:
        matrixWidth - row.width
    for idx in row.indices:
      heads[idx].x = x
      heads[idx].y = y + (row.height - heads[idx].height) div 2
      heads[idx].positionSet = true
      x += heads[idx].width
    y += row.height

proc resolveAutoPositions*(heads: var seq[ProposedHead]) =
  var minX = 0'i32
  var minY = 0'i32
  var maxX = 0'i32
  var maxY = 0'i32
  var placed = false

  for i in 0 ..< heads.len:
    if not heads[i].enabled:
      continue
    if not heads[i].positionSet:
      let ruleOpt = heads[i].ruleOpt
      if ruleOpt.found and ruleOpt.rule.positionSet and
          ruleOpt.rule.positionKind == OutputPositionKind.OutputPositionExplicit:
        heads[i].x = ruleOpt.rule.positionX
        heads[i].y = ruleOpt.rule.positionY
        heads[i].positionSet = true
      else:
        heads[i].x = heads[i].head.x
        heads[i].y = heads[i].head.y
        heads[i].positionSet = false

    if heads[i].positionSet:
      if not placed:
        minX = heads[i].x
        minY = heads[i].y
        maxX = heads[i].x + heads[i].width
        maxY = heads[i].y + heads[i].height
        placed = true
      else:
        minX = min(minX, heads[i].x)
        minY = min(minY, heads[i].y)
        maxX = max(maxX, heads[i].x + heads[i].width)
        maxY = max(maxY, heads[i].y + heads[i].height)

  for i in 0 ..< heads.len:
    if not heads[i].enabled:
      continue
    if heads[i].positionSet:
      continue
    let ruleOpt = heads[i].ruleOpt
    if not ruleOpt.found or not ruleOpt.rule.positionSet or
        ruleOpt.rule.positionKind == OutputPositionKind.OutputPositionExplicit:
      continue
    if not placed:
      heads[i].x = 0
      heads[i].y = 0
    else:
      case ruleOpt.rule.positionKind
      of OutputPositionKind.OutputPositionAuto,
          OutputPositionKind.OutputPositionAutoRight:
        heads[i].x = maxX
        heads[i].y = minY
      of OutputPositionKind.OutputPositionAutoLeft:
        heads[i].x = minX - heads[i].width
        heads[i].y = minY
      of OutputPositionKind.OutputPositionAutoUp:
        heads[i].x = minX
        heads[i].y = minY - heads[i].height
      of OutputPositionKind.OutputPositionAutoDown:
        heads[i].x = minX
        heads[i].y = maxY
      of OutputPositionKind.OutputPositionAutoCenterRight:
        heads[i].x = maxX
        heads[i].y = minY + (maxY - minY - heads[i].height) div 2
      of OutputPositionKind.OutputPositionAutoCenterLeft:
        heads[i].x = minX - heads[i].width
        heads[i].y = minY + (maxY - minY - heads[i].height) div 2
      of OutputPositionKind.OutputPositionAutoCenterUp:
        heads[i].x = minX + (maxX - minX - heads[i].width) div 2
        heads[i].y = minY - heads[i].height
      of OutputPositionKind.OutputPositionAutoCenterDown:
        heads[i].x = minX + (maxX - minX - heads[i].width) div 2
        heads[i].y = maxY
      of OutputPositionKind.OutputPositionExplicit:
        discard
    heads[i].positionSet = true
    if not placed:
      minX = heads[i].x
      minY = heads[i].y
      maxX = heads[i].x + heads[i].width
      maxY = heads[i].y + heads[i].height
      placed = true
    else:
      minX = min(minX, heads[i].x)
      minY = min(minY, heads[i].y)
      maxX = max(maxX, heads[i].x + heads[i].width)
      maxY = max(maxY, heads[i].y + heads[i].height)

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
  if daemon.monitorPowerOffActive:
    return
  if not daemon.runtimeState.model.hasOutputManagementConfig():
    return

  var proposedHeads: seq[ProposedHead] = @[]
  var matchedTargets: Table[string, bool]
  for headId, head in daemon.wlrOutputHeads.pairs:
    if head.finished:
      continue
    let ruleOpt = daemon.runtimeState.model.outputRuleForHead(head)
    if ruleOpt.found and ruleOpt.rule.target.len > 0:
      matchedTargets[ruleOpt.rule.target] = true
    let mode = daemon.selectedModeId(head, ruleOpt)
    let size = daemon.logicalHeadSize(head, ruleOpt, mode)
    let enabled =
      if ruleOpt.found and ruleOpt.rule.enabledSet:
        ruleOpt.rule.enabled
      else:
        not head.enabledSet or head.enabled
    proposedHeads.add(
      ProposedHead(
        headId: headId,
        head: head,
        ruleOpt: ruleOpt,
        mode: mode,
        enabled: enabled,
        width: size.w,
        height: size.h,
      )
    )

  proposedHeads.sort(
    proc(a, b: ProposedHead): int =
      result = cmp(a.head.name, b.head.name)
      if result == 0:
        result = cmp(a.headId, b.headId)
  )
  daemon.runtimeState.model.resolveLayoutPositions(proposedHeads)
  proposedHeads.resolveAutoPositions()

  var enabledCount = 0
  var anyChange = false
  for proposed in proposedHeads:
    if proposed.enabled:
      inc enabledCount
    if daemon.needsOutputApply(
      proposed.head, proposed.ruleOpt, proposed.mode, proposed.positionSet, proposed.x,
      proposed.y,
    ):
      anyChange = true

  if proposedHeads.len > 0 and enabledCount == 0:
    warn "Output-management config ignored; it would disable every output",
      reason = reason
    return

  for rule in daemon.runtimeState.model.outputRules:
    if (
      rule.modeSet or rule.scaleSet or rule.positionSet or rule.transformSet or
      rule.adaptiveSyncSet or rule.enabledSet
    ) and rule.target.len > 0 and not matchedTargets.getOrDefault(rule.target, false):
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

  for proposed in proposedHeads:
    daemon.configureHead(
      config, proposed.head, proposed.ruleOpt, proposed.mode, proposed.positionSet,
      proposed.x, proposed.y,
    )

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
  if listenerData.monitorPowerCompletionSet:
    daemon.monitorPowerRestoreHeadIds = listenerData.monitorPowerRestoreHeadIds
    daemon.monitorPowerOffActive = daemon.monitorPowerRestoreHeadIds.len > 0
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
  if listenerData.monitorPowerCompletionSet:
    daemon.wlrOutputRetryPending = false
    return
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
