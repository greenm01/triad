import ../config/dod_apply
import ../config/parser
import ../core/effects
import ../core/msg
import ../core/restore_state
import ../state/dod_restore_state
import ../state/engine
import ../types/dod_runtime_policy
import ../types/dod_runtime_state
import ../types/layout_projection
import ../types/shell_snapshot
import dod_layout
import dod_update
import dod_window_lifecycle
import dod_workspaces

export dod_runtime_state
export dod_runtime_policy

type
  RuntimeStateInitResult* = object
    state*: TriadRuntimeState

  ObservedRuntimeUpdateResult* = object
    authority*: RuntimeAuthority
    effects*: seq[Effect]

  ObservedLayoutProjectionResult* = object
    authority*: LayoutAuthority
    ok*: bool
    projection*: LayoutProjection

  ObservedStateApplicationResult* = object
    authority*: StateApplicationAuthority
    ok*: bool

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
  result.authority = DodRuntimeAuthority
  result.effects = effects

proc applyObservedRuntimeLayoutProjection*(
    state: var TriadRuntimeState): ObservedLayoutProjectionResult =
  let projection = state.model.layoutProjection()
  state.model.applyLayoutProjection(projection)
  result.authority = DodLayoutAuthority
  result.ok = true
  result.projection = projection

proc applyObservedRuntimeConfig*(
    state: var TriadRuntimeState;
    config: Config): ObservedStateApplicationResult =
  state.model.applyConfig(config)
  result.authority = DodStateApplicationAuthority
  result.ok = true

proc applyObservedRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): ObservedStateApplicationResult =
  state.model.applyLiveRestore(restoreState.dodFromLiveRestore())
  result.authority = DodStateApplicationAuthority
  result.ok = true

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  state.model.dodShellSnapshot()

proc readRuntimeLiveRestoreJson*(state: TriadRuntimeState): string =
  state.model.dodLiveRestoreJson()

proc writeRuntimeLiveRestoreState*(
    state: TriadRuntimeState;
    path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  state.model.writeDodLiveRestoreState(path)
