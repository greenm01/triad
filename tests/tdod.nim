import algorithm, json, options, os, sequtils, strutils, tables
import unittest
import ../src/config/parser as config_parser
import ../src/core/effects
import ../src/core/msg as core_msg
import ../src/core/model_utils
import ../src/core/niri_state
import ../src/core/restore_state
import ../src/core/shell_state
import ../src/core/triad_state
import ../src/core/update as legacy_update
import ../src/entities/dod_ops
import ../src/state/dod_adapter
import ../src/state/entity_manager
import ../src/state/dod_invariants
import ../src/state/dod_iterators
import ../src/state/dod_queries
import ../src/state/dod_restore_state
import ../src/state/dod_snapshot
import ../src/state/id_gen
import ../src/ipc/niri_compat
import ../src/ipc/triad_native
import ../src/systems/dod_focus
import ../src/systems/dod_layout
import ../src/systems/dod_outputs
import ../src/systems/dod_placement
import ../src/systems/dod_scratchpad
import ../src/systems/dod_shadow_runtime as shadow_runtime
import ../src/systems/dod_update
import ../src/systems/dod_window_lifecycle
import ../src/systems/dod_window_state
import ../src/systems/dod_workspaces
import ../src/systems/layout_projection_sync
import ../src/systems/layout_state
import ../src/systems/projection_read_sync
import ../src/systems/runtime_update_sync
import ../src/systems/state_application_sync
import ../src/types/core
import ../src/types/dod_model
from ../src/types/legacy_model import nil

type
  TestEntity = object
    id*: WindowId
    value*: string

proc dodFocusHistory(dod: DodModel): seq[legacy_model.WindowId] =
  for winId in dod.focusHistory:
    let winOpt = dod.windowData(winId)
    if winOpt.isSome:
      result.add(legacy_model.WindowId(uint32(winOpt.get().externalId)))

proc dodWorkspaceHistory(dod: DodModel): seq[uint32] =
  for tagId in dod.workspaceHistory:
    let tagOpt = dod.tagData(tagId)
    if tagOpt.isSome:
      result.add(tagOpt.get().slot)

proc dodPointerWindow(dod: DodModel): legacy_model.WindowId =
  let winOpt = dod.windowData(dod.pointerOp.windowId)
  if winOpt.isSome:
    return legacy_model.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc checkRuntimeParity(source: legacy_model.Model; dod: DodModel) =
  check dod.layerFocusExclusive == source.layerFocusExclusive
  check dod.sessionLocked == source.sessionLocked
  check dod.activeModifiers == source.activeModifiers
  check dod.outerGaps == source.outerGaps
  check dod.innerGaps == source.innerGaps
  check dod.previousOuterGaps == source.previousOuterGaps
  check dod.previousInnerGaps == source.previousInnerGaps
  check dod.borderWidth == source.borderWidth
  check dod.focusedBorderColor == source.focusedBorderColor
  check dod.unfocusedBorderColor == source.unfocusedBorderColor
  check dod.enableAnimations == source.enableAnimations
  check dod.animationSpeed == source.animationSpeed
  check dod.startupCommands == source.startupCommands
  check dod.quickshell == source.quickshell
  check dod.terminal == source.terminal
  check dod.screenshot == source.screenshot
  check dod.cursor == source.cursor
  check dod.presentationMode == source.presentationMode
  check dod.protocolSurfaces == source.protocolSurfaces
  check dod.keyBindings == source.keyBindings
  check dod.pointerBindings == source.pointerBindings
  check dod.screenLockCommand == source.screenLock.command
  check dod.windowMenuCommand == source.windowMenu.command
  check dod.allowExitSession == source.allowExitSession
  check dod.nextGroupId == source.nextGroupId
  check dod.pointerOp.kind == source.pointerOp.kind
  check dod.dodPointerWindow() == source.pointerOp.windowId
  check dod.pointerOp.initialGeom == source.pointerOp.initialGeom
  check dod.pointerOp.edges == source.pointerOp.edges

proc checkDodParity(source: legacy_model.Model): DodModel =
  result = source.dodFromLegacy()
  check result.validateInvariants().ok

  let legacySnapshot = shellSnapshot(source)
  let dodSnapshot = dodShellSnapshot(result)

  check dodSnapshot == legacySnapshot
  check triadStateJson(dodSnapshot) == triadStateJson(legacySnapshot)
  check triadLayoutStateJson(dodSnapshot) ==
    triadLayoutStateJson(legacySnapshot)
  check niriWorkspacesJson(dodSnapshot) == niriWorkspacesJson(legacySnapshot)
  check niriWindowsJson(dodSnapshot) == niriWindowsJson(legacySnapshot)
  check niriOutputsJson(dodSnapshot) == niriOutputsJson(legacySnapshot)
  check niriOverviewJson(dodSnapshot) == niriOverviewJson(legacySnapshot)
  check result.dodFocusHistory() == source.focusHistory
  check result.dodWorkspaceHistory() == source.workspaceHistory
  checkRuntimeParity(source, result)

proc checkLayoutParity(source: legacy_model.Model) =
  var legacyModel = source
  var dod = source.dodFromLegacy()

  check dod.validateInvariants().ok
  check legacyModel.layoutInstructions() == dod.dodLayoutInstructions()

  let legacySnapshot = shellSnapshot(legacyModel)
  let dodSnapshot = dodShellSnapshot(dod)
  check dodSnapshot == legacySnapshot

proc checkLayoutProjectionParity(source: legacy_model.Model) =
  var legacyBefore = source
  let legacyProjection = legacyBefore.layoutProjection()
  check legacyBefore == source

  var dodBefore = source.dodFromLegacy()
  let dodOriginal = dodBefore
  let dodProjection = dodBefore.layoutProjection()
  check dodBefore == dodOriginal

  check dodProjection.instructions == legacyProjection.instructions
  check dodProjection.viewportTargets == legacyProjection.viewportTargets

  var legacyApplied = source
  var dodApplied = source.dodFromLegacy()
  legacyApplied.applyLayoutProjection(legacyProjection)
  dodApplied.applyLayoutProjection(dodProjection)
  check dodShellSnapshot(dodApplied) == shellSnapshot(legacyApplied)

proc checkLayoutProjectionSync(source: legacy_model.Model) =
  var legacyModel = source
  var dod = source.dodFromLegacy()

  var expectedLegacy = source
  let expectedInstructions = expectedLegacy.layoutInstructions()

  let report = syncLayoutProjection(legacyModel, dod, syncShadow = true)
  check report.ok
  check report.shadowChecked
  check report.authority == LegacyLayoutAuthority
  check report.legacyProjection.instructions == expectedInstructions
  check report.authoritativeProjection.instructions ==
    report.legacyProjection.instructions
  check report.dodProjection.instructions == report.legacyProjection.instructions
  check report.dodProjection.viewportTargets ==
    report.legacyProjection.viewportTargets
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check shellSnapshot(legacyModel) == shellSnapshot(expectedLegacy)

proc checkFocusParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory
  checkRuntimeParity(legacyModel, dod)

proc checkPlacementParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory
  checkRuntimeParity(legacyModel, dod)

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc checkStateParity(
    source: legacy_model.Model; msg: core_msg.Msg;
    action: proc(dod: var DodModel)) =
  let (legacyModel, _) = legacy_update.update(source, msg)
  var dod = source.dodFromLegacy()

  action(dod)
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory
  checkRuntimeParity(legacyModel, dod)

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc checkReducerParity(source: legacy_model.Model; msg: core_msg.Msg):
    tuple[dod: DodModel, effects: seq[Effect]] =
  let (legacyModel, _) = legacy_update.update(source, msg)
  let (dodModel, dodEffects) = source.dodFromLegacy().dodUpdate(msg)
  var dod = dodModel
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory
  checkRuntimeParity(legacyModel, dod)

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()
  (dod, dodEffects)

proc containsEffect(effects: seq[Effect]; kind: EffectKind): bool =
  for effect in effects:
    if effect.kind == kind:
      return true
  false

proc containsFocusEffect(effects: seq[Effect];
    winId: legacy_model.WindowId): bool =
  for effect in effects:
    if effect.kind == EffFocusWindow and effect.focusId == winId:
      return true
  false

proc containsCloseEffect(effects: seq[Effect];
    winId: legacy_model.WindowId): bool =
  for effect in effects:
    if effect.kind == EffCloseWindow and effect.closeId == winId:
      return true
  false

