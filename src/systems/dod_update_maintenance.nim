import ../core/msg
import ../state/engine
import dod_focus
import dod_update_effects
import dod_workspaces

proc applyDodUpdateMaintenance*(
    model: var DodModel; kind: MsgKind): tuple[collapsed, pruned: bool] =
  result.collapsed =
    if kind.shouldCollapseAfterUpdate():
      model.collapseEmptyActiveDynamicWorkspace()
    else:
      false
  result.pruned = model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()
