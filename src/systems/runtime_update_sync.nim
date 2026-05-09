import ../core/effects
import ../core/model
import ../core/msg
import ../core/update as legacy_update
import ../types/dod_model
import ../types/dod_runtime_policy
import dod_update
import dod_shadow_runtime

export dod_runtime_policy

type
  RuntimeUpdateSyncResult* = object
    authority*: RuntimeAuthority
    legacyEffects*: seq[Effect]
    dodEffects*: seq[Effect]
    authoritativeEffects*: seq[Effect]
    shadowChecked*: bool
    shadowReport*: DodShadowReport

proc okShadowReport(): DodShadowReport =
  DodShadowReport(ok: true)

proc syncRuntimeUpdate*(
    legacyModel: var Model; shadow: var DodModel; msg: Msg;
    syncShadow: bool;
    authority = LegacyRuntimeAuthority): RuntimeUpdateSyncResult =
  result.authority = authority
  let (nextLegacy, legacyEffects) = legacy_update.update(legacyModel, msg)
  legacyModel = nextLegacy
  result.legacyEffects = legacyEffects

  if syncShadow or authority == DodRuntimeAuthority:
    let (nextShadow, dodEffects) = shadow.dodUpdate(msg)
    shadow = nextShadow
    result.dodEffects = dodEffects
    result.shadowReport.dodEffects = dodEffects

  case authority
  of LegacyRuntimeAuthority:
    result.authoritativeEffects = legacyEffects
  of DodRuntimeAuthority:
    result.authoritativeEffects = result.dodEffects

  if not syncShadow:
    result.shadowReport = okShadowReport()
    result.shadowReport.dodEffects = result.dodEffects
    return

  result.shadowChecked = true
  result.shadowReport = compareShadowState(legacyModel, shadow, msg,
    legacyEffects, result.dodEffects)
  result.shadowReport.dodEffects = result.dodEffects

proc syncShadowOnlyMessage*(
    legacyModel: Model; shadow: var DodModel; msg: Msg;
    syncShadow: bool;
    authority = LegacyRuntimeAuthority): RuntimeUpdateSyncResult =
  result.authority = authority
  let runDod = syncShadow or authority == DodRuntimeAuthority
  if not runDod:
    result.shadowReport = okShadowReport()
    return

  let (nextShadow, dodEffects) = shadow.dodUpdate(msg)
  shadow = nextShadow
  result.dodEffects = dodEffects
  result.shadowReport.dodEffects = dodEffects

  case authority
  of LegacyRuntimeAuthority:
    result.authoritativeEffects = @[]
  of DodRuntimeAuthority:
    result.authoritativeEffects = dodEffects

  if not syncShadow:
    result.shadowReport = okShadowReport()
    result.shadowReport.dodEffects = result.dodEffects
    return

  result.shadowChecked = true
  result.shadowReport = compareShadowState(legacyModel, shadow, msg, @[],
    dodEffects)
  result.shadowReport.dodEffects = dodEffects
