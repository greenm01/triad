import std/[algorithm, options, sets, strutils, tables]
import ../state/engine

proc knownOutputIdentity*(value: string): string =
  result = value.strip()
  if result.cmpIgnoreCase("Unknown") == 0:
    result = ""

proc outputMakeModelSerial*(output: OutputData): string =
  let make = output.make.knownOutputIdentity()
  let modelName = output.model.knownOutputIdentity()
  if make.len == 0 and modelName.len == 0:
    return ""
  (if make.len > 0: make else: "Unknown") & " " &
    (if modelName.len > 0: modelName else: "Unknown") & " Unknown"

proc outputStableTarget*(model: Model, outputId: OutputId, output: OutputData): string =
  let stableName = output.outputMakeModelSerial()
  if stableName.len > 0:
    return stableName
  if output.description.strip().len > 0:
    return output.description.strip()
  if output.name.strip().len > 0:
    return output.name.strip()
  model.shellOutputName(outputId)

proc outputMatchesTarget*(
    model: Model, outputId: OutputId, output: OutputData, target: string
): bool =
  let wanted = target.strip()
  if wanted.len == 0:
    return false
  if wanted.startsWith("desc:"):
    let description = wanted[5 ..^ 1].strip()
    return
      output.description.len > 0 and output.description.cmpIgnoreCase(description) == 0
  if output.name.cmpIgnoreCase(wanted) == 0:
    return true
  if model.shellOutputName(outputId).cmpIgnoreCase(wanted) == 0:
    return true
  let stableName = output.outputMakeModelSerial()
  if stableName.len > 0 and stableName.cmpIgnoreCase(wanted) == 0:
    return true
  output.description.len > 0 and output.description.cmpIgnoreCase(wanted) == 0

proc reservedAreaForOutput(
    model: Model, outputId: OutputId, output: OutputData
): tuple[found: bool, top, right, bottom, left: int32] =
  var fallback: tuple[found: bool, top, right, bottom, left: int32]
  for rule in model.outputRules:
    if not rule.reservedAreaSet:
      continue
    if rule.target.len == 0:
      fallback = (
        true, rule.reservedTop, rule.reservedRight, rule.reservedBottom,
        rule.reservedLeft,
      )
    elif model.outputMatchesTarget(outputId, output, rule.target):
      return (
        true, rule.reservedTop, rule.reservedRight, rule.reservedBottom,
        rule.reservedLeft,
      )
  fallback

