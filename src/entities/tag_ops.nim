import tables
import ../state/entity_manager
import ../state/id_gen
import ../types/core
import ../types/dod_model
from ../types/legacy_model import Scroller

proc addTag*(
    model: var DodModel; slot: uint32; name = ""; layoutMode = Scroller;
    focusedWindow = NullWindowId; targetViewportXOffset = 0.0'f32;
    currentViewportXOffset = 0.0'f32; targetViewportYOffset = 0.0'f32;
    currentViewportYOffset = 0.0'f32; masterCount = 1;
    masterSplitRatio = 0.55'f32): TagId =
  if model.tagBySlot.hasKey(slot):
    return model.tagBySlot[slot]

  let id = model.counters.generateTagId()
  let tag = TagData(
    id: id,
    slot: slot,
    bit: tagBit(slot),
    name: name,
    layoutMode: layoutMode,
    focusedWindow: focusedWindow,
    targetViewportXOffset: targetViewportXOffset,
    currentViewportXOffset: currentViewportXOffset,
    targetViewportYOffset: targetViewportYOffset,
    currentViewportYOffset: currentViewportYOffset,
    masterCount: max(1, masterCount),
    masterSplitRatio: max(0.05'f32, min(0.95'f32, masterSplitRatio))
  )
  model.tags.insert(tag)
  model.tagBySlot[slot] = id
  model.columnsByTag[id] = @[]
  model.windowsByTag[id] = @[]
  id
