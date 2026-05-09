import ../core/effects
import ../core/msg
import ../state/engine
import update_commands
import update_effects
import update_events
import update_maintenance

proc update*(model: Model; msg: Msg): (Model, seq[Effect]) =
  var next = model
  var effects: seq[Effect] = @[]
  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return (next, effects)

  let before = shellSnapshot(model)
  let step =
    case msg.kind
    of MsgKind.WlWindowCreated .. MsgKind.WlModifiersChanged:
      next.applyEvent(msg)
    of MsgKind.CmdSetLayout .. MsgKind.CmdScreenshot:
      next.applyCommand(msg)
  for effect in step.effects:
    effects.add(effect)
  var dirty = step.dirty

  let maintenance = next.applyUpdateMaintenance(msg.kind)
  if maintenance.collapsed or maintenance.pruned:
    dirty = true

  let after = shellSnapshot(next)
  effects.addPostUpdateEffects(
    msg, before, after, dirty, maintenance.collapsed, maintenance.pruned)

  (next, effects)
