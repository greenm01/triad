import ../core/effects
import ../core/msg
import ../state/engine
import dod_update_commands
import dod_update_effects
import dod_update_events
import dod_update_maintenance

proc dodUpdate*(model: DodModel; msg: Msg): (DodModel, seq[Effect]) =
  var next = model
  var effects: seq[Effect] = @[]
  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return (next, effects)

  let before = dodShellSnapshot(model)
  let step =
    case msg.kind
    of WlWindowCreated .. WlModifiersChanged:
      next.applyDodEvent(msg)
    of CmdSetLayout .. CmdScreenshot:
      next.applyDodCommand(msg)
  for effect in step.effects:
    effects.add(effect)
  var dirty = step.dirty

  let maintenance = next.applyDodUpdateMaintenance(msg.kind)
  if maintenance.collapsed or maintenance.pruned:
    dirty = true

  let after = dodShellSnapshot(next)
  effects.addPostUpdateEffects(
    msg, before, after, dirty, maintenance.collapsed, maintenance.pruned)

  (next, effects)
