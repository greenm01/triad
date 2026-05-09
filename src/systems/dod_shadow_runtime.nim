import algorithm, options, strutils
import ../core/effects
import ../core/model
import ../core/msg
import ../core/shell_state
import ../core/update as legacy_update
import ../state/dod_adapter
import ../state/dod_invariants
import ../state/dod_queries
import ../state/dod_snapshot
import ../types/core as dod_core
import ../types/dod_model
from ../types/legacy_model import nil
import dod_layout
import dod_update
import dod_workspaces
import layout_state

type
  DodShadowReport* = object
    ok*: bool
    effectParityChecked*: bool
    errors*: seq[string]
    dodEffects*: seq[Effect]

proc legacyWindowId(model: DodModel; winId: dod_core.WindowId):
    legacy_model.WindowId =
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacy_model.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc dodFocusHistory(model: DodModel): seq[legacy_model.WindowId] =
  for winId in model.focusHistory:
    let external = model.legacyWindowId(winId)
    if external != 0:
      result.add(external)

proc dodWorkspaceHistory(model: DodModel): seq[uint32] =
  for tagId in model.workspaceHistory:
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome:
      result.add(tagOpt.get().slot)

proc effectSignature(effect: Effect; msg: Msg): string =
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

proc stableEffectSignatures*(
    effects: seq[Effect]; msg: Msg): seq[string] =
  for effect in effects:
    let signature = effect.effectSignature(msg)
    if signature.len > 0:
      result.add(signature)
  result.sort()

proc shouldCheckEffectParity*(kind: MsgKind): bool =
  kind notin {CmdTick, CmdConfigReload, CmdSpawnTerminal, WlRenderStart}

proc shouldCheckLayoutParity(kind: MsgKind; effects: seq[Effect]): bool =
  if kind in {WlManageStart, WlRenderStart, CmdTick}:
    return true
  for effect in effects:
    if effect.kind == EffManageDirty:
      return true
  false

proc compareShadowState*(
    legacyModel: Model; shadow: var DodModel; msg: Msg;
    legacyEffects, dodEffects: seq[Effect]): DodShadowReport =
  result.ok = true
  shadow.refreshVisibleWorkspaceSlots()

  let invariantReport = shadow.validateInvariants()
  if not invariantReport.ok:
    result.ok = false
    for error in invariantReport.errors:
      result.errors.add("invariant: " & error.message)

  let legacySnapshot = shellSnapshot(legacyModel)
  let dodSnapshot = dodShellSnapshot(shadow)
  if dodSnapshot != legacySnapshot:
    result.ok = false
    result.errors.add("shell snapshot mismatch")

  if shadow.dodFocusHistory() != legacyModel.focusHistory:
    result.ok = false
    result.errors.add("focus history mismatch")

  if shadow.dodWorkspaceHistory() != legacyModel.workspaceHistory:
    result.ok = false
    result.errors.add("workspace history mismatch")

  if msg.kind.shouldCheckLayoutParity(legacyEffects):
    let legacyProjection = legacyModel.layoutProjection()
    let shadowProjection = shadow.layoutProjection()
    if legacyProjection.instructions != shadowProjection.instructions:
      result.ok = false
      result.errors.add("layout instructions mismatch")
    if legacyProjection.viewportTargets != shadowProjection.viewportTargets:
      result.ok = false
      result.errors.add("layout viewport targets mismatch")

  result.effectParityChecked = msg.kind.shouldCheckEffectParity()
  if result.effectParityChecked:
    let legacySignatures = legacyEffects.stableEffectSignatures(msg)
    let dodSignatures = dodEffects.stableEffectSignatures(msg)
    if dodSignatures != legacySignatures:
      result.ok = false
      result.errors.add("effect signature mismatch")

proc advanceShadow*(
    shadow: var DodModel; legacyModel: Model; msg: Msg;
    legacyEffects: seq[Effect]): DodShadowReport =
  let (nextShadow, dodEffects) = shadow.dodUpdate(msg)
  shadow = nextShadow
  result = compareShadowState(legacyModel, shadow, msg, legacyEffects,
    dodEffects)
  result.dodEffects = dodEffects

proc checkShadowTrace*(
    seed: Model; messages: openArray[Msg]): seq[DodShadowReport] =
  var legacyModel = seed
  var shadow = seed.dodFromLegacy()
  for msg in messages:
    var legacyEffects: seq[Effect]
    (legacyModel, legacyEffects) = legacy_update.update(legacyModel, msg)
    result.add(shadow.advanceShadow(legacyModel, msg, legacyEffects))
