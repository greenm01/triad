import ../config/[apply, parser]
import ../core/[effects, msg, restore_state]
import ../state/engine
import ../types/[janet_layouts, layout_projection, runtime_state, shell_snapshot]
import ../utils/behavior_log
import layout_projection, update, window_lifecycle, workspaces

export runtime_state

proc initRuntimeStateFromConfig*(
    config: Config, activeTag: uint32 = 1
): TriadRuntimeState =
  var model = Model(activeSlot: activeTag, startupWindowRulesActive: true)
  model.applyConfig(config)
  discard model.ensureActiveWorkspace()
  if model.shouldShowHotkeyOverlayAtStartup():
    discard model.setHotkeyOverlayOpen(true)
  TriadRuntimeState(model: model)

proc applyRuntimeUpdate*(
    state: var TriadRuntimeState, msg: Msg, movementEval: CustomLayoutMovementEval = nil
): seq[Effect] =
  state.model.updateInPlace(msg, movementEval)

proc applyRuntimeLayoutProjection*(
    state: var TriadRuntimeState,
    context = "",
    msgKind = "",
    layoutEval: CustomLayoutEval = nil,
): LayoutProjection =
  result = state.model.layoutProjection(layoutEval)
  if behaviorLogEnabled():
    let snapshot = state.model.shellSnapshot()
    snapshot.writeLayoutProjectionBehaviorEvent(result, context, msgKind)
  state.model.applyLayoutProjection(result)

proc applyRuntimeConfig*(state: var TriadRuntimeState, config: Config): bool =
  state.model.outputStartupFocusResolved = true
  state.model.applyConfig(config)
  true

proc applyRuntimeLiveRestore*(
    state: var TriadRuntimeState, restoreState: LiveRestoreState
): bool =
  state.model.applyLiveRestore(restoreState.pendingRestoreState())
  true

proc readRuntimeSnapshot*(state: TriadRuntimeState): ShellSnapshot =
  state.model.shellSnapshot()

proc readRuntimeWindowSnapshot*(
    state: TriadRuntimeState, externalWindowId: uint32
): ShellSnapshot =
  state.model.shellWindowSnapshotForExternal(ExternalWindowId(externalWindowId))

proc readRuntimeLiveRestoreJson*(state: TriadRuntimeState): string =
  state.model.liveRestoreJson()

proc pendingAdmissionWindowIds*(state: TriadRuntimeState): seq[uint32] =
  for externalId in state.model.pendingAdmissionExternalIds():
    result.add(uint32(externalId))

proc hasPendingAdmissionWindow*(state: TriadRuntimeState): bool =
  state.model.hasPendingAdmissionWindow()

proc writeRuntimeLiveRestoreState*(
    state: TriadRuntimeState, path = defaultLiveRestorePath()
): LiveRestoreWriteResult =
  state.model.writeLiveRestoreState(path)
