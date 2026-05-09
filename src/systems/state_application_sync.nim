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
  StateApplicationSyncResult* = object
    shadowChecked*: bool
    shadowReport*: DodShadowReport

proc okShadowReport(): DodShadowReport =
  DodShadowReport(ok: true)

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