proc containsFullscreenEffect(effects: seq[Effect];
    winId: legacy_model.WindowId; fullscreen: bool; outputId = 0'u32): bool =
  for effect in effects:
    if effect.kind == EffSetFullscreen and effect.fsWinId == winId and
        effect.isFullscreen == fullscreen and
        (not fullscreen or effect.fsOutputId == outputId):
      return true
  false

proc effectSignature(effect: Effect; msg: core_msg.Msg): string =
  case effect.kind
  of EffBroadcastJson, EffBroadcastTriadJson, EffManageDirty, EffLog, EffNone:
    ""
  of EffFocusWindow:
    ""
  of EffSetPosition:
    $effect.kind & ":" & $effect.windowId & ":" & $effect.x & ":" &
      $effect.y & ":" & $effect.w & ":" & $effect.h
  of EffFocusShellSurface:
    $effect.kind & ":" & $effect.focusShellSurfaceId
  of EffCloseWindow:
    $effect.kind & ":" & $effect.closeId
  of EffOpStartPointer:
    $effect.kind
  of EffOpEnd:
    $effect.kind
  of EffSetFullscreen:
    $effect.kind & ":" & $effect.fsWinId & ":" & $effect.isFullscreen &
      ":" & $effect.fsOutputId
  of EffSetMaximized:
    $effect.kind & ":" & $effect.maxWinId & ":" & $effect.isMaximized
  of EffInformResizeStart, EffInformResizeEnd:
    $effect.kind & ":" & $effect.resizeLifecycleWinId
  of EffSpawnScreenLock:
    $effect.kind & ":" & effect.screenLockCommand.join("\0")
  of EffSpawnWindowMenu:
    $effect.kind & ":" & effect.windowMenuCommand.join("\0") & ":" &
      $effect.windowMenuId & ":" & $effect.windowMenuX & ":" &
      $effect.windowMenuY
  of EffSpawn:
    $effect.kind & ":" & effect.spawnCommand.join("\0")
  of EffPointerWarp:
    $effect.kind & ":" & $effect.warpX & ":" & $effect.warpY
  of EffScreenshot:
    $effect.kind & ":" & $effect.screenshotKind & ":" &
      effect.screenshotPath & ":" & $effect.screenshotShowPointer
  else:
    $effect.kind

proc stableEffectSignatures(
    effects: seq[Effect]; msg: core_msg.Msg): seq[string] =
  for effect in effects:
    let signature = effect.effectSignature(msg)
    if signature.len > 0:
      result.add(signature)
  result.sort()

proc checkEffectParity(
    msg: core_msg.Msg; legacyEffects, dodEffects: seq[Effect]) =
  check dodEffects.stableEffectSignatures(msg) ==
    legacyEffects.stableEffectSignatures(msg)

proc checkRuntimeUpdateSync(source: legacy_model.Model; msg: core_msg.Msg) =
  var legacyModel = source
  var shadow = source.dodFromLegacy()
  let (_, expectedEffects) = legacy_update.update(source, msg)

  let result = syncRuntimeUpdate(
    legacyModel, shadow, msg, syncShadow = true)
  check result.shadowChecked
  check result.shadowReport.ok
  check result.authority == LegacyRuntimeAuthority
  check result.legacyEffects.stableEffectSignatures(msg) ==
    expectedEffects.stableEffectSignatures(msg)
  check result.authoritativeEffects.stableEffectSignatures(msg) ==
    expectedEffects.stableEffectSignatures(msg)
  check result.dodEffects.stableEffectSignatures(msg) ==
    expectedEffects.stableEffectSignatures(msg)
  check result.shadowReport.dodEffects.stableEffectSignatures(msg) ==
    expectedEffects.stableEffectSignatures(msg)
  check dodShellSnapshot(shadow) == shellSnapshot(legacyModel)

proc checkShadowStateParity(legacyModel: legacy_model.Model; dod: DodModel) =
  var checkedDod = dod
  checkedDod.refreshVisibleWorkspaceSlots()

  check checkedDod.validateInvariants().ok
  check dodShellSnapshot(checkedDod) == shellSnapshot(legacyModel)
  check checkedDod.dodFocusHistory() == legacyModel.focusHistory
  check checkedDod.dodWorkspaceHistory() == legacyModel.workspaceHistory
  checkRuntimeParity(legacyModel, checkedDod)

  var legacyLayout = legacyModel
  var dodLayout = checkedDod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc checkShadowTrace(
    seed: legacy_model.Model; messages: openArray[core_msg.Msg]) =
  var legacyModel = seed
  var dod = seed.dodFromLegacy()

  checkShadowStateParity(legacyModel, dod)
  for msg in messages:
    var legacyEffects: seq[Effect]
    (legacyModel, legacyEffects) = legacy_update.update(legacyModel, msg)
    let (nextDod, dodEffects) = dod.dodUpdate(msg)
    dod = nextDod

    checkShadowStateParity(legacyModel, dod)
    checkEffectParity(msg, legacyEffects, dodEffects)

proc checkShadowTraceAfterRestore(
    seed: legacy_model.Model; restored: LiveRestoreState;
    messages: openArray[core_msg.Msg]) =
  var legacyModel = seed
  legacyModel.applyLiveRestore(restored)

  var dod = seed.dodFromLegacy()
  dod.applyLiveRestore(restored.dodFromLiveRestore())

  checkShadowStateParity(legacyModel, dod)
  for msg in messages:
    var legacyEffects: seq[Effect]
    (legacyModel, legacyEffects) = legacy_update.update(legacyModel, msg)
    let (nextDod, dodEffects) = dod.dodUpdate(msg)
    dod = nextDod

    checkShadowStateParity(legacyModel, dod)
    checkEffectParity(msg, legacyEffects, dodEffects)

proc checkNiriIpcParity(source: legacy_model.Model; line: string) =
  let legacy = handleNiriRequest(line, shellSnapshot(source))
  let dod = handleNiriRequest(line, dodShellSnapshot(source.dodFromLegacy()))

  check dod.handled == legacy.handled
  check dod.subscribe == legacy.subscribe
  check dod.reply == legacy.reply
  check dod.initialEvents == legacy.initialEvents
  check dod.messages.mapIt($it) == legacy.messages.mapIt($it)

proc checkTriadIpcParity(source: legacy_model.Model; line: string) =
  let legacy = handleTriadRequest(line, shellSnapshot(source))
  let dod = handleTriadRequest(line, dodShellSnapshot(source.dodFromLegacy()))

  check dod.handled == legacy.handled
  check dod.subscribeLayout == legacy.subscribeLayout
  check dod.subscribeState == legacy.subscribeState
  check dod.reply == legacy.reply
  check dod.initialEvents == legacy.initialEvents
  check dod.messages.mapIt($it) == legacy.messages.mapIt($it)

proc checkProjectionParity(
    legacySnapshot, dodSnapshot: ShellSnapshot) =
  check dodSnapshot == legacySnapshot
  check initialNiriEvents(dodSnapshot) == initialNiriEvents(legacySnapshot)

  for line in [
    "\"Workspaces\"",
    "\"Windows\"",
    "\"FocusedWindow\"",
    "\"OverviewState\"",
    "\"EventStream\"",
    """{"Action":{"FocusWorkspaceDown":{}}}"""
  ]:
    let legacy = handleNiriRequest(line, legacySnapshot)
    let dod = handleNiriRequest(line, dodSnapshot)
    check dod.handled == legacy.handled
    check dod.subscribe == legacy.subscribe
    check dod.reply == legacy.reply
    check dod.initialEvents == legacy.initialEvents
    check dod.messages.mapIt($it) == legacy.messages.mapIt($it)

  for line in [
    """{"triad":{"version":1,"request":"state"}}""",
    """{"triad":{"version":1,"request":"layout-state"}}""",
    """{"triad":{"version":1,"request":"event-stream","events":["layout","state"]}}"""
  ]:
    let legacy = handleTriadRequest(line, legacySnapshot)
    let dod = handleTriadRequest(line, dodSnapshot)
    check dod.handled == legacy.handled
    check dod.subscribeLayout == legacy.subscribeLayout
    check dod.subscribeState == legacy.subscribeState
    check dod.reply == legacy.reply
    check dod.initialEvents == legacy.initialEvents
    check dod.messages.mapIt($it) == legacy.messages.mapIt($it)

proc checkShadowReadProjectionTrace(
    seed: legacy_model.Model; messages: openArray[core_msg.Msg]) =
  var legacyModel = seed
  var dod = seed.dodFromLegacy()

  for msg in messages:
    var legacyEffects: seq[Effect]
    (legacyModel, legacyEffects) = legacy_update.update(legacyModel, msg)
    let (nextDod, dodEffects) = dod.dodUpdate(msg)
    dod = nextDod
    checkEffectParity(msg, legacyEffects, dodEffects)

  checkShadowStateParity(legacyModel, dod)
  checkProjectionParity(shellSnapshot(legacyModel), dodShellSnapshot(dod))
  check parseJson(dodLiveRestoreJson(dod)) == parseJson(liveRestoreJson(legacyModel))

proc checkShadowReadProjectionAfterRestore(
    seed: legacy_model.Model; restored: LiveRestoreState;
    messages: openArray[core_msg.Msg]) =
  var legacyModel = seed
  legacyModel.applyLiveRestore(restored)

  var dod = seed.dodFromLegacy()
  dod.applyLiveRestore(restored.dodFromLiveRestore())

  for msg in messages:
    var legacyEffects: seq[Effect]
    (legacyModel, legacyEffects) = legacy_update.update(legacyModel, msg)
    let (nextDod, dodEffects) = dod.dodUpdate(msg)
    dod = nextDod
    checkEffectParity(msg, legacyEffects, dodEffects)

  checkShadowStateParity(legacyModel, dod)
  checkProjectionParity(shellSnapshot(legacyModel), dodShellSnapshot(dod))
  check parseJson(dodLiveRestoreJson(dod)) == parseJson(liveRestoreJson(legacyModel))

proc checkDodLiveRestoreJsonParity(source: legacy_model.Model) =
  let legacyJson = parseJson(liveRestoreJson(source))
  let dodJson = parseJson(dodLiveRestoreJson(source.dodFromLegacy()))
  check dodJson == legacyJson

proc checkRestoredStateParity(
    legacyModel: legacy_model.Model; dod: var DodModel) =
  dod.refreshVisibleWorkspaceSlots()

  check dod.validateInvariants().ok
  check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
  check dod.dodFocusHistory() == legacyModel.focusHistory
  check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory

  var legacyLayout = legacyModel
  var dodLayout = dod
  check legacyLayout.layoutInstructions() == dodLayout.dodLayoutInstructions()

proc baseParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1920,
    screenHeight: 1080,
    overviewActive: true
  )
  result.workspaces.defaultCount = 3
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.Grid, legacy_model.Monocle
  ]
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Grid, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.8))
  result.tags[2].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10,
    appId: "kitty",
    title: "Terminal",
    widthProportion: 0.5,
    heightProportion: 1.0,
    actualW: 900,
    actualH: 1000
  )
  result.windows[20] = legacy_model.WindowData(
    id: 20,
    appId: "brave",
    title: "Browser",
    widthProportion: 0.8,
    heightProportion: 1.0,
    isMaximized: true
  )
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1920, h: 1080)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, x: 1920, y: 0, w: 1920, h: 1080)
  result.primaryOutput = 42
  result.outputTags[43] = 2
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc dynamicParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 9,
    screenWidth: 2560,
    screenHeight: 1440
  )
  result.workspaces.defaultCount = 3
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.MasterStack,
    legacy_model.VerticalGrid
  ]
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[2] = initTagState(2, legacy_model.VerticalScroller, "web")
  result.tags[3] = initTagState(3, legacy_model.Grid, "files")
  result.tags[9] = initTagState(9, legacy_model.Deck, "media")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.7))
  result.tags[2].focusedWindow = 20
  result.tags[9].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(90)], widthProportion: 0.35))
  result.tags[9].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(91)], widthProportion: 0.9))
  result.tags[9].focusedWindow = 91
  result.tags[9].targetViewportXOffset = 128.0'f32
  result.tags[9].currentViewportXOffset = 64.0'f32
  result.tags[9].targetViewportYOffset = 42.0'f32
  result.tags[9].currentViewportYOffset = 21.0'f32
  result.tags[9].masterCount = 2
  result.tags[9].masterSplitRatio = 0.65'f32

  result.windows[20] = legacy_model.WindowData(
    id: 20,
    appId: "brave",
    title: "Docs",
    widthProportion: 0.7,
    heightProportion: 1.0,
    isMinimized: true
  )
  result.windows[90] = legacy_model.WindowData(
    id: 90,
    appId: "mpv",
    title: "Video",
    widthProportion: 0.35,
    heightProportion: 0.8,
    isFullscreen: true,
    fullscreenOutput: 43,
    actualW: 1280,
    actualH: 720
  )
  result.windows[91] = legacy_model.WindowData(
    id: 91,
    appId: "kitty",
    title: "Mixer",
    widthProportion: 0.9,
    heightProportion: 1.0,
    isFloating: true,
    isMaximized: true,
    floatingGeom: legacy_model.Rect(x: 40, y: 50, w: 900, h: 700),
    keyboardShortcutsInhibit: true
  )
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1280, h: 720)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, name: "HDMI-A-1", x: 1280, y: 0, w: 1280, h: 720)
  result.primaryOutput = 42
  result.outputTags[43] = 9
  result.focusHistory = @[legacy_model.WindowId(20), 90, 91]
  result.workspaceHistory = @[1'u32, 2, 9]

proc tiledLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800,
    outerGaps: 20,
    innerGaps: 10
  )
  result.tags[1] = initTagState(1, legacy_model.MasterStack, "main")
  result.tags[1].masterCount = 1
  result.tags[1].masterSplitRatio = 0.6'f32
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "term", title: "term")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "web", title: "web")

proc scrollerLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1000,
    screenHeight: 700,
    outerGaps: 10,
    innerGaps: 8,
    scrollerFocusCenter: true,
    centerFocusedColumn: "always"
  )
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10, heightProportion: 1.0)
  result.windows[20] = legacy_model.WindowData(
    id: 20, heightProportion: 1.0)

proc floatingLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.windows[20].isFloating = true
  result.windows[20].floatingGeom =
    legacy_model.Rect(x: 100, y: 120, w: 500, h: 360)

proc maximizedLayoutModel(): legacy_model.Model =
  result = floatingLayoutModel()
  result.tags[1].focusedWindow = 20
  result.windows[20].isMaximized = true

proc overviewLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.overviewActive = true
  result.overview.outerGap = 18
  result.overview.innerGapMultiplier = 2.0'f32
  result.tags[2] = initTagState(2, legacy_model.Grid, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(30)], widthProportion: 1.0))
  result.windows[30] = legacy_model.WindowData(
    id: 30, appId: "chat", title: "chat")

