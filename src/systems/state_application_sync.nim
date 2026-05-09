import ../config/dod_apply
import ../config/legacy_apply
import ../config/parser
import ../core/model
import ../core/msg
import ../core/restore_state
import ../state/dod_adapter
import ../types/dod_model
import ../types/dod_runtime_policy
import dod_shadow_runtime
import dod_window_lifecycle

export dod_runtime_policy

type
  InitialStateSyncResult* = object
    legacyModel*: Model
    shadowModel*: DodModel
    shadowChecked*: bool
    shadowReport*: DodShadowReport

  StateApplicationSyncResult* = object
    authority*: StateApplicationAuthority
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
    syncShadow: bool;
    authority = LegacyStateApplicationAuthority): StateApplicationSyncResult =
  result.authority = authority
  legacyModel.applyConfig(config)
  if syncShadow or authority == DodStateApplicationAuthority:
    shadow.applyConfig(config)

  if not syncShadow:
    result.shadowReport = okShadowReport()
    return

  result.shadowChecked = true
  result.shadowReport = compareShadowState(
    legacyModel, shadow, Msg(kind: CmdConfigReload), @[], @[])

proc syncLiveRestoreApplication*(
    legacyModel: var Model; shadow: var DodModel; state: LiveRestoreState;
    syncShadow: bool;
    authority = LegacyStateApplicationAuthority): StateApplicationSyncResult =
  result.authority = authority
  legacyModel.applyLiveRestore(state)
  if syncShadow or authority == DodStateApplicationAuthority:
    shadow.applyLiveRestore(state.dodFromLiveRestore())

  if not syncShadow:
    result.shadowReport = okShadowReport()
    return

  result.shadowChecked = true
  result.shadowReport = compareShadowState(
    legacyModel, shadow, Msg(kind: WlManageStart), @[], @[])
