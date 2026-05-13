import ../core/msg
import ../state/engine
import focus
import update_effects
import workspaces

proc applyUpdateMaintenance*(
    model: var Model, kind: MsgKind
): tuple[collapsed, pruned: bool] =
  result.collapsed =
    if kind.shouldCollapseAfterUpdate():
      model.collapseEmptyActiveDynamicWorkspace()
    else:
      false
  result.pruned = model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()