proc smartGapLayoutModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1000,
    screenHeight: 700,
    outerGaps: 30,
    innerGaps: 20,
    smartGaps: true
  )
  result.tags[1] = initTagState(1, legacy_model.Grid, "single")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 1.0))
  result.tags[1].focusedWindow = 10
  result.windows[10] = legacy_model.WindowData(id: 10)

proc usableOutputLayoutModel(): legacy_model.Model =
  result = tiledLayoutModel()
  result.screenWidth = 3000
  result.screenHeight = 2000
  result.outputs[42] = legacy_model.OutputData(
    id: 42,
    x: 0,
    y: 0,
    w: 2560,
    h: 1440,
    usableX: 10,
    usableY: 20,
    usableW: 1200,
    usableH: 700,
    hasUsable: true)
  result.primaryOutput = 42

proc focusParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[
      legacy_model.WindowId(10),
      legacy_model.WindowId(11)
    ],
    widthProportion: 0.5))
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(12)], widthProportion: 0.5))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.75))
  result.tags[2].focusedWindow = 20
  result.tags[3] = initTagState(3, legacy_model.Grid, "files")
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "term", title: "one")
  result.windows[11] = legacy_model.WindowData(
    id: 11, appId: "term", title: "two")
  result.windows[12] = legacy_model.WindowData(
    id: 12, appId: "term", title: "three")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "web", title: "browser")
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc minimizedFocusModel(): legacy_model.Model =
  result = focusParityModel()
  result.activeTag = 1
  result.windows[20].isMinimized = true

proc trailingWorkspaceFocusModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 3,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[1] = initTagState(1, legacy_model.Scroller, "term")
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[3] = initTagState(3, legacy_model.Scroller, "files")
  result.tags[3].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(30)], widthProportion: 0.5))
  result.tags[3].focusedWindow = 30
  result.windows[30] = legacy_model.WindowData(
    id: 30, appId: "files", title: "files")
  result.focusHistory = @[legacy_model.WindowId(30)]
  result.workspaceHistory = @[3'u32]

proc closedFocusedWindowModel(): legacy_model.Model =
  result = focusParityModel()
  result.activeTag = 2
  result.tags[2].focusedWindow = 20
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc placementParityModel(): legacy_model.Model =
  result = focusParityModel()
  result.layoutCycle = @[
    legacy_model.Scroller, legacy_model.MasterStack, legacy_model.Grid
  ]
  result.defaultColumnWidth = 0.7'f32
  result.tags[1].layoutMode = legacy_model.Scroller
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(13)], widthProportion: 0.6))
  result.windows[13] = legacy_model.WindowData(
    id: 13, appId: "term", title: "four")

proc focusWindowInPlacementModel(winId: legacy_model.WindowId):
    legacy_model.Model =
  result = placementParityModel()
  result.tags[1].focusedWindow = winId
  result.focusHistory = @[legacy_model.WindowId(10), 20, winId]

proc activeSecondPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.activeTag = 2
  result.tags[2].focusedWindow = 20
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc masterPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.tags[1].layoutMode = legacy_model.MasterStack
  result.tags[1].masterCount = 1
  result.tags[1].masterSplitRatio = 0.5'f32

proc verticalPlacementModel(): legacy_model.Model =
  result = placementParityModel()
  result.tags[1].layoutMode = legacy_model.VerticalScroller
  result.windows[10].widthProportion = 0.5'f32

proc stateParityModel(): legacy_model.Model =
  result = placementParityModel()
  result.screenWidth = 1200
  result.screenHeight = 800
  result.floating.xRatio = 0.1'f32
  result.floating.yRatio = 0.2'f32
  result.floating.widthRatio = 0.4'f32
  result.floating.heightRatio = 0.3'f32
  result.floating.minWidth = 80
  result.floating.minHeight = 90
  result.outputs[42] = legacy_model.OutputData(
    id: 42, name: "DP-1", x: 0, y: 0, w: 1200, h: 800)
  result.outputs[43] = legacy_model.OutputData(
    id: 43, name: "HDMI-A-1", x: 1200, y: 0, w: 1000, h: 700)
  result.primaryOutput = 42
  result.outputTags[42] = 1
  result.outputTags[43] = 2
  result.tags[1].focusedWindow = 10

proc floatingRuntimeModel(): legacy_model.Model =
  result = stateParityModel()
  result.windows[10].isFloating = true
  result.windows[10].floatingGeom =
    legacy_model.Rect(x: 100, y: 120, w: 500, h: 360)
  result.floating.minWidth = 80
  result.floating.minHeight = 90

proc pointerRuntimeModel(kind: legacy_model.PointerOpKind):
    legacy_model.Model =
  result = floatingRuntimeModel()
  result.pointerOp = legacy_model.PointerOpState(
    kind: kind,
    windowId: 10,
    initialGeom: result.windows[10].floatingGeom,
    edges: 8
  )

proc animationRuntimeModel(): legacy_model.Model =
  result = stateParityModel()
  result.enableAnimations = true
  result.animationSpeed = 0.2'f32
  result.tags[1].targetViewportXOffset = 100.0'f32
  result.tags[1].currentViewportXOffset = 0.0'f32
  result.tags[1].targetViewportYOffset = 50.0'f32
  result.tags[1].currentViewportYOffset = 0.0'f32

proc effectRuntimeModel(): legacy_model.Model =
  result = stateParityModel()
  result.screenLock.command = @["lockme", "--dev-mode"]
  result.windowMenu.command = @["menu-tool", "--quiet"]
  result.allowExitSession = true

proc scratchpadParityModel(visible = false; named = false):
    legacy_model.Model =
  result = stateParityModel()
  discard result.tags[1].removeWindow(10)
  result.tags[1].focusedWindow = 11
  result.scratchpadWindows = @[legacy_model.WindowId(10)]
  result.scratchpadWidthRatio = 0.8'f32
  result.scratchpadHeightRatio = 0.9'f32
  if named:
    result.namedScratchpads["terminal"] = 10
  if visible:
    result.visibleScratchpad = 10
    result.isScratchpadVisible = true

proc fullscreenOutputStateModel(): legacy_model.Model =
  result = stateParityModel()
  result.windows[10].isFullscreen = true
  result.windows[10].fullscreenOutput = 43

proc lifecycleParityModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 1,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.defaultColumnWidth = 0.6'f32
  result.defaultWindowWidth = 0.7'f32
  result.defaultWindowHeight = 0.8'f32
  result.defaultMasterCount = 2
  result.defaultMasterRatio = 0.65'f32
  result.tags[1] = initTagState(1, legacy_model.Scroller, "main")
  result.tags[1].masterCount = 2
  result.tags[1].masterSplitRatio = 0.65'f32
  result.tags[1].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(10)], widthProportion: 0.6))
  result.tags[1].focusedWindow = 10
  result.tags[2] = initTagState(2, legacy_model.Scroller, "web")
  result.tags[2].masterCount = 2
  result.tags[2].masterSplitRatio = 0.65'f32
  result.tags[2].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(20)], widthProportion: 0.6))
  result.tags[2].focusedWindow = 20
  result.windows[10] = legacy_model.WindowData(
    id: 10, appId: "foot", title: "one")
  result.windows[20] = legacy_model.WindowData(
    id: 20, appId: "brave", title: "web")
  result.focusHistory = @[legacy_model.WindowId(10), 20]
  result.workspaceHistory = @[1'u32, 2]

proc lifecycleFallbackModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 0,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3

proc lifecycleRuleModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.floating.xRatio = 0.1'f32
  result.floating.yRatio = 0.2'f32
  result.floating.widthRatio = 0.4'f32
  result.floating.heightRatio = 0.3'f32
  result.tagRules.add(legacy_model.TagRule(
    tagId: 4,
    name: "chat",
    defaultLayout: legacy_model.MasterStack
  ))
  result.windowRules.add(legacy_model.WindowRule(
    appIdMatch: "discord",
    defaultTag: 4,
    openFloating: true,
    keyboardShortcutsInhibit: true,
    forcedLayout: ord(legacy_model.Grid) + 1
  ))

proc lifecycleTagRuleModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.tagRules.add(legacy_model.TagRule(
    tagId: 5,
    name: "media",
    defaultLayout: legacy_model.Deck
  ))
  result.windowRules.add(legacy_model.WindowRule(
    appIdMatch: "mpv",
    defaultTag: 5
  ))

proc lifecycleDuplicateModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.activeTag = 1
  result.tags[2].columns[0].windows.add(legacy_model.WindowId(10))
  result.tags[2].focusedWindow = 10

proc lifecycleDynamicDestroyModel(): legacy_model.Model =
  result = lifecycleParityModel()
  result.activeTag = 4
  result.tags[4] = initTagState(4, legacy_model.Scroller, "temp")
  result.tags[4].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(40)], widthProportion: 0.6))
  result.tags[4].focusedWindow = 40
  result.windows[40] = legacy_model.WindowData(
    id: 40, appId: "scratch", title: "temp")
  result.focusHistory = @[legacy_model.WindowId(10), 40]

proc lifecycleCollapseDestroyModel(): legacy_model.Model =
  result = legacy_model.Model(
    activeTag: 4,
    screenWidth: 1200,
    screenHeight: 800
  )
  result.workspaces.defaultCount = 3
  result.tags[4] = initTagState(4, legacy_model.Scroller, "temp")
  result.tags[4].columns.add(legacy_model.Column(
    windows: @[legacy_model.WindowId(40)], widthProportion: 0.5))
  result.tags[4].focusedWindow = 40
  result.windows[40] = legacy_model.WindowData(
    id: 40, appId: "scratch", title: "temp")

