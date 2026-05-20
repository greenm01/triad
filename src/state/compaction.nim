import std/[sets, tables]
import entity_manager
import ../types/model

proc compactSeq*[T](items: seq[T]): seq[T] =
  result = newSeqOfCap[T](items.len)
  for item in items:
    result.add(item)

proc compactSeqSeq[T](items: seq[seq[T]]): seq[seq[T]] =
  result = newSeqOfCap[seq[T]](items.len)
  for item in items:
    result.add(item.compactSeq())

proc compactTable*[K, V](items: var Table[K, V]) =
  var compacted = initTable[K, V](items.len)
  for key, value in items.pairs:
    compacted[key] = value
  items = compacted

proc compactTableSeq*[K, V](items: var Table[K, seq[V]]) =
  var compacted = initTable[K, seq[V]](items.len)
  for key, value in items.pairs:
    compacted[key] = value.compactSeq()
  items = compacted

proc compactHashSet*[T](items: var HashSet[T]) =
  var compacted = initHashSet[T](items.len)
  for item in items.items:
    compacted.incl(item)
  items = compacted

proc compactModelMemory*(model: var Model) =
  model.windows.compactEntityManager()
  model.tags.compactEntityManager()
  model.columns.compactEntityManager()
  model.frames.compactEntityManager()
  model.bspNodes.compactEntityManager()
  model.splitNodes.compactEntityManager()
  model.outputs.compactEntityManager()
  model.groups.compactEntityManager()

  model.windowTags.compactTable()
  model.externalWindowIds.compactTable()
  model.externalOutputIds.compactTable()
  model.tagBySlot.compactTable()
  model.columnsByTag.compactTableSeq()
  model.windowsByTag.compactTableSeq()
  model.windowsByColumn.compactTableSeq()
  model.placementByTagWindow.compactTable()
  model.frameRootsByTag.compactTable()
  model.windowsByFrame.compactTableSeq()
  model.frameByTagWindow.compactTable()
  model.bspRootsByTag.compactTable()
  model.bspNodeByTagWindow.compactTable()
  model.splitRootsByTag.compactTable()
  model.splitNodeByTagWindow.compactTable()
  model.outputTags.compactTable()
  model.tagOutputs.compactTable()
  model.tagHomeOutputTargets.compactTable()
  model.tagHomeOutputPinned.compactHashSet()
  model.outputLastActiveSlots.compactTable()
  model.groupByWindow.compactTable()
  model.scratchpadWindows = model.scratchpadWindows.compactSeq()
  model.namedScratchpads.compactTable()
  model.scratchpadRestoreTags.compactTable()
  model.swallowedBy.compactTable()
  model.swallowing.compactTable()

  model.visibleSlots = model.visibleSlots.compactSeq()
  model.overviewViewportSnapshot.compactTable()
  model.viewportRetargetTags.compactHashSet()
  model.viewportSnapTags.compactHashSet()
  model.pendingDialogFocusWindows = model.pendingDialogFocusWindows.compactSeq()
  model.scrollerProportionPresets = model.scrollerProportionPresets.compactSeq()
  model.environment = model.environment.compactSeq()
  model.startupCommands = model.startupCommands.compactSeqSeq()
  model.keyBindings = model.keyBindings.compactSeq()
  model.pointerBindings = model.pointerBindings.compactSeq()
  model.axisBindings = model.axisBindings.compactSeq()
  model.gestureBindings = model.gestureBindings.compactSeq()
  model.switchEvents = model.switchEvents.compactSeq()
  model.screenLockCommand = model.screenLockCommand.compactSeq()
  model.outputRules = model.outputRules.compactSeq()
  model.windowRules = model.windowRules.compactSeq()
  model.tagRules = model.tagRules.compactSeq()

  model.restoreTagByWindow.compactTable()
  model.restoreWindows.compactTable()
  model.restoreTags.compactTable()
  model.restoreOutputTags.compactTable()
  model.restoreScratchpadWindows = model.restoreScratchpadWindows.compactSeq()
  model.restoreNamedScratchpads.compactTable()
  model.restoreScratchpadSlots.compactTableSeq()
  model.restoreFocusHistory = model.restoreFocusHistory.compactSeq()
  model.restoreWorkspaceHistory = model.restoreWorkspaceHistory.compactSeq()
  model.restoreResolvedWindows.compactTable()
  model.restoreSwallowedBy.compactTable()
  model.restoreSwallowing.compactTable()

  model.layoutCycle = model.layoutCycle.compactSeq()
  model.layoutCycleSelections = model.layoutCycleSelections.compactSeq()
  model.customLayouts = model.customLayouts.compactSeq()
  model.focusHistory = model.focusHistory.compactSeq()
  model.recentWindowHistory = model.recentWindowHistory.compactSeq()
  model.workspaceHistory = model.workspaceHistory.compactSeq()
