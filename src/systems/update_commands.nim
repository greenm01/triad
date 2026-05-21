import std/[options, strutils]
import ../core/[effects, msg, shell_profiles]
import ../state/engine
import ../types/janet_layouts
from ../types/runtime_values import
  Direction, FrameSplitOrientation, JanetLayoutId, LayoutMode, RecentWindowDirection,
  NativeLayoutId, SplitTreeNodeMode
import
  dialog_focus, focus, output_navigation, placement, recent_windows, runtime,
  scratchpad, update_effects, window_state, window_rules, workspaces

proc closeOverview(model: var Model): bool =
  model.closeOverviewMode()

proc openOverview(model: var Model): bool =
  if model.overviewActive:
    return false
  discard model.setOverviewTabModeActive(false, 0'u32)
  discard model.setOverviewWorkspacePreviewsActive(true)
  result = model.setOverviewActive(true)
  if result:
    discard model.clearOverviewSelection()

proc recomputeAllTagFocus(model: var Model) =
  for tagId, _ in model.tagsWithId():
    discard model.recomputeVisibleFocus(tagId)

proc configuredKeyboardLayoutCount(model: Model): uint32 =
  let xkb = model.input.keyboard.xkb
  if not xkb.layoutSet:
    return 0
  for name in xkb.layout.split(','):
    if name.strip().len > 0:
      inc result

proc switchKeyboardLayout(
    model: var Model, delta: int32, index: int32
): tuple[changed: bool, activeIndex: uint32] =
  let count = model.configuredKeyboardLayoutCount()
  if count == 0:
    return (false, 0'u32)
  let current = min(model.keyboardLayoutIndex, count - 1)
  let next =
    if index >= 0:
      min(uint32(index), count - 1)
    else:
      uint32((int32(current) + delta + int32(count)) mod int32(count))
  if next == model.keyboardLayoutIndex:
    return (false, next)
  model.keyboardLayoutIndex = next
  (true, next)

proc showLayoutSwitchToast(
    model: var Model,
    layout: LayoutMode,
    customLayout = JanetLayoutId(""),
    nativeLayout = NativeLayoutId(""),
): bool =
  model.openLayoutSwitchToast(layout, customLayout, nativeLayout)

proc showActiveLayoutSwitchToast(model: var Model): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone:
    return false
  let tag = tagOpt.get()
  model.showLayoutSwitchToast(tag.layoutMode, tag.customLayoutId, tag.nativeLayoutId)

proc activeSpawnPlacementContext(model: Model): tuple[outputId: uint32, slot: uint32] =
  var outputId =
    if model.activeOutput != NullOutputId and model.hasOutput(model.activeOutput):
      model.activeOutput
    elif model.primaryOutput != NullOutputId and model.hasOutput(model.primaryOutput):
      model.primaryOutput
    else:
      NullOutputId
  var slot = 0'u32
  if outputId != NullOutputId:
    let tagId = model.outputActiveTag(outputId)
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome:
      slot = tagOpt.get().slot
  if slot == 0:
    slot = model.activeWorkspaceSlot()
  (uint32(outputId), slot)

proc applyCommand*(
    model: var Model, msg: Msg, movementEval: CustomLayoutMovementEval = nil
): UpdateStep =
  case msg.kind
  of MsgKind.CmdSetLayout:
    result.dirty = model.setLayoutForSlot(msg.layoutTargetTag, msg.newLayout)
    if result.dirty and msg.layoutTargetTag == 0:
      result.dirty = model.showLayoutSwitchToast(msg.newLayout) or result.dirty
  of MsgKind.CmdSetCustomLayout:
    result.dirty =
      model.setCustomLayoutForSlot(msg.customLayoutTargetTag, msg.customLayout)
    if result.dirty and msg.customLayoutTargetTag == 0:
      let custom = model.customLayoutConfig(msg.customLayout)
      if custom.isSome:
        result.dirty =
          model.showLayoutSwitchToast(custom.get().fallback.builtin, msg.customLayout) or
          result.dirty
  of MsgKind.CmdSetNativeLayout:
    result.dirty =
      model.setNativeLayoutForSlot(msg.nativeLayoutTargetTag, msg.nativeLayout)
    if result.dirty and msg.nativeLayoutTargetTag == 0:
      let native = model.nativeLayoutConfig(msg.nativeLayout)
      if native.isSome:
        result.dirty =
          model.showLayoutSwitchToast(
            native.get().fallback.builtin, nativeLayout = native.get().id
          ) or result.dirty
  of MsgKind.CmdFrameSplitHorizontal:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedFrame(FrameSplitOrientation.Horizontal)
  of MsgKind.CmdFrameSplitVertical:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedFrame(FrameSplitOrientation.Vertical)
  of MsgKind.CmdFrameUnsplit:
    result.dirty = not model.overviewActive and model.unsplitFocusedFrame()
  of MsgKind.CmdFrameTabNext:
    result.dirty =
      not model.overviewActive and (
        if model.activeTagUsesSplitTree():
          model.focusSplitTreeTab(1)
        else:
          model.focusFrameTab(1)
      )
  of MsgKind.CmdFrameTabPrev:
    result.dirty =
      not model.overviewActive and (
        if model.activeTagUsesSplitTree():
          model.focusSplitTreeTab(-1)
        else:
          model.focusFrameTab(-1)
      )
  of MsgKind.CmdFrameResizeLeft:
    result.dirty =
      not model.overviewActive and
      model.adjustFocusedFrameSplit(
        model.activeTag, FrameSplitOrientation.Horizontal, -msg.frameResizeDelta
      )
  of MsgKind.CmdFrameResizeRight:
    result.dirty =
      not model.overviewActive and
      model.adjustFocusedFrameSplit(
        model.activeTag, FrameSplitOrientation.Horizontal, msg.frameResizeDelta
      )
  of MsgKind.CmdFrameResizeUp:
    result.dirty =
      not model.overviewActive and
      model.adjustFocusedFrameSplit(
        model.activeTag, FrameSplitOrientation.Vertical, -msg.frameResizeDelta
      )
  of MsgKind.CmdFrameResizeDown:
    result.dirty =
      not model.overviewActive and
      model.adjustFocusedFrameSplit(
        model.activeTag, FrameSplitOrientation.Vertical, msg.frameResizeDelta
      )
  of MsgKind.CmdFrameSplitToggle:
    result.dirty =
      not model.overviewActive and
      model.toggleFocusedFrameSplitOrientation(model.activeTag)
  of MsgKind.CmdFrameFocusParent:
    result.dirty =
      not model.overviewActive and model.activeTagUsesFrameTree() and
      model.focusFrameParent()
  of MsgKind.CmdFrameFocusChild:
    result.dirty =
      not model.overviewActive and model.activeTagUsesFrameTree() and
      model.focusFrameChild()
  of MsgKind.CmdFrameBindApp:
    let tagId = model.activeTag
    let focusedWin = model.focusedOnActiveTag()
    if not model.overviewActive and model.activeTagUsesFrameTree() and tagId != NullTagId and
        focusedWin != NullWindowId:
      let winOpt = model.windowData(focusedWin)
      let frameId = model.tagData(tagId).get().focusedFrame
      if winOpt.isSome and frameId != NullFrameId:
        result.dirty = model.bindAppToFrame(tagId, winOpt.get().appId, frameId)
  of MsgKind.CmdFrameUnbindApp:
    let tagId = model.activeTag
    let focusedWin = model.focusedOnActiveTag()
    if not model.overviewActive and model.activeTagUsesFrameTree() and tagId != NullTagId and
        focusedWin != NullWindowId:
      let winOpt = model.windowData(focusedWin)
      if winOpt.isSome:
        result.dirty = model.unbindAppFromFrame(tagId, winOpt.get().appId)
  of MsgKind.CmdSplitTreeSplitHorizontal:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedSplitTree(FrameSplitOrientation.Horizontal)
  of MsgKind.CmdSplitTreeSplitVertical:
    result.dirty =
      not model.overviewActive and
      model.splitFocusedSplitTree(FrameSplitOrientation.Vertical)
  of MsgKind.CmdSplitTreeSplitToggle:
    result.dirty =
      not model.overviewActive and (
        if model.activeTagUsesSplitTree():
          let nodeId = model.focusedSplitLeafOrRoot(model.activeTag)
          if nodeId != NullSplitNodeId:
            let node = model.splitNodeData(nodeId)
            if node.isSome and node.get().parent != NullSplitNodeId:
              let parent = model.splitNodeData(node.get().parent)
              if parent.isSome and parent.get().mode == SplitTreeNodeMode.SplitH:
                model.splitFocusedSplitTree(FrameSplitOrientation.Vertical)
              else:
                model.splitFocusedSplitTree(FrameSplitOrientation.Horizontal)
            else:
              model.splitFocusedSplitTree(FrameSplitOrientation.Vertical)
          else:
            model.splitFocusedSplitTree(FrameSplitOrientation.Vertical)
        else:
          false
      )
  of MsgKind.CmdSplitTreeLayoutSplitHorizontal:
    result.dirty =
      not model.overviewActive and
      model.setFocusedSplitTreeLayoutMode(SplitTreeNodeMode.SplitH)
  of MsgKind.CmdSplitTreeLayoutSplitVertical:
    result.dirty =
      not model.overviewActive and
      model.setFocusedSplitTreeLayoutMode(SplitTreeNodeMode.SplitV)
  of MsgKind.CmdSplitTreeLayoutToggleSplit:
    result.dirty =
      not model.overviewActive and model.toggleFocusedSplitTreeSplitLayout()
  of MsgKind.CmdSplitTreeLayoutStacking:
    result.dirty =
      not model.overviewActive and
      model.setFocusedSplitTreeLayoutMode(SplitTreeNodeMode.Stacking)
  of MsgKind.CmdSplitTreeLayoutTabbed:
    result.dirty =
      not model.overviewActive and
      model.setFocusedSplitTreeLayoutMode(SplitTreeNodeMode.Tabbed)
  of MsgKind.CmdSplitTreeFocusParent:
    result.dirty =
      not model.overviewActive and model.activeTagUsesSplitTree() and
      model.focusSplitTreeParent()
  of MsgKind.CmdSplitTreeFocusChild:
    result.dirty =
      not model.overviewActive and model.activeTagUsesSplitTree() and
      model.focusSplitTreeChild()
  of MsgKind.CmdSplitTreeLayoutCycleAll:
    result.dirty = not model.overviewActive and model.cycleFocusedSplitTreeLayoutAll()
  of MsgKind.CmdSplitTreeLayoutDefault:
    result.dirty =
      not model.overviewActive and
      model.setFocusedSplitTreeLayoutMode(SplitTreeNodeMode.SplitH)
  of MsgKind.CmdSplitTreeLayoutCycleList:
    result.dirty =
      not model.overviewActive and model.cycleFocusedSplitTreeLayoutList(msg.cycleModes)
  of MsgKind.CmdSplitTreeFocusNextSibling:
    result.dirty =
      not model.overviewActive and model.activeTagUsesSplitTree() and
      model.focusSplitTreeSibling(1)
  of MsgKind.CmdSplitTreeFocusPrevSibling:
    result.dirty =
      not model.overviewActive and model.activeTagUsesSplitTree() and
      model.focusSplitTreeSibling(-1)
  of MsgKind.CmdBspBalance:
    result.dirty = not model.overviewActive and model.balanceBspTree(model.activeTag)
  of MsgKind.CmdBspEqualize:
    result.dirty = not model.overviewActive and model.equalizeBspTree(model.activeTag)
  of MsgKind.CmdBspPreselect:
    result.dirty =
      not model.overviewActive and
      model.setFocusedBspPreselection(msg.bspPreselectDirection)
  of MsgKind.CmdBspPreselectCancel:
    result.dirty = not model.overviewActive and model.cancelFocusedBspPreselection()
  of MsgKind.CmdBspPreselectRatio:
    result.dirty =
      not model.overviewActive and
      model.setFocusedBspPreselectionRatio(msg.bspPreselectRatio)
  of MsgKind.CmdSwitchLayout:
    result.dirty = model.switchLayout()
    if result.dirty:
      result.dirty = model.showActiveLayoutSwitchToast() or result.dirty
  of MsgKind.CmdSetMasterCount:
    result.dirty = model.setMasterCount(msg.count)
  of MsgKind.CmdAdjustMasterCount:
    result.dirty = model.adjustMasterCount(msg.deltaMC)
  of MsgKind.CmdSetMasterRatio:
    result.dirty = model.setMasterRatio(msg.ratio)
  of MsgKind.CmdAdjustMasterRatio:
    result.dirty = model.adjustMasterRatio(msg.deltaMR)
  of MsgKind.CmdMaximizeColumn:
    result.dirty = model.toggleFocusedColumnFullWidth()
  of MsgKind.CmdResizeWidth:
    result.dirty = model.resizeWidth(msg.deltaW)
  of MsgKind.CmdResizeHeight:
    result.dirty = model.resizeHeight(msg.deltaH)
  of MsgKind.CmdSetColumnWidth:
    result.dirty = model.setFocusedColumnWidth(msg.targetWidth)
  of MsgKind.CmdSwitchProportionPreset:
    result.dirty = model.switchProportionPreset(msg.proportionPresetDelta)
  of MsgKind.CmdRenameTag:
    result.dirty = model.renameActiveWorkspace(msg.newName)
    if result.dirty:
      result.effects.add(broadcastWorkspaceActivated(shellSnapshot(model)))
  of MsgKind.CmdGroupWindows:
    result.dirty = model.groupFocusedWindow()
  of MsgKind.CmdUngroupWindow:
    result.dirty = model.ungroupFocusedWindow()
  of MsgKind.CmdFocusNextInGroup:
    result.dirty = model.focusNextInGroup()
  of MsgKind.CmdFocusNext:
    result.dirty = model.focusCycle(1)
  of MsgKind.CmdFocusPrev:
    result.dirty = model.focusCycle(-1)
  of MsgKind.CmdFocusDirection:
    result.dirty = model.focusByDirection(msg.direction)
  of MsgKind.CmdFocusLast:
    result.dirty = model.focusLast()
  of MsgKind.CmdFocusTagLeft:
    result.dirty =
      if model.overviewActive:
        model.focusOverviewWorkspaceStep(-1)
      else:
        model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdFocusTagRight:
    result.dirty =
      if model.overviewActive:
        model.focusOverviewWorkspaceStep(1)
      else:
        model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdFocusOccupiedTagLeft:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(-1, true))
  of MsgKind.CmdFocusOccupiedTagRight:
    result.dirty = model.focusWorkspaceSlot(model.nearestWorkspaceSlot(1, true))
  of MsgKind.CmdFocusColumnFirst:
    result.dirty = model.focusColumnAtEdge(true)
  of MsgKind.CmdFocusColumnLast:
    result.dirty = model.focusColumnAtEdge(false)
  of MsgKind.CmdFocusWindowOrWorkspaceUp:
    result.dirty =
      if model.overviewActive:
        model.focusByDirection(Direction.DirUp)
      else:
        model.focusWindowOrWorkspace(-1)
  of MsgKind.CmdFocusWindowOrWorkspaceDown:
    result.dirty =
      if model.overviewActive:
        model.focusByDirection(Direction.DirDown)
      else:
        model.focusWindowOrWorkspace(1)
  of MsgKind.CmdFocusTag:
    result.dirty = model.focusWorkspaceSlot(msg.focusTag)
  of MsgKind.CmdFocusWorkspaceIndex:
    result.dirty = model.focusWorkspaceIndex(msg.workspaceIndex)
  of MsgKind.CmdNewWorkspace:
    result.dirty = model.focusNewWorkspaceOnActiveOutput()
  of MsgKind.CmdReorderWorkspaceIndex:
    result.dirty =
      model.reorderWorkspaceIndex(msg.reorderWorkspaceIndex, msg.reorderTargetIndex)
  of MsgKind.CmdFocusOutput:
    result.dirty = model.focusOutputTarget(msg.outputTarget)
  of MsgKind.CmdMoveWorkspaceToOutput:
    result.dirty = model.moveActiveWorkspaceToOutputTarget(msg.outputTarget)
  of MsgKind.CmdMoveToOutput:
    result.dirty = model.moveFocusedWindowToOutputTarget(msg.outputTarget)
  of MsgKind.CmdFocusWindowById:
    result.dirty = model.focusExternalWindow(msg.focusWindowId.externalWindowId())
  of MsgKind.CmdMoveToTag:
    result.dirty = model.moveFocusedWindowToSlotAndFocus(msg.targetTag)
  of MsgKind.CmdMoveWindowToTag:
    let winId = model.windowForExternal(ExternalWindowId(msg.moveWindowId))
    if winId != NullWindowId and model.moveWindowToSlot(winId, msg.moveTargetTag):
      result.dirty = true
      if msg.moveFollowWindow:
        result.dirty = model.focusWindow(winId) or result.dirty
  of MsgKind.CmdSwapWindowToTag:
    result.dirty = model.swapFocusedWindowToSlot(msg.targetTagSwap)
  of MsgKind.CmdMoveToTagLeft:
    result.dirty =
      model.moveFocusedWindowToSlotAndFocus(model.nearestWorkspaceSlot(-1, false))
  of MsgKind.CmdMoveToTagRight:
    result.dirty =
      model.moveFocusedWindowToSlotAndFocus(model.nearestWorkspaceSlot(1, false))
  of MsgKind.CmdMoveToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.workspaceIndex)
    result.dirty = slot != 0 and model.moveFocusedWindowToSlotAndFocus(slot)
  of MsgKind.CmdMoveWindowToWorkspaceIndex:
    let slot = model.workspaceSlotForClampedIndex(msg.moveWorkspaceIndex)
    let winId = model.windowForExternal(ExternalWindowId(msg.moveWorkspaceWindowId))
    if slot != 0 and winId != NullWindowId and model.moveWindowToSlot(winId, slot):
      result.dirty = true
      if msg.moveWorkspaceFollowWindow:
        result.dirty = model.focusWindow(winId) or result.dirty
  of MsgKind.CmdMoveWindowLeft:
    let focusedLeft = model.focusedOnActiveTag()
    result.dirty =
      (
        model.activeTagUsesSplitTree() and focusedLeft != NullWindowId and
        model.moveWindowInSplitTree(model.activeTag, focusedLeft, Direction.DirLeft)
      ) or model.moveFocusedWindowLeft(movementEval)
  of MsgKind.CmdMoveWindowRight:
    let focusedRight = model.focusedOnActiveTag()
    result.dirty =
      (
        model.activeTagUsesSplitTree() and focusedRight != NullWindowId and
        model.moveWindowInSplitTree(model.activeTag, focusedRight, Direction.DirRight)
      ) or model.moveFocusedWindowRight(movementEval)
  of MsgKind.CmdMoveWindowUp:
    let focusedUp = model.focusedOnActiveTag()
    result.dirty =
      (
        model.activeTagUsesSplitTree() and focusedUp != NullWindowId and
        model.moveWindowInSplitTree(model.activeTag, focusedUp, Direction.DirUp)
      ) or model.moveFocusedWindowUp(movementEval)
  of MsgKind.CmdMoveWindowDown:
    let focusedDown = model.focusedOnActiveTag()
    result.dirty =
      (
        model.activeTagUsesSplitTree() and focusedDown != NullWindowId and
        model.moveWindowInSplitTree(model.activeTag, focusedDown, Direction.DirDown)
      ) or model.moveFocusedWindowDown(movementEval)
  of MsgKind.CmdMoveWindowUpOrToWorkspaceUp:
    result.dirty = model.moveFocusedWindowUpOrWorkspace(movementEval)
  of MsgKind.CmdMoveWindowDownOrToWorkspaceDown:
    result.dirty = model.moveFocusedWindowDownOrWorkspace(movementEval)
  of MsgKind.CmdMoveColumnLeft:
    result.dirty = model.moveFocusedColumnLeft()
  of MsgKind.CmdMoveColumnRight:
    result.dirty = model.moveFocusedColumnRight()
  of MsgKind.CmdMoveColumnToFirst:
    result.dirty = model.moveFocusedColumnToFirst()
  of MsgKind.CmdMoveColumnToLast:
    result.dirty = model.moveFocusedColumnToLast()
  of MsgKind.CmdSwapWindowUp:
    result.dirty = model.moveFocusedWindowUp(movementEval)
  of MsgKind.CmdSwapWindowDown:
    result.dirty = model.moveFocusedWindowDown(movementEval)
  of MsgKind.CmdConsumeWindow:
    result.dirty = model.consumeNextColumnWindow()
  of MsgKind.CmdExpelWindow:
    result.dirty = model.expelFocusedWindow()
  of MsgKind.CmdZoom:
    result.dirty = model.zoomFocusedWindow()
  of MsgKind.CmdMoveToScratchpad:
    result.dirty = model.moveFocusedToScratchpad()
  of MsgKind.CmdMoveToNamedScratchpad:
    result.dirty = model.moveFocusedToScratchpad(msg.scratchpadName)
  of MsgKind.CmdToggleScratchpad:
    result.dirty = model.toggleScratchpad()
  of MsgKind.CmdToggleNamedScratchpad:
    result.dirty = model.toggleNamedScratchpad(msg.scratchpadName)
  of MsgKind.CmdRestoreScratchpad:
    result.dirty = model.restoreScratchpad()
  of MsgKind.CmdToggleOverview:
    if model.overviewActive:
      result.dirty = model.closeOverview()
      if result.dirty:
        model.recomputeAllTagFocus()
        result.effects.add(broadcastOverview(false))
    else:
      result.dirty = model.openOverview()
      if result.dirty:
        result.effects.add(broadcastOverview(true))
        result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdOpenOverview:
    result.dirty = model.openOverview()
    if result.dirty:
      result.effects.add(broadcastOverview(true))
      result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdCloseOverview:
    result.dirty = model.closeOverview()
    if result.dirty:
      result.effects.add(broadcastOverview(false))
  of MsgKind.CmdOverviewTab:
    if model.overviewTabMode and msg.overviewTabModifiers != 0:
      if not model.overviewActive:
        result.dirty = model.openOverview()
        result.dirty =
          model.setOverviewTabModeActive(true, msg.overviewTabModifiers) or result.dirty
        if result.dirty:
          result.effects.add(broadcastOverview(true))
          result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
      else:
        result.dirty =
          model.setOverviewTabModeActive(true, msg.overviewTabModifiers) or result.dirty
        result.dirty = model.focusOverviewTabNext() or result.dirty
  of MsgKind.CmdRecentWindowNext:
    result.dirty = model.openOrAdvanceRecentWindow(
      RecentWindowDirection.Forward, msg.recentScope, msg.recentScopeSet,
      msg.recentFilter, msg.recentFilterSet,
    )
  of MsgKind.CmdRecentWindowPrev:
    result.dirty = model.openOrAdvanceRecentWindow(
      RecentWindowDirection.Backward, msg.recentScope, msg.recentScopeSet,
      msg.recentFilter, msg.recentFilterSet,
    )
  of MsgKind.CmdRecentWindowConfirm:
    let selected = model.confirmedRecentWindow()
    result.dirty = selected != NullWindowId
    if selected != NullWindowId:
      result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.CmdRecentWindowCancel:
    result.dirty = model.cancelRecentWindows()
  of MsgKind.CmdRecentWindowFirst:
    result.dirty = model.selectFirstRecentWindow()
  of MsgKind.CmdRecentWindowLast:
    result.dirty = model.selectLastRecentWindow()
  of MsgKind.CmdRecentWindowScope:
    result.dirty = model.setRecentWindowScopeCommand(msg.recentTargetScope)
  of MsgKind.CmdRecentWindowCycleScope:
    result.dirty = model.cycleRecentWindowScope()
  of MsgKind.CmdRecentWindowCloseCurrent:
    let selected = model.closeCurrentRecentWindow()
    if selected != NullWindowId:
      result.effects.add(
        Effect(
          kind: EffectKind.EffCloseWindow, closeId: model.runtimeWindowId(selected)
        )
      )
      result.dirty = true
  of MsgKind.CmdToggleFloating:
    result.dirty = model.toggleFloatingFocused()
  of MsgKind.CmdSetWindowFloatingById:
    result.dirty = model.setFloatingForExternal(
      ExternalWindowId(msg.floatingWindowId), msg.windowFloating
    )
  of MsgKind.CmdSetWindowMaximizedById:
    result.dirty = model.setMaximizedForExternal(
      ExternalWindowId(msg.maximizedWindowId), msg.windowMaximized
    )
  of MsgKind.CmdMoveFloating:
    result.dirty = model.moveFloatingFocused(msg.moveDX, msg.moveDY)
  of MsgKind.CmdResizeFloating:
    result.dirty = model.resizeFloatingFocused(msg.deltaFW, msg.deltaFH)
  of MsgKind.CmdAdjustGaps:
    result.dirty = model.adjustGaps(msg.deltaG)
  of MsgKind.CmdToggleGaps:
    result.dirty = model.toggleGaps()
  of MsgKind.CmdToggleFullscreen:
    result.dirty = model.toggleFullscreenFocused()
  of MsgKind.CmdToggleFullscreenById:
    result.dirty =
      model.toggleFullscreenForExternal(msg.fullscreenWindowId.externalWindowId())
  of MsgKind.CmdExitFullscreenById:
    result.dirty =
      model.exitFullscreenForExternal(msg.fullscreenWindowId.externalWindowId())
  of MsgKind.CmdToggleMaximized:
    result.dirty = model.toggleMaximizedFocused()
  of MsgKind.CmdMinimize:
    result.dirty = model.minimizeFocused()
  of MsgKind.CmdToggleKeyboardShortcutsInhibit:
    result.dirty = model.toggleKeyboardShortcutsInhibitFocused()
  of MsgKind.CmdSelectWindow:
    let selected = model.selectedOverviewWindow()
    result.dirty = model.closeOverview()
    if selected != NullWindowId:
      result.dirty = model.focusWindow(selected) or result.dirty
  of MsgKind.CmdCloseWindow:
    let focused = model.focusedOnActiveTag()
    if focused != NullWindowId:
      result.effects.add(
        Effect(kind: EffectKind.EffCloseWindow, closeId: model.runtimeWindowId(focused))
      )
  of MsgKind.CmdCloseWindowById:
    if model.windowForExternal(msg.closeWindowId.externalWindowId()) != NullWindowId:
      result.effects.add(
        Effect(kind: EffectKind.EffCloseWindow, closeId: msg.closeWindowId)
      )
  of MsgKind.CmdSpawn:
    if msg.spawnCommand.len > 0:
      let context = model.activeSpawnPlacementContext()
      result.effects.add(
        Effect(
          kind: EffectKind.EffSpawn,
          spawnCommand: msg.spawnCommand,
          spawnContextOutputId: context.outputId,
          spawnContextSlot: context.slot,
        )
      )
  of MsgKind.CmdTick:
    let elapsedMs =
      if msg.tickElapsedMs > 0: msg.tickElapsedMs else: DefaultFrameIntervalMs
    result.dirty = model.tickAnimations(elapsedMs)
    result.dirty = model.tickOverviewPointerHold(elapsedMs) or result.dirty
    result.dirty = model.tickRecentWindows(elapsedMs) or result.dirty
    result.dirty = model.tickLayoutSwitchToast(elapsedMs) or result.dirty
    result.dirty = model.flushPendingDialogFocus() or result.dirty
  of MsgKind.CmdExpireStartupWindowRules:
    result.dirty = model.expireStartupWindowRules()
  of MsgKind.CmdLockSession:
    if model.screenLockCommand.len > 0:
      result.effects.add(
        Effect(
          kind: EffectKind.EffSpawnScreenLock,
          screenLockCommand: model.screenLockCommand,
        )
      )
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "screen lock command is not configured")
      )
  of MsgKind.CmdWarpPointer:
    result.effects.add(
      Effect(kind: EffectKind.EffPointerWarp, warpX: msg.warpX, warpY: msg.warpY)
    )
  of MsgKind.CmdEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffEnsureNextKeyEaten))
  of MsgKind.CmdCancelEatNextKey:
    result.effects.add(Effect(kind: EffectKind.EffCancelEnsureNextKeyEaten))
  of MsgKind.CmdSwitchKeyboardLayout:
    let switched =
      model.switchKeyboardLayout(msg.keyboardLayoutDelta, msg.keyboardLayoutIndex)
    if switched.changed:
      result.dirty = true
      let snapshot = shellSnapshot(model)
      result.effects.add(
        Effect(
          kind: EffectKind.EffSetKeyboardLayout,
          keyboardLayoutIndex: switched.activeIndex,
        )
      )
      result.effects.add(broadcastKeyboardLayoutsChanged(snapshot))
      result.effects.add(broadcastKeyboardLayoutSwitched(switched.activeIndex))
  of MsgKind.CmdStopManager:
    result.effects.add(Effect(kind: EffectKind.EffStopManager))
  of MsgKind.CmdTriadReload:
    result.effects.add(Effect(kind: EffectKind.EffTriadReload))
  of MsgKind.CmdExitSession:
    if model.allowExitSession:
      result.dirty = model.setHotkeyOverlayOpen(false) or result.dirty
      result.dirty = model.cancelRecentWindows() or result.dirty
      result.dirty = model.setExitSessionConfirmOpen(true) or result.dirty
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdExitSessionImmediate:
    if model.allowExitSession:
      result.dirty = model.setHotkeyOverlayOpen(false) or result.dirty
      result.dirty = model.cancelRecentWindows() or result.dirty
      result.dirty = model.setExitSessionConfirmOpen(false) or result.dirty
      result.effects.add(Effect(kind: EffectKind.EffExitSession))
    else:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdConfirmExitSession:
    let wasOpen = model.exitSessionConfirmOpen
    result.dirty = model.setExitSessionConfirmOpen(false)
    if wasOpen and model.allowExitSession:
      result.effects.add(Effect(kind: EffectKind.EffExitSession))
    elif wasOpen:
      result.effects.add(
        Effect(kind: EffectKind.EffLog, msg: "exit-session is disabled by config")
      )
  of MsgKind.CmdDismissExitSessionConfirm:
    result.dirty = model.setExitSessionConfirmOpen(false)
  of MsgKind.CmdFocusShellUi:
    if not model.sessionLocked and not model.layerFocusExclusive:
      result.effects.add(Effect(kind: EffectKind.EffFocusShellUi))
  of MsgKind.CmdSwitchShell:
    if model.shells.hasShellProfile(msg.shellName):
      if model.shells.active != msg.shellName:
        model.shells.active = msg.shellName
        result.dirty = true
    else:
      result.effects.add(
        Effect(
          kind: EffectKind.EffLog, msg: "shell profile not found: " & msg.shellName
        )
      )
  of MsgKind.CmdCycleShell:
    let nextShell = model.shells.nextShellName()
    if nextShell.len > 0 and model.shells.active != nextShell:
      model.shells.active = nextShell
      result.dirty = true
  of MsgKind.CmdShowHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(true)
  of MsgKind.CmdHideHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(false)
  of MsgKind.CmdToggleHotkeyOverlay:
    result.dirty = model.setHotkeyOverlayOpen(not model.hotkeyOverlayOpen)
  of MsgKind.CmdScreenshot:
    result.effects.add(
      Effect(
        kind: EffectKind.EffScreenshot,
        screenshotKind: msg.screenshotKind,
        screenshotPath: msg.screenshotPath,
        screenshotPointerMode: msg.screenshotPointerMode,
        screenshotWriteToDisk: msg.screenshotWriteToDisk,
        screenshotCopyToClipboard: msg.screenshotCopyToClipboard,
      )
    )
  of MsgKind.CmdConfigReload, MsgKind.CmdSpawnTerminal:
    result.dirty = true
  else:
    discard
