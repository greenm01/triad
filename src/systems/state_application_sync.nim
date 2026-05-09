import ../config/dod_apply
import ../config/parser
import ../core/model
import ../core/msg
import ../core/restore_state
import ../state/dod_adapter
import ../types/dod_model
import dod_shadow_runtime
import dod_window_lifecycle

type
  InitialStateSyncResult* = object
    legacyModel*: Model
    shadowModel*: DodModel
    shadowChecked*: bool
    shadowReport*: DodShadowReport

  StateApplicationSyncResult* = object
    shadowChecked*: bool
    shadowReport*: DodShadowReport

proc okShadowReport(): DodShadowReport =
  DodShadowReport(ok: true)

proc syncInitialConfigApplication*(
    config: Config; activeTag: uint32 = 1): InitialStateSyncResult =
  result.legacyModel = Model(activeTag: activeTag)
  result.legacyModel.applyConfig(config)

  var shadowSeed = Model(activeTag: activeTag)
  result.shadowModel = shadowSeed.dodFromLegacy()
  result.shadowModel.applyConfig(config)
  result.shadowChecked = true
  result.shadowReport = compareShadowState(
    result.legacyModel, result.shadowModel, Msg(kind: CmdConfigReload), @[], @[])

proc syncConfigApplication*(
    legacyModel: var Model; shadow: var DodModel; config: Config;
    syncShadow: bool): StateApplicationSyncResult =
  legacyModel.applyConfig(config)
  if not syncShadow:
    result.shadowReport = okShadowReport()
    return

  shadow.applyConfig(config)
  result.shadowChecked = true
  result.shadowReport = compareShadowState(
    legacyModel, shadow, Msg(kind: CmdConfigReload), @[], @[])

proc syncLiveRestoreApplication*(
    legacyModel: var Model; shadow: var DodModel; state: LiveRestoreState;
    syncShadow: bool): StateApplicationSyncResult =
  legacyModel.applyLiveRestore(state)
  if not syncShadow:
    result.shadowReport = okShadowReport()
    return

  shadow.applyLiveRestore(state.dodFromLiveRestore())
  result.shadowChecked = true
  result.shadowReport = compareShadowState(
    legacyModel, shadow, Msg(kind: WlManageStart), @[], @[])
