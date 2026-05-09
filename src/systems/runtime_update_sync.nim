import ../core/effects
import ../core/model
import ../core/msg
import ../core/update as legacy_update
import ../types/dod_model
import dod_shadow_runtime

type
  RuntimeUpdateSyncResult* = object
    legacyEffects*: seq[Effect]
    shadowChecked*: bool
    shadowReport*: DodShadowReport

proc syncRuntimeUpdate*(
    legacyModel: var Model; shadow: var DodModel; msg: Msg;
    syncShadow: bool): RuntimeUpdateSyncResult =
  let (nextLegacy, legacyEffects) = legacy_update.update(legacyModel, msg)
  legacyModel = nextLegacy
  result.legacyEffects = legacyEffects

  if not syncShadow:
    result.shadowReport = DodShadowReport(ok: true)
    return

  result.shadowChecked = true
  result.shadowReport = shadow.advanceShadow(legacyModel, msg, legacyEffects)

proc syncShadowOnlyMessage*(
    legacyModel: Model; shadow: var DodModel; msg: Msg;
    syncShadow: bool): RuntimeUpdateSyncResult =
  if not syncShadow:
    result.shadowReport = DodShadowReport(ok: true)
    return

  result.shadowChecked = true
  result.shadowReport = shadow.advanceShadow(legacyModel, msg, @[])
