import std/options
import ../state/entity_manager
import ../types/[core, model]

proc setActiveWorkspace*(model: var Model; tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  model.activeTag = tagId
  model.activeSlot = tagOpt.get().slot
  true

proc clearActiveWorkspaceIfTag*(model: var Model; tagId: TagId): bool =
  if tagId == NullTagId or model.activeTag != tagId:
    return false
  model.activeTag = NullTagId
  model.activeSlot = 0
  true

proc replaceVisibleWorkspaceSlots*(
    model: var Model; slots: seq[uint32]): bool =
  model.visibleSlots = slots
  true
