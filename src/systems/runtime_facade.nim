import ../config/apply
import ../config/parser
import ../core/effects
import ../core/msg
import ../core/restore_state
import ../state/engine
import ../types/runtime_state
import ../types/layout_projection
import ../types/shell_snapshot
import layout_projection
import update
import window_lifecycle
import workspaces

export runtime_state

proc initRuntimeStateFromConfig*(
    config: Config; activeTag: uint32 = 1): TriadRuntimeState =
  var model = Model(activeSlot: activeTag)
  model.applyConfig(config)
  discard model.ensureActiveWorkspace()
  TriadRuntimeState(model: model)

proc applyRuntimeUpdate*(
    state: var TriadRuntimeState; msg: Msg): seq[Effect] =
  let (next, effects) = state.model.update(msg)
  state.model = next
  effects

proc applyRuntimeLayoutProjection*(
    state: var TriadRuntimeState): LayoutProjection =
  result = state.model.layoutProjection()
  state.model.applyLayoutProjection(result)

proc applyRuntimeConfig*(
    state: var TriadRuntimeState;
    config: Config): bool =
  state.model.applyConfig(config)
  true

proc applyRuntimeLiveRestore*(
    state: var TriadRuntimeState;
    restoreState: LiveRestoreState): bool =
  state.model.applyLiveRestore(restoreState.pendingRestoreState())
  true

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  state.model.shellSnapshot()

proc readRuntimeLiveRestoreJson*(state: TriadRuntimeState): string =
  state.model.liveRestoreJson()

proc writeRuntimeLiveRestoreState*(
    state: TriadRuntimeState;
    path = defaultLiveRestorePath()): LiveRestoreWriteResult =
  state.model.writeLiveRestoreState(path)
