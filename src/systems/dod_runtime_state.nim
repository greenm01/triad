import ../config/parser
import ../core/msg
import ../core/restore_state
import ../core/shell_state
import ../types/dod_runtime_state
import dod_shadow_health
import dod_shadow_runtime
import layout_projection_sync
import projection_read_sync
import runtime_update_sync
import state_application_sync

export dod_runtime_state

type
  RuntimeStateInitResult* = object
    state*: TriadRuntimeState
    shadowChecked*: bool
    shadowReport*: DodShadowReport

proc initRuntimeStateFromConfig*(
    config: Config; activeTag: uint32 = 1): RuntimeStateInitResult =
  let syncResult = syncInitialConfigApplication(config, activeTag)
  result.state = TriadRuntimeState(
    legacyModel: syncResult.legacyModel,
    shadowModel: syncResult.shadowModel,
    shadowHealth: initDodShadowHealth())
  result.shadowChecked = syncResult.shadowChecked
  result.shadowReport = syncResult.shadowReport

proc applyRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg;
    authority = LegacyRuntimeAuthority): RuntimeUpdateSyncResult =
  runtime_update_sync.syncRuntimeUpdate(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    authority)

proc applyRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg;
    authority = LegacyRuntimeAuthority): RuntimeUpdateSyncResult =
  syncShadowOnlyMessage(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    authority)

proc applyRuntimeLayoutProjection*(
    state: var TriadRuntimeState;
    authority = LegacyLayoutAuthority): LayoutProjectionSyncReport =
  syncLayoutProjection(
    state.legacyModel,
    state.shadowModel,
    state.shadowHealth.shadowSyncEnabled(),
    authority)

proc applyRuntimeConfig*(
    state: var TriadRuntimeState; config: Config): StateApplicationSyncResult =
  syncConfigApplication(
    state.legacyModel,
    state.shadowModel,
    config,
    state.shadowHealth.shadowSyncEnabled())

proc applyRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): StateApplicationSyncResult =
  syncLiveRestoreApplication(
    state.legacyModel,
    state.shadowModel,
    restoreState,
    state.shadowHealth.shadowSyncEnabled())

proc runtimeProjectionReadSource*(
    state: TriadRuntimeState): ProjectionReadSource =
  projectionReadSource(state.shadowHealth)

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  readProjectionSnapshot(
    state.legacyModel,
    state.shadowModel,
    state.runtimeProjectionReadSource())

proc readRuntimeLiveRestoreJson*(state: TriadRuntimeState): string =
  readProjectionLiveRestoreJson(
    state.legacyModel,
    state.shadowModel,
    state.runtimeProjectionReadSource())

proc writeRuntimeLiveRestoreState*(
    state: TriadRuntimeState;
    path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  writeProjectionLiveRestoreState(
    state.legacyModel,
    state.shadowModel,
    state.runtimeProjectionReadSource(),
    path)
