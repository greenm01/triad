import options
import ../state/entity_manager
import ../types/core
import ../types/dod_model

proc setActiveWorkspace*(model: var DodModel; tagId: TagId): bool =
  if tagId == NullTagId:
    return false
  let tagOpt = model.tags.entity(tagId)
  if tagOpt.isNone:
    return false
  model.activeTag = tagId
  model.activeSlot = tagOpt.get().slot
  true

proc clearActiveWorkspaceIfTag*(model: var DodModel; tagId: TagId): bool =
  if tagId == NullTagId or model.activeTag != tagId:
    return false
  model.activeTag = NullTagId
  model.activeSlot = 0
  true

proc replaceVisibleWorkspaceSlots*(
    model: var DodModel; slots: seq[uint32]): bool =
  model.visibleSlots = slots
  true
