import ../core/msg
import ../state/engine
import focus
import update_effects
import workspaces

proc applyUpdateMaintenance*(
    model: var Model, kind: MsgKind
): tuple[collapsed, pruned, outputCovered: bool] =
  result.collapsed =
    if kind.shouldCollapseAfterUpdate():
      model.collapseEmptyActiveDynamicWorkspace()
    else:
      false
  result.outputCovered = model.ensureOutputWorkspaceCoverage()
  result.pruned = model.pruneDynamicWorkspaces()
  result.outputCovered = model.ensureOutputWorkspaceCoverage() or result.outputCovered
  model.refreshVisibleWorkspaceSlots()