suite "DOD state primitives":
  test "DOD systems stay behind state engine facade":
    var checkedFiles: seq[string] = @[]
    for path in walkFiles("src/systems/dod_*.nim"):
      checkedFiles.add(path)
    checkedFiles.add("src/config/dod_apply.nim")

    let forbiddenImports = [
      "../state/dod_invariants",
      "../state/dod_iterators",
      "../state/dod_queries",
      "../state/dod_snapshot",
      "../state/entity_manager"
    ]
    let forbiddenStorage = [
      ".data",
      ".index",
      ".entity(",
      ".mEntity("
    ]

    check checkedFiles.len > 0
    for path in checkedFiles:
      let source = readFile(path)
      for pattern in forbiddenImports:
        check not source.contains(pattern)
      for pattern in forbiddenStorage:
        check not source.contains(pattern)

  test "DOD update orchestrates domain reducers only":
    let source = readFile("src/systems/dod_update.nim")
    let forbiddenImports = [
      "import dod_focus",
      "import dod_outputs",
      "import dod_placement",
      "import dod_runtime",
      "import dod_scratchpad",
      "import dod_window_lifecycle",
      "import dod_window_state",
      "import dod_workspaces"
    ]

    for pattern in forbiddenImports:
      check not source.contains(pattern)
    check source.contains("import dod_update_commands")
    check source.contains("import dod_update_events")
    check source.contains("import dod_update_effects")

  test "logical IDs are monotonic and reserve zero":
    var counters = IdCounters()

    let firstWindow = counters.generateWindowId()
    let secondWindow = counters.generateWindowId()
    let firstTag = counters.generateTagId()

    check firstWindow == WindowId(1)
    check secondWindow == WindowId(2)
    check firstTag == TagId(1)
    check firstWindow != NullWindowId
    check firstTag != NullTagId

  test "entity manager adds, updates, and deletes densely":
    var manager: EntityManager[WindowId, TestEntity]

    manager.insert(TestEntity(id: WindowId(1), value: "one"))
    manager.insert(TestEntity(id: WindowId(2), value: "two"))
    manager.insert(TestEntity(id: WindowId(3), value: "three"))

    check manager.len == 3
    check manager.contains(WindowId(2))
    manager.mEntity(WindowId(2)).value = "updated"
    check manager.entity(WindowId(2)).get().value == "updated"

    check manager.delete(WindowId(2))
    check manager.len == 2
    check not manager.contains(WindowId(2))
    check manager.contains(WindowId(3))
    check manager.entity(WindowId(3)).get().value == "three"
    check manager.hasDenseIndex()

  test "entity manager rejects duplicate IDs":
    var manager: EntityManager[WindowId, TestEntity]

    manager.insert(TestEntity(id: WindowId(1), value: "one"))

    expect ValueError:
      manager.insert(TestEntity(id: WindowId(1), value: "dupe"))

  test "tag masks are bounded and composable":
    var mask = EmptyTagMask
    let first = tagBit(1)
    let last = tagBit(MaxTagBits)

    check mask.isEmpty()
    mask.incl(first)
    check mask.contains(first)
    check not mask.contains(last)
    mask.incl(last)
    check mask.contains(last)
    mask.excl(first)
    check not mask.contains(first)
    check mask.contains(last)

    expect ValueError:
      discard tagBit(0)
    expect ValueError:
      discard tagBit(MaxTagBits + 1)

  test "DOD placement supports multi-tag windows and destroy cleanup":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tagOne = model.addTag(1, "one")
    let tagTwo = model.addTag(2, "two")
    let colOne = model.addColumn(tagOne, 0.5)
    let colTwo = model.addColumn(tagTwo, 0.75)
    let win = model.addWindow(
      ExternalWindowId(10), appId = "term", title = "Terminal")

    model.placeWindow(tagOne, colOne, win)
    model.placeWindow(tagTwo, colTwo, win)

    var tagOneWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tagOne):
      tagOneWindows.add(winId)
    var tagTwoWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tagTwo):
      tagTwoWindows.add(winId)
    var colOneWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnColumnWithId(colOne):
      colOneWindows.add(winId)
    var colTwoWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnColumnWithId(colTwo):
      colTwoWindows.add(winId)

    check model.windowTags[win].contains(tagBit(1))
    check model.windowTags[win].contains(tagBit(2))
    check tagOneWindows == @[win]
    check tagTwoWindows == @[win]
    check colOneWindows == @[win]
    check colTwoWindows == @[win]
    check model.placementForWindowOnTag(tagOne, win).get().windowIdx == 1
    check model.firstWindowPosition(win).slot == 1
    check model.validateInvariants().ok

    check model.destroyWindow(win)
    check not model.windows.contains(win)
    check not model.externalWindowIds.hasKey(ExternalWindowId(10))
    check model.tagHasLiveWindows(tagOne) == false
    check model.tagHasLiveWindows(tagTwo) == false
    check model.validateInvariants().ok

  test "DOD iterators skip dangling relationship rows":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tag = model.addTag(1, "one")
    let column = model.addColumn(tag, 0.5)
    let win = model.addWindow(ExternalWindowId(10), appId = "term")

    model.placeWindow(tag, column, win)
    check model.windows.delete(win)

    var yieldedWindows: seq[WindowId] = @[]
    for winId, _ in model.windowsOnTagWithId(tag):
      yieldedWindows.add(winId)

    check yieldedWindows.len == 0

  test "DOD queries sort shell-facing ids by external id":
    var model = DodModel(defaultWorkspaceCount: 3)
    let left = model.addOutput(ExternalOutputId(20), name = "left")
    let right = model.addOutput(ExternalOutputId(10), name = "right")
    let second = model.addWindow(ExternalWindowId(20), appId = "term")
    let first = model.addWindow(ExternalWindowId(10), appId = "browser")

    check model.sortedOutputIdsByExternal() == @[right, left]
    check model.sortedWindowIdsByExternal() == @[first, second]

  test "DOD invariants report broken relationship indexes":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tag = model.addTag(1, "one")
    discard model.addColumn(tag, 0.5)
    model.windowsByTag[tag].add(WindowId(999))

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(it.message.contains("missing window"))

  test "legacy adapter preserves shell snapshots and existing IPC ids":
    let dod = checkDodParity(baseParityModel())
    check uint32(dod.windows.entity(WindowId(1)).get().externalId) == 10
    check uint32(dod.windows.entity(WindowId(2)).get().externalId) == 20

    let dodSnapshot = dodShellSnapshot(dod)
    let windows = triadStateJson(dodSnapshot)["windows"]
    check windows[0]["id"].getInt() == 10
    check windows[1]["id"].getInt() == 20

  test "legacy adapter preserves dynamic workspace and output parity":
    let dod = checkDodParity(dynamicParityModel())
    let snapshot = dodShellSnapshot(dod)
    let workspaces = niriWorkspacesJson(snapshot)
    let windows = niriWindowsJson(snapshot)

    check workspaces.len == 5
    check workspaces[3]["id"].getInt() == 9
    check workspaces[4]["id"].getInt() == 10
    check windows[1]["is_fullscreen"].getBool()
    check windows[2]["is_floating"].getBool()
    check windows[2]["is_maximized"].getBool()

  test "DOD live restore serializer matches legacy JSON":
    checkDodLiveRestoreJsonParity(dynamicParityModel())
    checkDodLiveRestoreJsonParity(stateParityModel())
    checkDodLiveRestoreJsonParity(scratchpadParityModel(
      visible = true, named = true))

  test "DOD live restore JSON round trips through restore parser":
    var source = legacy_model.Model(activeTag: 1, screenWidth: 1200,
      screenHeight: 800)
    source.workspaces.defaultCount = 1
    source.tags[1] = initTagState(1, legacy_model.Scroller, "main")
    source.tags[1].columns.add(legacy_model.Column(
      windows: @[legacy_model.WindowId(10)], widthProportion: 0.7))
    source.tags[1].focusedWindow = 10
    source.windows[10] = legacy_model.WindowData(
      id: 10,
      appId: "kitty",
      title: "Terminal",
      widthProportion: 0.7,
      heightProportion: 1.0,
      isMaximized: true,
      actualW: 900,
      actualH: 700)
    source.workspaceHistory = @[1'u32]

    let parsed = parseLiveRestoreJson(dodLiveRestoreJson(source.dodFromLegacy()))
    check parsed.isSome

    var seed = legacy_model.Model(activeTag: 1, screenWidth: 1200,
      screenHeight: 800)
    seed.workspaces.defaultCount = 1

    checkShadowTraceAfterRestore(
      seed,
      parsed.get(),
      @[
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 10,
          appId: "kitty",
          title: "Terminal")
      ])

  test "DOD snapshot drives Niri IPC parity":
    let source = dynamicParityModel()
    checkNiriIpcParity(source, "\"Outputs\"")
    checkNiriIpcParity(source, "\"Workspaces\"")
    checkNiriIpcParity(source, "\"Windows\"")
    checkNiriIpcParity(source, "\"FocusedWindow\"")
    checkNiriIpcParity(source, "\"OverviewState\"")
    checkNiriIpcParity(source, "\"EventStream\"")
    checkNiriIpcParity(
      source,
      """{"Action":{"FocusWorkspace":{"reference":{"Index":2}}}}""")
    checkNiriIpcParity(
      source,
      """{"Action":{"FocusWorkspaceDown":{}}}""")
    checkNiriIpcParity(
      source,
      """{"Action":{"MaximizeWindowToEdges":{}}}""")

  test "DOD snapshot drives native Triad IPC parity":
    let source = dynamicParityModel()
    checkTriadIpcParity(
      source,
      """{"triad":{"version":1,"request":"state"}}""")
    checkTriadIpcParity(
      source,
      """{"triad":{"version":1,"request":"layout-state"}}""")
    checkTriadIpcParity(
      source,
      """{"triad":{"version":1,"request":"set-layout","layout":"grid","target":{"tag":9}}}""")
    checkTriadIpcParity(
      source,
      """{"triad":{"version":1,"request":"set-layout","layout":"monocle","target":{"workspace_idx":2}}}""")
    checkTriadIpcParity(
      source,
      """{"triad":{"version":1,"request":"event-stream","events":["layout","state"]}}""")

  test "DOD layout projection matches tiled legacy layout":
    checkLayoutParity(tiledLayoutModel())

  test "DOD layout projection matches scroller viewport updates":
    checkLayoutParity(scrollerLayoutModel())

  test "DOD explicit layout projection is pure and matches legacy":
    checkLayoutProjectionParity(tiledLayoutModel())
    checkLayoutProjectionParity(scrollerLayoutModel())
    checkLayoutProjectionParity(floatingLayoutModel())
    checkLayoutProjectionParity(maximizedLayoutModel())

  test "DOD explicit vertical scroller projection matches viewport writes":
    checkLayoutProjectionParity(dynamicParityModel())

  test "DOD runtime layout projection sync updates legacy and shadow":
    checkLayoutProjectionSync(scrollerLayoutModel())
    checkLayoutProjectionSync(dynamicParityModel())

  test "DOD runtime layout projection sync can select DOD projection":
    var legacyModel = scrollerLayoutModel()
    var dod = legacyModel.dodFromLegacy()

    let report = syncLayoutProjection(
      legacyModel,
      dod,
      syncShadow = true,
      authority = DodLayoutAuthority)
    check report.ok
    check report.shadowChecked
    check report.authority == DodLayoutAuthority
    check report.authoritativeProjection.instructions ==
      report.dodProjection.instructions
    check report.dodProjection.instructions ==
      report.legacyProjection.instructions
    check dodShellSnapshot(dod) == shellSnapshot(legacyModel)

  test "DOD runtime layout projection sync can skip shadow mutation":
    var legacyModel = scrollerLayoutModel()
    var dod = legacyModel.dodFromLegacy()
    let originalDod = dod

    let report = syncLayoutProjection(legacyModel, dod, syncShadow = false)
    check report.ok
    check not report.shadowChecked
    check dod == originalDod
    check report.legacyProjection.viewportTargets.len == 1
    check legacyModel.tags[1].targetViewportXOffset ==
      report.legacyProjection.viewportTargets[0].targetX
    check report.authoritativeProjection.instructions ==
      report.legacyProjection.instructions
    check report.dodProjection.instructions.len == 0

  test "DOD runtime layout projection authority runs without shadow checks":
    var legacyModel = scrollerLayoutModel()
    var dod = legacyModel.dodFromLegacy()

    let report = syncLayoutProjection(
      legacyModel,
      dod,
      syncShadow = false,
      authority = DodLayoutAuthority)
    check report.ok
    check not report.shadowChecked
    check report.authority == DodLayoutAuthority
    check report.dodProjection.instructions.len > 0
    check report.authoritativeProjection.instructions ==
      report.dodProjection.instructions

  test "DOD runtime layout projection sync reports mismatches":
    var legacyModel = scrollerLayoutModel()
    var dod = legacyModel.dodFromLegacy()
    dod.outerGaps = legacyModel.outerGaps + 17

    let report = syncLayoutProjection(legacyModel, dod, syncShadow = true)
    check not report.ok
    check report.shadowChecked
    check report.errors.contains("layout instructions mismatch")
    check report.legacyProjection.instructions == legacyModel.layoutProjection().instructions
    check report.authoritativeProjection.instructions ==
      report.legacyProjection.instructions

  test "DOD config application sync updates legacy and shadow":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    var config = config_parser.Config(
      layout: config_parser.LayoutConfig(
        gaps: 31,
        borderWidth: 4,
        defaultColumnWidth: 0.6,
        defaultWindowWidth: 0.7,
        defaultWindowHeight: 0.8,
        defaultMasterCount: 2,
        defaultMasterRatio: 0.65))
    config.workspaces.defaultCount = 3

    let report = syncConfigApplication(
      legacyModel, dod, config, syncShadow = true)
    check report.shadowChecked
    check report.shadowReport.ok
    check legacyModel.outerGaps == 31
    check dod.outerGaps == 31
    check dodShellSnapshot(dod) == shellSnapshot(legacyModel)

  test "DOD config application sync can skip shadow mutation":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    let originalDod = dod
    var config = config_parser.Config(
      layout: config_parser.LayoutConfig(
        gaps: 33,
        borderWidth: 5,
        defaultColumnWidth: 0.6,
        defaultWindowWidth: 0.7,
        defaultWindowHeight: 0.8,
        defaultMasterCount: 2,
        defaultMasterRatio: 0.65))
    config.workspaces.defaultCount = 3

    let report = syncConfigApplication(
      legacyModel, dod, config, syncShadow = false)
    check not report.shadowChecked
    check report.shadowReport.ok
    check legacyModel.outerGaps == 33
    check dod == originalDod

  test "DOD config application sync reports mismatches":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    dod.focusHistory = @[]
    var config = config_parser.Config(
      layout: config_parser.LayoutConfig(
        gaps: 35,
        borderWidth: 6,
        defaultColumnWidth: 0.6,
        defaultWindowWidth: 0.7,
        defaultWindowHeight: 0.8,
        defaultMasterCount: 2,
        defaultMasterRatio: 0.65))
    config.workspaces.defaultCount = 3

    let report = syncConfigApplication(
      legacyModel, dod, config, syncShadow = true)
    check report.shadowChecked
    check not report.shadowReport.ok
    check report.shadowReport.errors.contains("focus history mismatch")
    check legacyModel.outerGaps == 35

  test "DOD live restore application sync updates legacy and shadow":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    var restored = LiveRestoreState(activeTag: 2, focusedWindow: 20)
    restored.tagByWindow[20] = 2
    restored.focusHistory = @[20'u32]
    restored.workspaceHistory = @[2'u32]

    let report = syncLiveRestoreApplication(
      legacyModel, dod, restored, syncShadow = true)
    check report.shadowChecked
    check report.shadowReport.ok
    check legacyModel.activeTag == 2
    check dodShellSnapshot(dod) == shellSnapshot(legacyModel)

  test "DOD live restore application sync can skip shadow mutation":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    let originalDod = dod
    let restored = LiveRestoreState(activeTag: 2, focusedWindow: 20)

    let report = syncLiveRestoreApplication(
      legacyModel, dod, restored, syncShadow = false)
    check not report.shadowChecked
    check report.shadowReport.ok
    check legacyModel.activeTag == 2
    check dod == originalDod

  test "DOD live restore application sync reports mismatches":
    var legacyModel = lifecycleParityModel()
    var dod = legacyModel.dodFromLegacy()
    dod.outerGaps = legacyModel.outerGaps + 17
    let restored = LiveRestoreState(activeTag: 2, focusedWindow: 20)

    let report = syncLiveRestoreApplication(
      legacyModel, dod, restored, syncShadow = true)
    check report.shadowChecked
    check not report.shadowReport.ok
    check legacyModel.activeTag == 2

  test "DOD projection read bridge selects healthy shadow reads":
    check projectionReadSource(true, true) == DodProjectionSource
    check projectionReadSource(true, false) == LegacyProjectionSource
    check projectionReadSource(false, true) == LegacyProjectionSource
    check projectionReadSource(false, false) == LegacyProjectionSource

  test "DOD projection read bridge reads shell snapshots by source":
    let legacyModel = lifecycleParityModel()
    let dod = legacyModel.dodFromLegacy()

    check readProjectionSnapshot(
      legacyModel, dod, DodProjectionSource) == dodShellSnapshot(dod)
    check readProjectionSnapshot(
      legacyModel, dod, LegacyProjectionSource) == shellSnapshot(legacyModel)
    check readProjectionSnapshot(
      legacyModel, dod, DodProjectionSource) ==
      readProjectionSnapshot(legacyModel, dod, LegacyProjectionSource)

  test "DOD projection read bridge reads live restore JSON by source":
    let legacyModel = dynamicParityModel()
    let dod = legacyModel.dodFromLegacy()

    let dodJson = readProjectionLiveRestoreJson(
      legacyModel, dod, DodProjectionSource)
    let legacyJson = readProjectionLiveRestoreJson(
      legacyModel, dod, LegacyProjectionSource)
    check parseJson(dodJson) == parseJson(dodLiveRestoreJson(dod))
    check parseJson(legacyJson) == parseJson(liveRestoreJson(legacyModel))
    check parseJson(dodJson) == parseJson(legacyJson)

  test "DOD projection read bridge writes parseable live restore state":
    let legacyModel = lifecycleParityModel()
    let dod = legacyModel.dodFromLegacy()
    let path = getTempDir() / (
      "triad-projection-read-" & $getCurrentProcessId() & ".json")
    try:
      var result = writeProjectionLiveRestoreState(
        legacyModel, dod, DodProjectionSource, path)
      check result.ok
      check result.path == path
      check parseLiveRestoreJson(readFile(path)).isSome

      result = writeProjectionLiveRestoreState(
        legacyModel, dod, LegacyProjectionSource, path)
      check result.ok
      check result.path == path
      check parseLiveRestoreJson(readFile(path)).isSome
    finally:
      if fileExists(path):
        removeFile(path)

  test "DOD layout projection matches floating windows":
    checkLayoutParity(floatingLayoutModel())

  test "DOD layout projection matches fullscreen and maximized override":
    checkLayoutParity(maximizedLayoutModel())

  test "DOD layout projection matches overview grid":
    checkLayoutParity(overviewLayoutModel())

  test "DOD layout projection matches smart gaps":
    checkLayoutParity(smartGapLayoutModel())

  test "DOD layout projection matches usable output geometry":
    checkLayoutParity(usableOutputLayoutModel())

  test "DOD focus tag matches legacy focus behavior":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusTag, focusTag: 2),
      proc(dod: var DodModel) =
        discard dod.focusWorkspaceSlot(2)
    )

  test "DOD focus workspace index matches trailing workspace behavior":
    checkFocusParity(
      trailingWorkspaceFocusModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusWorkspaceIndex,
        workspaceIndex: 4),
      proc(dod: var DodModel) =
        discard dod.focusWorkspaceIndex(4)
    )

  test "DOD focus external window unminimizes like legacy":
    checkFocusParity(
      minimizedFocusModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusWindowById,
        focusWindowId: 20),
      proc(dod: var DodModel) =
        discard dod.focusExternalWindow(ExternalWindowId(20))
    )

  test "DOD focus cycle matches legacy next and previous":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusNext),
      proc(dod: var DodModel) =
        discard dod.focusCycle(1)
    )
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusPrev),
      proc(dod: var DodModel) =
        discard dod.focusCycle(-1)
    )

  test "DOD directional focus matches legacy columns":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusDirection,
        direction: legacy_model.DirRight),
      proc(dod: var DodModel) =
        discard dod.focusByDirection(legacy_model.DirRight)
    )

  test "DOD overview vertical focus matches legacy workspace navigation":
    checkFocusParity(
      overviewLayoutModel(),
      core_msg.Msg(
        kind: core_msg.CmdFocusDirection,
        direction: legacy_model.DirDown),
      proc(dod: var DodModel) =
        discard dod.focusByDirection(legacy_model.DirDown)
    )

  test "DOD focus last matches legacy focus history":
    checkFocusParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusLast),
      proc(dod: var DodModel) =
        discard dod.focusLast()
    )

  test "DOD focus fallback after close matches legacy history":
    checkFocusParity(
      closedFocusedWindowModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        let winId = dod.windowForExternal(ExternalWindowId(20))
        discard dod.destroyWindow(winId)
        if not dod.focusMostRecentWindow():
          discard dod.focusMostRecentWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )

  test "DOD dynamic workspace pruning matches legacy":
    var legacyState = trailingWorkspaceFocusModel()
    legacyState.tags[4] = initTagState(4, legacy_model.Scroller, "tail")
    legacyState.tags[5] = initTagState(5, legacy_model.Scroller, "stale")
    var dod = legacyState.dodFromLegacy()

    discard legacyState.pruneDynamicWorkspaces()
    discard dod.pruneDynamicWorkspaces()

    check dod.validateInvariants().ok
    check dodShellSnapshot(dod) == shellSnapshot(legacyState)

  test "DOD layout command parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdSetLayout,
        newLayout: legacy_model.Deck,
        layoutTargetTag: 2),
      proc(dod: var DodModel) =
        discard dod.setLayoutForSlot(2, legacy_model.Deck)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSwitchLayout),
      proc(dod: var DodModel) =
        discard dod.switchLayout()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSetMasterCount, count: 3),
      proc(dod: var DodModel) =
        discard dod.setMasterCount(3)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdAdjustMasterCount, deltaMC: 2),
      proc(dod: var DodModel) =
        discard dod.adjustMasterCount(2)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdSetMasterRatio, ratio: 0.7),
      proc(dod: var DodModel) =
        discard dod.setMasterRatio(0.7'f32)
    )
    checkPlacementParity(
      masterPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdAdjustMasterRatio, deltaMR: 0.1),
      proc(dod: var DodModel) =
        discard dod.adjustMasterRatio(0.1'f32)
    )

  test "DOD resize command parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdResizeWidth, deltaW: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeWidth(0.1'f32)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdResizeHeight, deltaH: -0.1),
      proc(dod: var DodModel) =
        discard dod.resizeHeight(-0.1'f32)
    )
    checkPlacementParity(
      verticalPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdResizeWidth, deltaW: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeWidth(0.1'f32)
    )
    checkPlacementParity(
      verticalPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdResizeHeight, deltaH: 0.1),
      proc(dod: var DodModel) =
        discard dod.resizeHeight(0.1'f32)
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSetColumnWidth, targetWidth: 0.8),
      proc(dod: var DodModel) =
        discard dod.setFocusedColumnWidth(0.8'f32)
    )

  test "DOD window movement parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowRight),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowRight()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdMoveWindowLeft),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowLeft()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(11),
      core_msg.Msg(kind: core_msg.CmdMoveWindowUp),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowUp()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowDown),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowDown()
    )

  test "DOD edge window movement parity follows focused window":
    checkPlacementParity(
      activeSecondPlacementModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowUpOrToWorkspaceUp),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowUpOrWorkspace()
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(11),
      core_msg.Msg(kind: core_msg.CmdMoveWindowDownOrToWorkspaceDown),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowDownOrWorkspace()
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )

  test "DOD column movement parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveColumnRight),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnRight()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdMoveColumnLeft),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnLeft()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(13),
      core_msg.Msg(kind: core_msg.CmdMoveColumnToFirst),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnToFirst()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveColumnToLast),
      proc(dod: var DodModel) =
        discard dod.moveFocusedColumnToLast()
    )

  test "DOD consume expel and zoom parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdConsumeWindow),
      proc(dod: var DodModel) =
        discard dod.consumeNextColumnWindow()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdExpelWindow),
      proc(dod: var DodModel) =
        discard dod.expelFocusedWindow()
    )
    checkPlacementParity(
      focusWindowInPlacementModel(12),
      core_msg.Msg(kind: core_msg.CmdZoom),
      proc(dod: var DodModel) =
        discard dod.zoomFocusedWindow()
    )

  test "DOD move and swap tag parity matches legacy":
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveToTag, targetTag: 2),
      proc(dod: var DodModel) =
        discard dod.moveFocusedWindowToSlot(2)
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkPlacementParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdSwapWindowToTag, targetTagSwap: 2),
      proc(dod: var DodModel) =
        discard dod.swapFocusedWindowToSlot(2)
    )

  test "DOD output lifecycle parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputDimensions,
        outputId: 0,
        width: -10,
        height: 900),
      proc(dod: var DodModel) =
        discard dod.setOutputDimensionsForExternal(
          NullExternalOutputId, -10, 900)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputDimensions,
        outputId: 44,
        width: 1600,
        height: 900),
      proc(dod: var DodModel) =
        discard dod.setOutputDimensionsForExternal(
          ExternalOutputId(44), 1600, 900)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputName,
        nameOutputId: 42,
        outputName: " DP-1-fixed "),
      proc(dod: var DodModel) =
        discard dod.setOutputNameForExternal(
          ExternalOutputId(42), " DP-1-fixed ")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputPosition,
        positionOutputId: 42,
        outputX: 10,
        outputY: 20),
      proc(dod: var DodModel) =
        discard dod.setOutputPositionForExternal(
          ExternalOutputId(42), 10, 20)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputUsable,
        usableOutputId: 42,
        usableX: 4,
        usableY: 8,
        usableW: -1,
        usableH: 700),
      proc(dod: var DodModel) =
        discard dod.setOutputUsableForExternal(
          ExternalOutputId(42), 4, 8, -1, 700)
    )
    checkStateParity(
      fullscreenOutputStateModel(),
      core_msg.Msg(kind: core_msg.WlOutputRemoved, removedOutputId: 43),
      proc(dod: var DodModel) =
        discard dod.removeOutputForExternal(ExternalOutputId(43))
    )

  test "DOD window metadata parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDimensions,
        dimensionsWindowId: 10,
        actualWidth: -100,
        actualHeight: 540),
      proc(dod: var DodModel) =
        discard dod.updateWindowDimensionsForExternal(
          ExternalWindowId(10), -100, 540)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDecorationHint,
        decorationWindowId: 10,
        decorationHint: 1),
      proc(dod: var DodModel) =
        discard dod.updateWindowDecorationHintForExternal(
          ExternalWindowId(10), 1)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowPresentationHint,
        presentationWindowId: 10,
        presentationHint: 2),
      proc(dod: var DodModel) =
        discard dod.updateWindowPresentationHintForExternal(
          ExternalWindowId(10), 2)
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowParent,
        childWindowId: 10,
        parentWindowId: 20),
      proc(dod: var DodModel) =
        discard dod.updateWindowParentForExternal(
          ExternalWindowId(10), ExternalWindowId(20))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowIdentifier,
        identifierWindowId: 10,
        identifier: "kitty-window-10"),
      proc(dod: var DodModel) =
        discard dod.updateWindowIdentifierForExternal(
          ExternalWindowId(10), "kitty-window-10")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowAppId,
        appIdWindowId: 10,
        updatedAppId: "org.wezfurlong.wezterm"),
      proc(dod: var DodModel) =
        discard dod.updateWindowAppIdForExternal(
          ExternalWindowId(10), "org.wezfurlong.wezterm")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowTitle,
        titleWindowId: 10,
        updatedTitle: "shell"),
      proc(dod: var DodModel) =
        discard dod.updateWindowTitleForExternal(
          ExternalWindowId(10), "shell")
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDimensionsHint,
        hintWindowId: 10,
        minWidth: 200,
        minHeight: 100,
        maxWidth: 50,
        maxHeight: 80),
      proc(dod: var DodModel) =
        discard dod.updateWindowDimensionsHintForExternal(
          ExternalWindowId(10), 200, 100, 50, 80)
    )

  test "DOD window state request parity matches legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowFullscreenRequested,
        fullscreenRequestId: 10,
        fullscreenOutputId: 43),
      proc(dod: var DodModel) =
        discard dod.requestFullscreenForExternal(
          ExternalWindowId(10), ExternalOutputId(43))
    )
    checkStateParity(
      fullscreenOutputStateModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowExitFullscreenRequested,
        exitFullscreenRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.exitFullscreenForExternal(ExternalWindowId(10))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowMaximizeRequested,
        maximizeRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.requestMaximizeForExternal(ExternalWindowId(10))
    )
    checkStateParity(
      maximizedLayoutModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowUnmaximizeRequested,
        unmaximizeRequestId: 20),
      proc(dod: var DodModel) =
        discard dod.requestUnmaximizeForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowMinimizeRequested,
        minimizeRequestId: 10),
      proc(dod: var DodModel) =
        discard dod.requestMinimizeForExternal(ExternalWindowId(10))
    )

  test "DOD focused window toggles match legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleFloating),
      proc(dod: var DodModel) =
        discard dod.toggleFloatingFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleFullscreen),
      proc(dod: var DodModel) =
        discard dod.toggleFullscreenFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleMaximized),
      proc(dod: var DodModel) =
        discard dod.toggleMaximizedFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdMinimize),
      proc(dod: var DodModel) =
        discard dod.minimizeFocused()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleKeyboardShortcutsInhibit),
      proc(dod: var DodModel) =
        discard dod.toggleKeyboardShortcutsInhibitFocused()
    )

  test "DOD scratchpad commands match legacy":
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveToScratchpad),
      proc(dod: var DodModel) =
        discard dod.moveFocusedToScratchpad()
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkStateParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdMoveToNamedScratchpad,
        scratchpadName: "terminal"),
      proc(dod: var DodModel) =
        discard dod.moveFocusedToScratchpad("terminal")
        discard dod.collapseEmptyActiveDynamicWorkspace()
        discard dod.pruneDynamicWorkspaces()
    )
    checkStateParity(
      scratchpadParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleScratchpad),
      proc(dod: var DodModel) =
        discard dod.toggleScratchpad()
    )
    checkStateParity(
      scratchpadParityModel(visible = true),
      core_msg.Msg(kind: core_msg.CmdToggleScratchpad),
      proc(dod: var DodModel) =
        discard dod.toggleScratchpad()
    )
    checkStateParity(
      scratchpadParityModel(named = true),
      core_msg.Msg(
        kind: core_msg.CmdToggleNamedScratchpad,
        scratchpadName: "terminal"),
      proc(dod: var DodModel) =
        discard dod.toggleNamedScratchpad("terminal")
    )
    checkStateParity(
      scratchpadParityModel(visible = true, named = true),
      core_msg.Msg(
        kind: core_msg.CmdToggleNamedScratchpad,
        scratchpadName: "terminal"),
      proc(dod: var DodModel) =
        discard dod.toggleNamedScratchpad("terminal")
    )
    checkStateParity(
      scratchpadParityModel(visible = true, named = true),
      core_msg.Msg(kind: core_msg.CmdRestoreScratchpad),
      proc(dod: var DodModel) =
        discard dod.restoreScratchpad()
    )

  test "DOD scratchpad refs are pruned from invariants":
    var dod = stateParityModel().dodFromLegacy()
    let winId = dod.windowForExternal(ExternalWindowId(10))
    check winId != NullWindowId
    discard dod.moveFocusedToScratchpad("terminal")
    check dod.validateInvariants().ok
    discard dod.destroyWindowForExternal(ExternalWindowId(10))
    check dod.scratchpadWindows.len == 0
    check not dod.namedScratchpads.hasKey("terminal")
    check dod.validateInvariants().ok

  test "DOD window creation parity matches legacy":
    checkStateParity(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell",
        createdIdentifier: "kitty-30"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "kitty", "shell", "kitty-30")
    )
    checkStateParity(
      lifecycleFallbackModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "kitty", "shell")
    )

  test "DOD window creation applies rules like legacy":
    checkStateParity(
      lifecycleRuleModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "discord",
        title: "Discord"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "discord", "Discord")
    )
    checkStateParity(
      lifecycleTagRuleModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "mpv",
        title: "movie"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(30), "mpv", "movie")
    )

  test "DOD duplicate window creation clears stale placement":
    checkStateParity(
      lifecycleDuplicateModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 10,
        appId: "kitty",
        title: "replacement"),
      proc(dod: var DodModel) =
        discard dod.createWindowForExternal(
          ExternalWindowId(10), "kitty", "replacement")
    )

  test "DOD window destruction parity matches legacy":
    checkStateParity(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      closedFocusedWindowModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 20),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(20))
    )
    checkStateParity(
      lifecycleDynamicDestroyModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 40),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(40))
    )

  test "DOD restore placement beats window rules like legacy":
    var seed = legacy_model.Model(activeTag: 1, screenWidth: 1200,
      screenHeight: 800)
    seed.tags[1] = initTagState(1, legacy_model.Scroller)
    seed.tags[2] = initTagState(2, legacy_model.Grid)
    seed.windowRules.add(legacy_model.WindowRule(
      appIdMatch: "pinned", defaultTag: 3))
    var restored = LiveRestoreState(activeTag: 2)
    restored.tagByWindow[legacy_model.WindowId(112)] = 2

    var legacyModel = seed
    legacyModel.applyLiveRestore(restored)
    var dod = seed.dodFromLegacy()
    dod.applyLiveRestore(restored.dodFromLiveRestore())

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 112,
        appId: "pinned-app",
        title: "pinned"))
    discard dod.createWindowForExternal(
      ExternalWindowId(112), "pinned-app", "pinned")

    checkRestoredStateParity(legacyModel, dod)

  test "DOD restore overlays existing workspace state":
    var seed = legacy_model.Model(activeTag: 1, screenWidth: 2000,
      screenHeight: 1000)
    seed.tags[1] = initTagState(1, legacy_model.Scroller, "configured")

    var restored = LiveRestoreState(activeTag: 1, focusedWindow: 120)
    restored.tags[1] = legacy_model.RestoredTagState(
      tagId: 1,
      name: "restored",
      layoutMode: legacy_model.VerticalScroller,
      focusedWindow: 120,
      targetViewportXOffset: 1908.0,
      currentViewportXOffset: 1908.0,
      targetViewportYOffset: 42.0,
      currentViewportYOffset: 40.0,
      masterCount: 3,
      masterSplitRatio: 0.65,
      columns: @[
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(119)],
          widthProportion: 0.35),
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(120)],
          widthProportion: 0.8)
      ])
    restored.windows[120] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "brave",
      title: "Brave",
      widthProportion: 0.8,
      heightProportion: 1.0)
    restored.tagByWindow[120] = 1

    var legacyModel = seed
    legacyModel.applyLiveRestore(restored)
    var dod = seed.dodFromLegacy()
    dod.applyLiveRestore(restored.dodFromLiveRestore())

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 220,
        appId: "brave",
        title: "Brave"))
    discard dod.createWindowForExternal(
      ExternalWindowId(220), "brave", "Brave")

    checkRestoredStateParity(legacyModel, dod)

  test "DOD restore waits for identifiers like legacy":
    var restored = LiveRestoreState(activeTag: 1, focusedWindow: 11)
    restored.tags[1] = legacy_model.RestoredTagState(
      tagId: 1,
      layoutMode: legacy_model.Scroller,
      masterCount: 1,
      masterSplitRatio: 0.55,
      focusedWindow: 11,
      columns: @[
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(10)],
          widthProportion: 0.35),
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(11)],
          widthProportion: 0.8)
      ])
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "kitty",
      title: "~ - fish",
      identifier: "terminal-a",
      widthProportion: 0.35,
      heightProportion: 1.0)
    restored.windows[11] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "kitty",
      title: "~ - fish",
      identifier: "terminal-b",
      widthProportion: 0.8,
      heightProportion: 1.0,
      isMaximized: true)

    var seed = legacy_model.Model(activeTag: 1, screenWidth: 2000,
      screenHeight: 1000)
    var legacyModel = seed
    legacyModel.applyLiveRestore(restored)
    var dod = seed.dodFromLegacy()
    dod.applyLiveRestore(restored.dodFromLiveRestore())

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 210,
        appId: "kitty",
        title: "~ - fish"))
    discard dod.createWindowForExternal(
      ExternalWindowId(210), "kitty", "~ - fish")
    check dod.restoreWindows.len == legacyModel.restoreWindows.len

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 211,
        appId: "kitty",
        title: "~ - fish"))
    discard dod.createWindowForExternal(
      ExternalWindowId(211), "kitty", "~ - fish")
    check dod.restoreWindows.len == legacyModel.restoreWindows.len

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowIdentifier,
        identifierWindowId: 210,
        identifier: "terminal-a"))
    discard dod.updateWindowIdentifierAndRestoreForExternal(
      ExternalWindowId(210), "terminal-a")
    checkRestoredStateParity(legacyModel, dod)

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowIdentifier,
        identifierWindowId: 211,
        identifier: "terminal-b"))
    discard dod.updateWindowIdentifierAndRestoreForExternal(
      ExternalWindowId(211), "terminal-b")
    checkRestoredStateParity(legacyModel, dod)

  test "DOD restore maps legacy Niri state by identity":
    let parsed = parseLiveRestoreJson("""
{
  "workspaces": [
    {"id": 1, "name": "term", "is_active": false},
    {"id": 2, "name": "web", "is_active": true}
  ],
  "windows": [
    {
      "id": 10,
      "title": "term",
      "app_id": "triad-foot",
      "raw_app_id": "foot",
      "workspace_id": 2,
      "is_focused": false,
      "layout": {
        "pos_in_scrolling_layout": [2, 1],
        "tile_size": [2000.0, 1000.0],
        "window_size": [800, 900]
      }
    },
    {
      "id": 11,
      "title": "Browser",
      "app_id": "brave-origin-nightly.desktop",
      "raw_app_id": "brave-origin-nightly",
      "workspace_id": 2,
      "is_focused": true,
      "is_maximized": true,
      "layout": {
        "pos_in_scrolling_layout": [1, 1],
        "tile_size": [2000.0, 1000.0],
        "window_size": [1000, 900]
      }
    }
  ]
}
""")
    check parsed.isSome

    var seed = legacy_model.Model(activeTag: 1, screenWidth: 2000,
      screenHeight: 1000)
    var legacyModel = seed
    legacyModel.applyLiveRestore(parsed.get())
    var dod = seed.dodFromLegacy()
    dod.applyLiveRestore(parsed.get().dodFromLiveRestore())

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 210,
        appId: "foot",
        title: "term"))
    discard dod.createWindowForExternal(
      ExternalWindowId(210), "foot", "term")

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 211,
        appId: "brave-origin-nightly",
        title: "Browser"))
    discard dod.createWindowForExternal(
      ExternalWindowId(211), "brave-origin-nightly", "Browser")

    checkRestoredStateParity(legacyModel, dod)

  test "DOD restore preserves scratchpad state":
    var restored = LiveRestoreState(activeTag: 1)
    restored.scratchpadWindows = @[legacy_model.WindowId(10)]
    restored.namedScratchpads["terminal"] = 10
    restored.visibleScratchpad = 10
    restored.isScratchpadVisible = true
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 0,
      appId: "foot",
      title: "drop-down",
      widthProportion: 0.8,
      heightProportion: 1.0)

    var seed = legacy_model.Model(activeTag: 1, screenWidth: 2000,
      screenHeight: 1000)
    seed.tags[1] = initTagState(1, legacy_model.Scroller)
    var legacyModel = seed
    legacyModel.applyLiveRestore(restored)
    var dod = seed.dodFromLegacy()
    dod.applyLiveRestore(restored.dodFromLiveRestore())

    (legacyModel, _) = legacy_update.update(
      legacyModel,
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 10,
        appId: "foot",
        title: "drop-down"))
    discard dod.createWindowForExternal(
      ExternalWindowId(10), "foot", "drop-down")

    check dod.scratchpadWindows.len == 1
    check dod.visibleScratchpad != NullWindowId
    check dod.isScratchpadVisible
    dod.refreshVisibleWorkspaceSlots()
    check dod.validateInvariants().ok
    check dodShellSnapshot(dod) == shellSnapshot(legacyModel)
    check dod.dodFocusHistory() == legacyModel.focusHistory
    check dod.dodWorkspaceHistory() == legacyModel.workspaceHistory
    check dod.dodLayoutInstructions().len == 1

  test "DOD restore maps scratchpads by identity":
    var restored = LiveRestoreState(activeTag: 1)
    restored.scratchpadWindows = @[legacy_model.WindowId(10)]
    restored.namedScratchpads["terminal"] = 10
    restored.visibleScratchpad = 10
    restored.isScratchpadVisible = true
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 0,
      appId: "foot",
      title: "drop-down",
      widthProportion: 0.8,
      heightProportion: 1.0)

    var dod = legacy_model.Model(
      activeTag: 1, screenWidth: 2000, screenHeight: 1000).dodFromLegacy()
    dod.applyLiveRestore(restored.dodFromLiveRestore())
    let winId = dod.createWindowForExternal(
      ExternalWindowId(210), "foot", "drop-down")

    check winId != NullWindowId
    check dod.scratchpadWindows == @[winId]
    check dod.namedScratchpads["terminal"] == winId
    check dod.visibleScratchpad == winId
    check dod.isScratchpadVisible
    check dod.placementForWindowOnTag(dod.activeTag, winId).isNone
    check dod.validateInvariants().ok

    checkStateParity(
      lifecycleCollapseDestroyModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowDestroyed,
        destroyedId: 40),
      proc(dod: var DodModel) =
        discard dod.destroyWindowForExternal(ExternalWindowId(40))
    )

  test "DOD reducer bridges focus layout movement and workspace effects":
    var result = checkReducerParity(
      focusParityModel(),
      core_msg.Msg(kind: core_msg.CmdFocusNext))
    check result.effects.containsFocusEffect(11)
    check result.effects.containsEffect(EffManageDirty)
    check result.effects.containsEffect(EffBroadcastJson)
    check result.effects.containsEffect(EffBroadcastTriadJson)

    discard checkReducerParity(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowRight))
    discard checkReducerParity(
      placementParityModel(),
      core_msg.Msg(
        kind: core_msg.CmdSetLayout,
        newLayout: legacy_model.Deck,
        layoutTargetTag: 2))

  test "DOD reducer bridges output lifecycle and window state effects":
    var result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlOutputDimensions,
        outputId: 44,
        width: 1600,
        height: 900))
    check result.effects.containsEffect(EffBroadcastJson)
    check result.effects.containsEffect(EffBroadcastTriadJson)

    result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowFullscreenRequested,
        fullscreenRequestId: 10,
        fullscreenOutputId: 43))
    check result.effects.containsFullscreenEffect(10, true, 43)

  test "DOD reducer bridges lifecycle scratchpad overview and close effects":
    var result = checkReducerParity(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell",
        createdIdentifier: "kitty-30"))
    check result.effects.containsFocusEffect(30)
    check result.effects.containsEffect(EffManageDirty)

    discard checkReducerParity(
      scratchpadParityModel(visible = true, named = true),
      core_msg.Msg(kind: core_msg.CmdRestoreScratchpad))
    discard checkReducerParity(
      overviewLayoutModel(),
      core_msg.Msg(kind: core_msg.CmdCloseOverview))

    result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdCloseWindowById, closeWindowId: 10))
    check result.effects.containsCloseEffect(10)

  test "DOD reducer bridges session layer manage and modifier runtime":
    var result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.WlManageStart))
    check result.effects.containsFocusEffect(10)
    check result.effects.containsEffect(EffManageDirty)

    var locked = focusParityModel()
    locked.sessionLocked = true
    result = checkReducerParity(
      locked,
      core_msg.Msg(kind: core_msg.CmdFocusNext))
    check not result.effects.containsFocusEffect(11)

    result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.WlSessionLocked))
    check result.dod.sessionLocked
    check result.effects.containsEffect(EffManageDirty)

    result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.WlLayerFocusExclusive))
    check result.dod.layerFocusExclusive

    discard checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.WlModifiersChanged, newModifiers: 64))

  test "DOD reducer bridges pointer and floating runtime":
    var result = checkReducerParity(
      floatingRuntimeModel(),
      core_msg.Msg(
        kind: core_msg.WlPointerMoveRequested,
        moveWinId: 10,
        moveSeat: nil))
    check result.effects.containsEffect(EffOpStartPointer)

    result = checkReducerParity(
      floatingRuntimeModel(),
      core_msg.Msg(
        kind: core_msg.WlPointerResizeRequested,
        resizeWinId: 10,
        resizeSeat: nil,
        resizeEdges: 8))
    check result.effects.containsEffect(EffInformResizeStart)

    discard checkReducerParity(
      pointerRuntimeModel(legacy_model.OpMove),
      core_msg.Msg(kind: core_msg.WlPointerDelta, dx: 20, dy: -10))
    result = checkReducerParity(
      pointerRuntimeModel(legacy_model.OpResize),
      core_msg.Msg(kind: core_msg.WlPointerRelease))
    check result.effects.containsEffect(EffInformResizeEnd)

    discard checkReducerParity(
      floatingRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdMoveFloating, moveDX: 7, moveDY: -3))
    discard checkReducerParity(
      floatingRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdResizeFloating, deltaFW: 50,
        deltaFH: -20))

  test "DOD reducer bridges gaps animation groups and effect-only commands":
    discard checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdAdjustGaps, deltaG: 6))
    discard checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdToggleGaps))
    discard checkReducerParity(
      animationRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdTick))

    var result = checkReducerParity(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.CmdGroupWindows))
    check result.effects.containsEffect(EffManageDirty)

    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.WlWindowMenuRequested, menuWindowId: 10,
        menuX: 12, menuY: 34))
    check result.effects.containsEffect(EffSpawnWindowMenu)

    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdSpawn, spawnCommand: @["foot"]))
    check result.effects.containsEffect(EffSpawn)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdLockSession))
    check result.effects.containsEffect(EffSpawnScreenLock)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdWarpPointer, warpX: 10, warpY: 20))
    check result.effects.containsEffect(EffPointerWarp)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdEatNextKey))
    check result.effects.containsEffect(EffEnsureNextKeyEaten)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdCancelEatNextKey))
    check result.effects.containsEffect(EffCancelEnsureNextKeyEaten)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdTriadReload))
    check result.effects.containsEffect(EffTriadReload)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdExitSession))
    check result.effects.containsEffect(EffExitSession)
    result = checkReducerParity(
      effectRuntimeModel(),
      core_msg.Msg(kind: core_msg.CmdScreenshot,
        screenshotKind: core_msg.ShotScreen, screenshotPath: "/tmp/shot.png",
        screenshotShowPointer: true))
    check result.effects.containsEffect(EffScreenshot)

  test "DOD runtime update sync returns legacy effects and advances shadow":
    checkRuntimeUpdateSync(
      lifecycleParityModel(),
      core_msg.Msg(
        kind: core_msg.WlWindowCreated,
        windowId: 30,
        appId: "kitty",
        title: "shell",
        createdIdentifier: "kitty-30"))
    checkRuntimeUpdateSync(
      placementParityModel(),
      core_msg.Msg(kind: core_msg.CmdMoveWindowRight))
    checkRuntimeUpdateSync(
      stateParityModel(),
      core_msg.Msg(kind: core_msg.WlSessionLocked))

  test "DOD runtime update sync can select DOD effects as authoritative":
    var legacyModel = lifecycleParityModel()
    var shadow = legacyModel.dodFromLegacy()
    let msg = core_msg.Msg(
      kind: core_msg.WlWindowCreated,
      windowId: 30,
      appId: "kitty",
      title: "shell",
      createdIdentifier: "kitty-30")

    let result = syncRuntimeUpdate(
      legacyModel,
      shadow,
      msg,
      syncShadow = true,
      authority = DodRuntimeAuthority)
    check result.authority == DodRuntimeAuthority
    check result.shadowChecked
    check result.shadowReport.ok
    check result.authoritativeEffects.stableEffectSignatures(msg) ==
      result.dodEffects.stableEffectSignatures(msg)
    check result.dodEffects.stableEffectSignatures(msg) ==
      result.legacyEffects.stableEffectSignatures(msg)
    check dodShellSnapshot(shadow) == shellSnapshot(legacyModel)

  test "DOD runtime update sync can skip shadow mutation":
    var legacyModel = lifecycleParityModel()
    var shadow = legacyModel.dodFromLegacy()
    let originalShadow = shadow
    let msg = core_msg.Msg(
      kind: core_msg.WlWindowCreated,
      windowId: 30,
      appId: "kitty",
      title: "shell")

    let result = syncRuntimeUpdate(
      legacyModel, shadow, msg, syncShadow = false)
    check not result.shadowChecked
    check result.shadowReport.ok
    check shadow == originalShadow
    check legacyModel.windows.hasKey(30)
    check result.legacyEffects.containsEffect(EffManageDirty)
    check result.authoritativeEffects.containsEffect(EffManageDirty)
    check result.dodEffects.len == 0

  test "DOD runtime update sync reports mismatches without changing effects":
    var legacyModel = lifecycleParityModel()
    var shadow = lifecycleParityModel().dodFromLegacy()
    shadow.outerGaps = legacyModel.outerGaps + 9
    let msg = core_msg.Msg(kind: core_msg.CmdAdjustGaps, deltaG: 3)
    let (_, expectedEffects) = legacy_update.update(legacyModel, msg)

    let result = syncRuntimeUpdate(
      legacyModel, shadow, msg, syncShadow = true)
    check result.shadowChecked
    check not result.shadowReport.ok
    check result.legacyEffects.stableEffectSignatures(msg) ==
      expectedEffects.stableEffectSignatures(msg)
    check result.authoritativeEffects.stableEffectSignatures(msg) ==
      expectedEffects.stableEffectSignatures(msg)

  test "DOD runtime update sync handles shadow-only messages":
    var legacyModel = effectRuntimeModel()
    var shadow = legacyModel.dodFromLegacy()
    let originalLegacy = legacyModel

    let result = syncShadowOnlyMessage(
      legacyModel,
      shadow,
      core_msg.Msg(kind: core_msg.CmdSpawnTerminal),
      syncShadow = true)
    check result.shadowChecked
    check result.shadowReport.ok
    check legacyModel == originalLegacy
    check result.legacyEffects.len == 0
    check result.authoritativeEffects.len == 0
    check result.dodEffects.len > 0

  test "DOD runtime shadow-only sync can expose DOD authoritative effects":
    var legacyModel = effectRuntimeModel()
    var shadow = legacyModel.dodFromLegacy()
    let msg = core_msg.Msg(kind: core_msg.CmdSpawnTerminal)

    let result = syncShadowOnlyMessage(
      legacyModel,
      shadow,
      msg,
      syncShadow = true,
      authority = DodRuntimeAuthority)
    check result.authority == DodRuntimeAuthority
    check result.shadowChecked
    check result.shadowReport.ok
    check result.authoritativeEffects.stableEffectSignatures(msg) ==
      result.dodEffects.stableEffectSignatures(msg)

  test "DOD shadow trace follows lifecycle and focus history":
    checkShadowTrace(
      lifecycleParityModel(),
      @[
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 30,
          appId: "kitty",
          title: "shell",
          createdIdentifier: "kitty-30"),
        core_msg.Msg(kind: core_msg.WlFocusChanged, newFocusedId: 20),
        core_msg.Msg(kind: core_msg.CmdFocusLast),
        core_msg.Msg(
          kind: core_msg.WlWindowTitle,
          titleWindowId: 30,
          updatedTitle: "shell - tests"),
        core_msg.Msg(
          kind: core_msg.WlWindowDimensions,
          dimensionsWindowId: 30,
          actualWidth: 1000,
          actualHeight: 720),
        core_msg.Msg(kind: core_msg.CmdToggleMaximized),
        core_msg.Msg(kind: core_msg.WlWindowDestroyed, destroyedId: 30),
        core_msg.Msg(kind: core_msg.CmdFocusLast)
      ])

  test "DOD shadow trace follows dynamic workspace growth":
    checkShadowTrace(
      lifecycleParityModel(),
      @[
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 4),
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 40,
          appId: "alacritty",
          title: "workspace four"),
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 5),
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 50,
          appId: "brave",
          title: "workspace five"),
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 4),
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 1)
      ])

  test "DOD shadow trace follows movement and state toggles":
    checkShadowTrace(
      placementParityModel(),
      @[
        core_msg.Msg(kind: core_msg.CmdFocusNext),
        core_msg.Msg(kind: core_msg.CmdMoveWindowRight),
        core_msg.Msg(kind: core_msg.CmdFocusLast),
        core_msg.Msg(kind: core_msg.CmdToggleKeyboardShortcutsInhibit)
      ])

  test "DOD shadow trace follows outputs pointer and effect commands":
    checkShadowTrace(
      effectRuntimeModel(),
      @[
        core_msg.Msg(
          kind: core_msg.WlOutputDimensions,
          outputId: 44,
          width: 1600,
          height: 900),
        core_msg.Msg(
          kind: core_msg.WlOutputName,
          nameOutputId: 44,
          outputName: "HDMI-A-2"),
        core_msg.Msg(
          kind: core_msg.WlOutputPosition,
          positionOutputId: 44,
          outputX: 1200,
          outputY: 0),
        core_msg.Msg(
          kind: core_msg.WlPointerMoveRequested,
          moveWinId: 10,
          moveSeat: nil),
        core_msg.Msg(kind: core_msg.WlPointerDelta, dx: 24, dy: -12),
        core_msg.Msg(kind: core_msg.WlPointerRelease),
        core_msg.Msg(kind: core_msg.CmdConfigReload),
        core_msg.Msg(kind: core_msg.CmdTriadReload),
        core_msg.Msg(kind: core_msg.CmdSpawn, spawnCommand: @["foot"]),
        core_msg.Msg(kind: core_msg.CmdLockSession),
        core_msg.Msg(kind: core_msg.CmdWarpPointer, warpX: 10, warpY: 20),
        core_msg.Msg(kind: core_msg.CmdScreenshot,
          screenshotKind: core_msg.ShotScreen,
          screenshotPath: "/tmp/shot.png",
          screenshotShowPointer: true)
      ])

  test "DOD shadow trace follows restored windows by identity":
    var restored = LiveRestoreState(activeTag: 1, focusedWindow: 10)
    restored.tags[1] = legacy_model.RestoredTagState(
      tagId: 1,
      layoutMode: legacy_model.Scroller,
      focusedWindow: 10,
      columns: @[
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(10)],
          widthProportion: 0.35)
      ])
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "kitty-a",
      title: "terminal-a",
      widthProportion: 0.35,
      heightProportion: 1.0,
      isMaximized: true)

    checkShadowTraceAfterRestore(
      legacy_model.Model(activeTag: 1, screenWidth: 2000,
        screenHeight: 1000),
      restored,
      @[
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 210,
          appId: "kitty-a",
          title: "terminal-a"),
        core_msg.Msg(kind: core_msg.CmdFocusLast)
      ])

  test "DOD shadow projections match IPC and live restore reads":
    checkShadowReadProjectionTrace(
      lifecycleParityModel(),
      @[
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 30,
          appId: "kitty",
          title: "shell"),
        core_msg.Msg(kind: core_msg.WlFocusChanged, newFocusedId: 30),
        core_msg.Msg(kind: core_msg.CmdToggleMaximized),
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 4),
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 40,
          appId: "brave",
          title: "browser"),
        core_msg.Msg(
          kind: core_msg.CmdFocusWorkspaceIndex,
          workspaceIndex: 1)
      ])

  test "DOD shadow projections match IPC reads after live restore":
    var restored = LiveRestoreState(activeTag: 1, focusedWindow: 10)
    restored.tags[1] = legacy_model.RestoredTagState(
      tagId: 1,
      layoutMode: legacy_model.Scroller,
      focusedWindow: 10,
      columns: @[
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(10)],
          widthProportion: 0.4)
      ])
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "kitty-a",
      title: "terminal-a",
      widthProportion: 0.4,
      heightProportion: 1.0,
      isMaximized: true)

    var seed = legacy_model.Model(activeTag: 1, screenWidth: 2000,
      screenHeight: 1000)
    seed.workspaces.defaultCount = 3
    seed.tags[1] = initTagState(1, legacy_model.Scroller)
    seed.tags[2] = initTagState(2, legacy_model.Scroller)
    seed.tags[3] = initTagState(3, legacy_model.Scroller)

    checkShadowReadProjectionAfterRestore(
      seed,
      restored,
      @[
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 210,
          appId: "kitty-a",
          title: "terminal-a"),
        core_msg.Msg(kind: core_msg.CmdFocusLast)
      ])

  test "DOD shadow runtime helper reports clean lifecycle trace":
    let reports = shadow_runtime.checkShadowTrace(
      lifecycleParityModel(),
      @[
        core_msg.Msg(kind: core_msg.WlManageStart),
        core_msg.Msg(
          kind: core_msg.WlWindowCreated,
          windowId: 30,
          appId: "kitty",
          title: "shell"),
        core_msg.Msg(kind: core_msg.WlFocusChanged, newFocusedId: 30),
        core_msg.Msg(kind: core_msg.CmdToggleMaximized),
        core_msg.Msg(kind: core_msg.WlWindowDestroyed, destroyedId: 30)
      ])
    check reports.allIt(it.ok)

  test "DOD shadow runtime helper handles live restore before windows":
    var restored = LiveRestoreState(activeTag: 1, focusedWindow: 10)
    restored.tags[1] = legacy_model.RestoredTagState(
      tagId: 1,
      layoutMode: legacy_model.Scroller,
      focusedWindow: 10,
      masterCount: 1,
      masterSplitRatio: 0.55,
      columns: @[
        legacy_model.RestoredColumnState(
          windows: @[legacy_model.WindowId(10)],
          widthProportion: 0.5)
      ])
    restored.windows[10] = legacy_model.RestoredWindowState(
      tagId: 1,
      appId: "kitty",
      title: "restored",
      widthProportion: 0.5,
      heightProportion: 1.0)

    var legacyState = legacy_model.Model(activeTag: 1, screenWidth: 1200,
      screenHeight: 800)
    legacyState.applyLiveRestore(restored)
    var shadow = legacy_model.Model(activeTag: 1, screenWidth: 1200,
      screenHeight: 800).dodFromLegacy()
    shadow.applyLiveRestore(restored.dodFromLiveRestore())

    let report = shadow_runtime.compareShadowState(
      legacyState,
      shadow,
      core_msg.Msg(kind: core_msg.WlManageStart),
      @[],
      @[])
    check report.ok

  test "DOD shadow runtime skips effect parity for runtime-owned messages":
    let model = lifecycleParityModel()
    var shadow = model.dodFromLegacy()
    let report = shadow_runtime.compareShadowState(
      model,
      shadow,
      core_msg.Msg(kind: core_msg.CmdSpawnTerminal),
      @[Effect(kind: EffManageDirty)],
      @[])

    check report.ok
    check not report.effectParityChecked
