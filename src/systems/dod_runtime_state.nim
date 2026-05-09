import ../config/dod_apply
import ../config/parser
import ../core/model
import ../core/msg
import ../core/restore_state
import ../core/shell_state
import ../state/dod_adapter
import ../state/dod_restore_state
import ../state/engine
import ../types/dod_runtime_policy
import ../types/dod_runtime_state
import dod_layout
import dod_update
import dod_window_lifecycle
import dod_workspaces
import layout_projection_sync
import runtime_update_sync
import state_application_sync

export dod_runtime_state
export dod_runtime_policy

type
  RuntimeStateInitResult* = object
    state*: TriadRuntimeState

  ObservedRuntimeUpdateResult* = object
    syncResult*: RuntimeUpdateSyncResult

  ObservedLayoutProjectionResult* = object
    syncResult*: LayoutProjectionSyncReport

  ObservedStateApplicationResult* = object
    syncResult*: StateApplicationSyncResult

proc initRuntimeStateFromConfig*(
    config: Config; activeTag: uint32 = 1): RuntimeStateInitResult =
  var model = DodModel(activeSlot: activeTag)
  model.applyConfig(config)
  discard model.ensureActiveWorkspace()
  result.state = TriadRuntimeState(model: model)

proc applyObservedRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  let (next, effects) = state.model.dodUpdate(msg)
  state.model = next
  result.syncResult = RuntimeUpdateSyncResult(
    authority: DodRuntimeAuthority,
    dodEffects: effects,
    authoritativeEffects: effects)

proc applyObservedRuntimeShadowOnly*(
    state: var TriadRuntimeState; msg: Msg): ObservedRuntimeUpdateResult =
  state.applyObservedRuntimeUpdate(msg)

proc applyObservedRuntimeLayoutProjection*(
    state: var TriadRuntimeState): ObservedLayoutProjectionResult =
  let projection = state.model.layoutProjection()
  state.model.applyLayoutProjection(projection)
  result.syncResult = LayoutProjectionSyncReport(
    authority: DodLayoutAuthority,
    ok: true,
    dodProjection: projection,
    authoritativeProjection: projection)

proc applyObservedRuntimeConfig*(
    state: var TriadRuntimeState;
    config: Config): ObservedStateApplicationResult =
  state.model.applyConfig(config)
  result.syncResult = StateApplicationSyncResult(
    authority: DodStateApplicationAuthority)

proc applyObservedRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): ObservedStateApplicationResult =
  state.model.applyLiveRestore(restoreState.dodFromLiveRestore())
  result.syncResult = StateApplicationSyncResult(
    authority: DodStateApplicationAuthority)

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  state.model.dodShellSnapshot()

proc readRuntimeModelView*(state: TriadRuntimeState): Model =
  # Transitional read view for daemon helpers that still consume legacy shapes.
  legacyViewFromDod(state.model, Model())

proc readRuntimeLiveRestoreJson*(state: TriadRuntimeState): string =
  state.model.dodLiveRestoreJson()

proc writeRuntimeLiveRestoreState*(
    state: TriadRuntimeState;
    path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  state.model.writeDodLiveRestoreState(path)