proc applyConfiguredOutputUsable*(model: var Model, outputId: OutputId): bool =
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return false

  let output = outputOpt.get()
  let reserved = model.reservedAreaForOutput(outputId, output)
  let baseX = if output.hasBaseUsable: output.baseUsableX else: output.x
  let baseY = if output.hasBaseUsable: output.baseUsableY else: output.y
  let baseW = if output.hasBaseUsable: output.baseUsableW else: output.w
  let baseH = if output.hasBaseUsable: output.baseUsableH else: output.h

  if not reserved.found:
    if output.hasBaseUsable and (
      output.usableX != baseX or output.usableY != baseY or output.usableW != baseW or
      output.usableH != baseH or not output.hasUsable
    ):
      result = model.setOutputEffectiveUsable(outputId, baseX, baseY, baseW, baseH)
    return

  let x = baseX + reserved.left
  let y = baseY + reserved.top
  let w = max(0'i32, baseW - reserved.left - reserved.right)
  let h = max(0'i32, baseH - reserved.top - reserved.bottom)
  if output.usableX != x or output.usableY != y or output.usableW != w or
      output.usableH != h or not output.hasUsable:
    result = model.setOutputEffectiveUsable(outputId, x, y, w, h)

proc outputForTarget*(model: Model, target: string): OutputId =
  if target.strip().len == 0:
    return NullOutputId
  for outputId, output in model.outputsWithId():
    if model.outputMatchesTarget(outputId, output, target):
      return outputId
  NullOutputId

proc activeOutputOrPrimary*(model: Model): OutputId =
  if model.activeOutput != NullOutputId and model.hasOutput(model.activeOutput):
    return model.activeOutput
  model.primaryOutput

proc restoreWorkspaceOutputsFor*(model: var Model, outputId: OutputId): bool =
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return false
  let output = outputOpt.get()
  let stableTarget = model.outputStableTarget(outputId, output)

  for tagId, _ in model.tagsWithId():
    let target = model.tagHomeOutputTargets.getOrDefault(tagId, "")
    if target.len > 0 and model.outputMatchesTarget(outputId, output, target):
      result = model.setTagOutput(tagId, outputId) or result
      result = model.clearVisibleTagOutside(tagId, outputId) or result

  let rememberedSlot = model.outputLastActiveSlots.getOrDefault(stableTarget, 0'u32)
  if rememberedSlot != 0:
    let tagId = model.tagForSlot(rememberedSlot)
    if tagId != NullTagId:
      if outputId == model.activeOutput and tagId != model.activeTag:
        result = model.setTagOutput(tagId, outputId) or result
      else:
        result = model.setOutputTag(outputId, tagId) or result

proc focusStartupOutput*(model: var Model, outputId: OutputId): bool =
  let outputOpt = model.outputData(outputId)
  if outputId == NullOutputId or outputOpt.isNone:
    return false

  result = model.setActiveOutput(outputId)
  var tagId = NullTagId
  let startupTag = model.tagForSlot(1)
  if startupTag != NullTagId:
    let pinnedTarget = model.tagHomeOutputTargets.getOrDefault(startupTag, "")
    if not model.tagHomeOutputPinned.contains(startupTag) or pinnedTarget.len == 0 or
        model.outputMatchesTarget(outputId, outputOpt.get(), pinnedTarget):
      tagId = startupTag
      result = model.setTagOutput(tagId, outputId) or result
      result = model.setOutputTag(outputId, tagId) or result
  if tagId == NullTagId:
    tagId = model.outputActiveTag(outputId)
  if tagId == NullTagId:
    for candidateTagId, mappedOutputId in model.tagOutputs.pairs:
      if mappedOutputId == outputId:
        tagId = candidateTagId
        break
  if tagId != NullTagId and model.tagData(tagId).isSome:
    result = model.setActiveWorkspace(tagId) or result

proc applyStartupOutputFocus*(model: var Model): bool =
  if model.outputStartupFocusResolved:
    return false
  for rule in model.outputRules:
    if rule.focusAtStartup and rule.target.len > 0:
      let outputId = model.outputForTarget(rule.target)
      if outputId != NullOutputId:
        result = model.focusStartupOutput(outputId)
        model.outputStartupFocusResolved = true
        return

proc syncConfiguredOutputState*(model: var Model, outputId: OutputId): bool =
  result = model.applyConfiguredOutputUsable(outputId)
  result = model.restoreWorkspaceOutputsFor(outputId)
  result = model.applyStartupOutputFocus() or result

proc syncPrimaryOutput*(model: var Model) =
  if model.outputsCount() == 0:
    model.primaryOutput = NullOutputId
    model.activeOutput = NullOutputId
    return

  if model.primaryOutput == NullOutputId or not model.hasOutput(model.primaryOutput):
    model.primaryOutput = model.sortedOutputIdsByExternal()[0]
  if model.activeOutput == NullOutputId or not model.hasOutput(model.activeOutput):
    model.activeOutput = model.primaryOutput

  let primary = model.output(model.primaryOutput)
  if primary.isSome and primary.get().w > 0 and primary.get().h > 0:
    discard model.setScreenSize(primary.get().w, primary.get().h)

proc upsertOutputForExternal*(
    model: var Model, externalId: ExternalOutputId
): OutputId =
  if externalId == NullExternalOutputId:
    return NullOutputId
  result = model.outputForExternal(externalId)
  if result == NullOutputId:
    result = model.addOutput(externalId)

proc setOutputDimensionsForExternal*(
    model: var Model, externalId: ExternalOutputId, w, h: int32
): bool =
  if externalId == NullExternalOutputId:
    return model.setScreenSize(w, h)

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputDimensions(outputId, w, h)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputNameForExternal*(
    model: var Model, externalId: ExternalOutputId, name: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputName(outputId, name.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputIdentityForExternal*(
    model: var Model, externalId: ExternalOutputId, make, modelName: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputIdentity(outputId, make.strip(), modelName.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputDescriptionForExternal*(
    model: var Model, externalId: ExternalOutputId, description: string
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputDescription(outputId, description.strip())
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputPositionForExternal*(
    model: var Model, externalId: ExternalOutputId, x, y: int32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputPosition(outputId, x, y)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputRefreshRateForExternal*(
    model: var Model, externalId: ExternalOutputId, refreshRate: int32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputRefreshRate(outputId, refreshRate)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputPhysicalMetadataForExternal*(
    model: var Model,
    externalId: ExternalOutputId,
    physicalWidth, physicalHeight, transform: int32,
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result =
    model.setOutputPhysicalMetadata(outputId, physicalWidth, physicalHeight, transform)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputScaleForExternal*(
    model: var Model, externalId: ExternalOutputId, scale: float32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputScale(outputId, scale)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc setOutputUsableForExternal*(
    model: var Model, externalId: ExternalOutputId, x, y, w, h: int32
): bool =
  if externalId == NullExternalOutputId:
    return false

  let outputId = model.upsertOutputForExternal(externalId)
  result = model.setOutputUsable(outputId, x, y, w, h)
  model.syncPrimaryOutput()
  discard model.syncPrimaryOutputTag()
  result = model.syncConfiguredOutputState(outputId) or result

proc removeOutputForExternal*(
    model: var Model, externalId: ExternalOutputId
): seq[WindowId] =
  if externalId == NullExternalOutputId:
    return
  let outputId = model.outputForExternal(externalId)
  if outputId == NullOutputId:
    return

  let outputOpt = model.outputData(outputId)
  if outputOpt.isSome:
    let target = model.outputStableTarget(outputId, outputOpt.get())
    let activeTag = model.outputActiveTag(outputId)
    let tagOpt = model.tagData(activeTag)
    if tagOpt.isSome:
      discard model.rememberOutputSlot(target, tagOpt.get().slot)

  var affectedTags: seq[TagId] = @[]
  for tagId, mappedOutput in model.tagOutputs.pairs:
    if mappedOutput == outputId:
      affectedTags.add(tagId)

  discard model.destroyOutput(outputId)
  model.syncPrimaryOutput()
  for tagId in affectedTags:
    if model.primaryOutput != NullOutputId:
      discard model.setTagOutput(tagId, model.primaryOutput)
  discard model.syncPrimaryOutputTag()

  for winId, win in model.windowsWithId():
    if win.isFullscreen and win.fullscreenOutput == externalId:
      discard model.setWindowFullscreen(winId, false)
      result.add(winId)

proc sortedOutputsByGeometry*(model: Model): seq[OutputId] =
  for outputId, _ in model.outputsWithId():
    result.add(outputId)
  result.sort(
    proc(a, b: OutputId): int =
      let aData = model.outputData(a).get()
      let bData = model.outputData(b).get()
      result = cmp(aData.y, bData.y)
      if result == 0:
        result = cmp(aData.x, bData.x)
      if result == 0:
        result = cmp(uint32(aData.externalId), uint32(bData.externalId))
  )

proc directionalOutput*(model: Model, direction: string): OutputId =
  let current = model.activeOutputOrPrimary()
  if current == NullOutputId:
    return NullOutputId

  let lower = direction.strip().toLowerAscii()
  if lower in ["next", "previous", "prev"]:
    let outputs = model.sortedOutputsByGeometry()
    let idx = outputs.find(current)
    if idx == -1 or outputs.len == 0:
      return NullOutputId
    let step = if lower == "next": 1 else: -1
    return outputs[(idx + step + outputs.len) mod outputs.len]

  let currentOpt = model.outputData(current)
  if currentOpt.isNone:
    return NullOutputId
  let currentData = currentOpt.get()
  let currentCx = int64(currentData.x) * 2'i64 + int64(currentData.w)
  let currentCy = int64(currentData.y) * 2'i64 + int64(currentData.h)

  var best = NullOutputId
  var bestPrimary = high(int64)
  var bestPerp = high(int64)
  for outputId, output in model.outputsWithId():
    if outputId == current:
      continue
    let cx = int64(output.x) * 2'i64 + int64(output.w)
    let cy = int64(output.y) * 2'i64 + int64(output.h)
    var primary: int64
    var perp: int64
    case lower
    of "left":
      if cx >= currentCx:
        continue
      primary = currentCx - cx
      perp = abs(currentCy - cy)
    of "right":
      if cx <= currentCx:
        continue
      primary = cx - currentCx
      perp = abs(currentCy - cy)
    of "up":
      if cy >= currentCy:
        continue
      primary = currentCy - cy
      perp = abs(currentCx - cx)
    of "down":
      if cy <= currentCy:
        continue
      primary = cy - currentCy
      perp = abs(currentCx - cx)
    else:
      return NullOutputId
    if primary < bestPrimary or (primary == bestPrimary and perp < bestPerp):
      best = outputId
      bestPrimary = primary
      bestPerp = perp
  best

proc resolveOutputTarget*(model: Model, target: string): OutputId =
  let named = model.outputForTarget(target)
  if named != NullOutputId:
    return named
  model.directionalOutput(target)

proc learnTagOutputFromActive*(model: var Model, tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  let outputId = model.activeOutputOrPrimary()
  let outputOpt = model.outputData(outputId)
  if outputOpt.isNone:
    return false
  result = model.setTagOutput(tagId, outputId)
  if not model.tagHomeOutputPinned.contains(tagId):
    result =
      model.setTagHomeOutput(
        tagId, model.outputStableTarget(outputId, outputOpt.get()), pinned = false
      ) or result
