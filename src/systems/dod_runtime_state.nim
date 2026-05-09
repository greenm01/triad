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
export dod_shadow_health

type
  RuntimeShadowObservation* = object
    checked*: bool
    report*: DodShadowReport
    decision*: DodShadowHealthDecision

  RuntimeStateInitResult* = object
    state*: TriadRuntimeState
    shadowChecked*: bool
    shadowReport*: DodShadowReport
    observation*: RuntimeShadowObservation

  ObservedRuntimeUpdateResult* = object
    syncResult*: RuntimeUpdateSyncResult
    observation*: RuntimeShadowObservation

  ObservedLayoutProjectionResult* = object
    syncResult*: LayoutProjectionSyncReport
    observation*: RuntimeShadowObservation

  ObservedStateApplicationResult* = object
    syncResult*: StateApplicationSyncResult
    observation*: RuntimeShadowObservation

proc observeShadowReport*(
    state: var TriadRuntimeState; checked: bool;
    report: DodShadowReport): RuntimeShadowObservation =
  result.checked = checked
  result.report = report
  result.decision = DodShadowHealthDecision(
    reportOk: report.ok,
    divergenceCount: state.shadowHealth.divergenceCount)
  if checked:
    result.decision = state.shadowHealth.applyShadowReport(report)

proc initRuntimeStateFromConfig*(
    config: Config; activeTag: uint32 = 1): RuntimeStateInitResult =
  let syncResult = syncInitialConfigApplication(config, activeTag)
  result.state = TriadRuntimeState(
    legacyModel: syncResult.legacyModel,
    shadowModel: syncResult.shadowModel,
    shadowHealth: initDodShadowHealth(),
    policy: defaultTriadRuntimePolicy())
  result.shadowChecked = syncResult.shadowChecked
  result.shadowReport = syncResult.shadowReport
  result.observation = result.state.observeShadowReport(
    syncResult.shadowChecked, syncResult.shadowReport)

proc applyRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): RuntimeUpdateSyncResult =
  runtime_update_sync.syncRuntimeUpdate(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    state.policy.runtimeAuthority)

proc applyRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg): RuntimeUpdateSyncResult =
  syncShadowOnlyMessage(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    state.policy.runtimeAuthority)

proc applyObservedRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  result.syncResult = state.applyRuntimeUpdate(msg)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)

proc applyObservedRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  result.syncResult = state.applyRuntimeShadowOnly(msg)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)

proc applyRuntimeLayoutProjection*(
    state: var TriadRuntimeState): LayoutProjectionSyncReport =
  syncLayoutProjection(
    state.legacyModel,
    state.shadowModel,
    state.shadowHealth.shadowSyncEnabled(),
    state.policy.layoutAuthority)

proc applyObservedRuntimeLayoutProjection*(
    state: var TriadRuntimeState): ObservedLayoutProjectionResult =
  result.syncResult = state.applyRuntimeLayoutProjection()
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked,
    DodShadowReport(
      ok: result.syncResult.ok,
      errors: result.syncResult.errors))

proc applyRuntimeConfig*(
    state: var TriadRuntimeState; config: Config): StateApplicationSyncResult =
  syncConfigApplication(
    state.legacyModel,
    state.shadowModel,
    config,
    state.shadowHealth.shadowSyncEnabled())

proc applyObservedRuntimeConfig*(
    state: var TriadRuntimeState;
    config: Config): ObservedStateApplicationResult =
  result.syncResult = state.applyRuntimeConfig(config)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)

proc applyRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): StateApplicationSyncResult =
  syncLiveRestoreApplication(
    state.legacyModel,
    state.shadowModel,
    restoreState,
    state.shadowHealth.shadowSyncEnabled())

proc applyObservedRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): ObservedStateApplicationResult =
  result.syncResult = state.applyRuntimeLiveRestore(restoreState)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)

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
