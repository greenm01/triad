import ../config/parser
import ../core/model
import ../core/msg
import ../core/restore_state
import ../core/shell_state
import ../state/dod_adapter
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

proc effectiveRuntimeAuthority(
    state: TriadRuntimeState; msg: Msg): RuntimeAuthority =
  if state.policy.runtimeAuthority == DodRuntimeAuthority and
      state.shadowHealth.shadowProjectionReadsEnabled() and
      msg.kind.shouldCheckEffectParity():
    DodRuntimeAuthority
  else:
    LegacyRuntimeAuthority

proc applyRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): RuntimeUpdateSyncResult =
  runtime_update_sync.syncRuntimeUpdate(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    state.effectiveRuntimeAuthority(msg))

proc applyRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg): RuntimeUpdateSyncResult =
  syncShadowOnlyMessage(
    state.legacyModel,
    state.shadowModel,
    msg,
    state.shadowHealth.shadowSyncEnabled(),
    state.effectiveRuntimeAuthority(msg))

proc fallBackToLegacyEffects(result: var RuntimeUpdateSyncResult) =
  result.authority = LegacyRuntimeAuthority
  result.authoritativeEffects = result.legacyEffects

proc applyObservedRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  result.syncResult = state.applyRuntimeUpdate(msg)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)
  if result.syncResult.authority == DodRuntimeAuthority and
      not result.observation.decision.reportOk:
    result.syncResult.fallBackToLegacyEffects()

proc applyObservedRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  result.syncResult = state.applyRuntimeShadowOnly(msg)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)
  if result.syncResult.authority == DodRuntimeAuthority and
      not result.observation.decision.reportOk:
    result.syncResult.fallBackToLegacyEffects()

proc effectiveLayoutAuthority(state: TriadRuntimeState): LayoutAuthority =
  if state.policy.layoutAuthority == DodLayoutAuthority and
      state.shadowHealth.shadowProjectionReadsEnabled():
    DodLayoutAuthority
  else:
    LegacyLayoutAuthority

proc applyRuntimeLayoutProjection*(
    state: var TriadRuntimeState): LayoutProjectionSyncReport =
  syncLayoutProjection(
    state.legacyModel,
    state.shadowModel,
    state.shadowHealth.shadowSyncEnabled(),
    state.effectiveLayoutAuthority())

proc applyObservedRuntimeLayoutProjection*(
    state: var TriadRuntimeState): ObservedLayoutProjectionResult =
  result.syncResult = state.applyRuntimeLayoutProjection()
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked,
    DodShadowReport(
      ok: result.syncResult.ok,
      errors: result.syncResult.errors))
  if result.syncResult.authority == DodLayoutAuthority and
      not result.observation.decision.reportOk:
    result.syncResult.authority = LegacyLayoutAuthority
    result.syncResult.authoritativeProjection =
      result.syncResult.legacyProjection

proc effectiveStateApplicationAuthority(
    state: TriadRuntimeState): StateApplicationAuthority =
  if state.policy.stateApplicationAuthority == DodStateApplicationAuthority and
      state.shadowHealth.shadowProjectionReadsEnabled():
    DodStateApplicationAuthority
  else:
    LegacyStateApplicationAuthority

proc applyRuntimeConfig*(
    state: var TriadRuntimeState; config: Config): StateApplicationSyncResult =
  syncConfigApplication(
    state.legacyModel,
    state.shadowModel,
    config,
    state.shadowHealth.shadowSyncEnabled(),
    state.effectiveStateApplicationAuthority())

proc fallBackToLegacyStateApplication(result: var StateApplicationSyncResult) =
  result.authority = LegacyStateApplicationAuthority

proc applyObservedRuntimeConfig*(
    state: var TriadRuntimeState;
    config: Config): ObservedStateApplicationResult =
  result.syncResult = state.applyRuntimeConfig(config)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)
  if result.syncResult.authority == DodStateApplicationAuthority and
      not result.observation.decision.reportOk:
    result.syncResult.fallBackToLegacyStateApplication()

proc applyRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): StateApplicationSyncResult =
  syncLiveRestoreApplication(
    state.legacyModel,
    state.shadowModel,
    restoreState,
    state.shadowHealth.shadowSyncEnabled(),
    state.effectiveStateApplicationAuthority())

proc applyObservedRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): ObservedStateApplicationResult =
  result.syncResult = state.applyRuntimeLiveRestore(restoreState)
  result.observation = state.observeShadowReport(
    result.syncResult.shadowChecked, result.syncResult.shadowReport)
  if result.syncResult.authority == DodStateApplicationAuthority and
      not result.observation.decision.reportOk:
    result.syncResult.fallBackToLegacyStateApplication()

proc runtimeProjectionReadSource*(
    state: TriadRuntimeState): ProjectionReadSource =
  projectionReadSource(state.shadowHealth)

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  readProjectionSnapshot(
    state.legacyModel,
    state.shadowModel,
    state.runtimeProjectionReadSource())

proc readRuntimeModelView*(state: TriadRuntimeState): Model =
  case state.runtimeProjectionReadSource()
  of LegacyProjectionSource:
    state.legacyModel
  of DodProjectionSource:
    legacyViewFromDod(state.shadowModel, state.legacyModel)

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
