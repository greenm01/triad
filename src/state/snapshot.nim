import std/[options, strutils, tables]
import iterators, queries
import ../core/layout_descriptor_codec
import ../core/layout_mode_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../core/defaults
import ../types/[core, model, shell_snapshot]
from ../types/runtime_values import LayoutMode

proc externalWindowId(model: Model, winId: WindowId): uint32 =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return uint32(winOpt.get().externalId)
  0'u32

proc shellColumns(model: Model, tagId: TagId): seq[ShellColumn] =
  var idx = 0'u32
  for columnId, column in model.columnsOnTagWithId(tagId):
    var windows: seq[uint32] = @[]
    for winId, win in model.windowsOnColumnWithId(columnId):
      if win.windowAdmitted() and not win.isFloating and not win.isUnmanagedGlobal:
        windows.add(model.externalWindowId(winId))
    if windows.len == 0:
      continue
    inc idx
    result.add(
      ShellColumn(
        idx: idx,
        widthProportion: column.widthProportion,
        scrollerSingleProportion: column.scrollerSingleProportion,
        isFullWidth: column.isFullWidth,
        windows: windows,
      )
    )

proc shellFrames(model: Model, tagId: TagId): seq[ShellFrame] =
  for frameId, frame in model.framesOnTagWithId(tagId):
    var windows: seq[uint32] = @[]
    for winId in model.windowsByFrame.getOrDefault(frameId, @[]):
      let winOpt = model.windowData(winId)
      if winOpt.isSome and winOpt.get().windowAdmitted() and not winOpt.get().isFloating and
          not winOpt.get().isUnmanagedGlobal:
        windows.add(model.externalWindowId(winId))
    result.add(
      ShellFrame(
        id: uint32(frame.id),
        kind: frame.kind,
        parent: uint32(frame.parent),
        firstChild: uint32(frame.firstChild),
        secondChild: uint32(frame.secondChild),
        orientation: frame.orientation,
        ratio: frame.ratio,
        windows: windows,
        activeWindow: model.externalWindowId(frame.activeWindow),
        focused:
          model.tagData(tagId).isSome and
          model.tagData(tagId).get().focusedFrame == frameId,
      )
    )

proc shellBspNodes(model: Model, tagId: TagId): seq[ShellBspNode] =
  let tagOpt = model.tagData(tagId)
  for nodeId, node in model.bspNodesOnTagWithId(tagId):
    result.add(
      ShellBspNode(
        id: uint32(nodeId),
        kind: node.kind,
        parent: uint32(node.parent),
        firstChild: uint32(node.firstChild),
        secondChild: uint32(node.secondChild),
        orientation: node.orientation,
        ratio: node.ratio,
        window: model.externalWindowId(node.window),
        focused:
          tagOpt.isSome and node.window != NullWindowId and
          node.window == tagOpt.get().focusedWindow,
      )
    )

proc snapshotDefaultMasterCount(model: Model): int =
  if model.defaultMasterCount > 0:
    max(1, model.defaultMasterCount)
  else:
    DefaultMasterCount

proc snapshotDefaultMasterRatio(model: Model): float32 =
  if model.defaultMasterRatio > 0:
    clamp(model.defaultMasterRatio, 0.05'f32, 0.95'f32)
  else:
    DefaultMasterRatio

proc keyboardLayoutNames(model: Model): seq[string] =
  let xkb = model.input.keyboard.xkb
  if not xkb.layoutSet:
    return @[]
  for name in xkb.layout.split(','):
    let stripped = name.strip()
    if stripped.len > 0:
      result.add(stripped)

proc shellSnapshot*(model: Model): ShellSnapshot =
  result.version = TriadIpcVersion
  result.activeTag = model.activeSlot
  result.activeWorkspaceIdx = model.workspaceIndexForSlot(model.activeSlot)
  result.overviewActive = model.overviewActive
  result.overviewSelectedWindow =
    if model.overviewActive:
      model.externalWindowId(model.selectedOverviewWindow())
    else:
      0'u32
  result.activeScratchpadWindow = model.externalWindowId(model.activeScratchpadWindow())
  let activeScratchpad = model.activeScratchpadWindow()
  result.sessionLocked = model.sessionLocked
  result.layerFocusExclusive = model.layerFocusExclusive
  result.layoutCycle =
    if model.layoutCycle.len > 0:
      model.layoutCycle
    else:
      @[
        LayoutMode.Scroller, LayoutMode.MasterStack, LayoutMode.Grid,
        LayoutMode.Monocle, LayoutMode.VerticalScroller,
      ]
  result.layoutCycleSelections =
    if model.layoutCycleSelections.len > 0:
      model.layoutCycleSelections
    else:
      @[]
  if result.layoutCycleSelections.len == 0:
    for mode in result.layoutCycle:
      result.layoutCycleSelections.add(builtinSelection(mode))
  result.customLayouts = model.customLayouts
  result.nativeLayouts = nativeLayouts()
  result.keyboardLayoutNames = model.keyboardLayoutNames()
  result.keyboardLayoutIndex =
    if result.keyboardLayoutNames.len == 0:
      0'u32
    else:
      min(model.keyboardLayoutIndex, uint32(result.keyboardLayoutNames.len - 1))

  for idx, slot in model.visibleWorkspaceSlots():
    let tagId = model.tagForSlot(slot)
    let tagOpt =
      if tagId != NullTagId:
        model.tagData(tagId)
      else:
        none(TagData)
    let tag =
      if tagOpt.isSome:
        tagOpt.get()
      else:
        TagData(
          slot: slot,
          layoutMode: LayoutMode.Scroller,
          masterCount: model.snapshotDefaultMasterCount(),
          masterSplitRatio: model.snapshotDefaultMasterRatio(),
        )
    let layoutKind =
      if tag.customLayoutId.layoutIdString().len > 0:
        "custom"
      elif tag.nativeLayoutId.nativeLayoutIdString().len > 0:
        "native"
      else:
        "builtin"
    let layoutId =
      case layoutKind
      of "custom":
        tag.customLayoutId.layoutIdString()
      of "native":
        tag.nativeLayoutId.nativeLayoutIdString()
      else:
        layoutModeId(tag.layoutMode)
    let fallbackLayout =
      if layoutKind == "custom":
        let custom = model.customLayouts.findCustomLayout(tag.customLayoutId)
        if custom.isSome:
          custom.get().fallback.selectionFallbackId()
        else:
          layoutModeId(tag.layoutMode)
      else:
        layoutModeId(tag.layoutMode)

    result.workspaces.add(
      ShellWorkspace(
        tagId: slot,
        workspaceIdx: uint32(idx + 1),
        name: tag.name,
        layoutMode: tag.layoutMode,
        layoutId: layoutId,
        layoutKind: layoutKind,
        runtimeLayoutKind: layoutKindForId(layoutId).layoutKindId(),
        layoutSource: layoutSourceForId(layoutId).layoutSourceId(),
        fallbackLayout: fallbackLayout,
        isActive: slot == model.activeSlot,
        isOutputVisible: tagId != NullTagId and model.tagVisibleOnOutput(tagId),
        focusedWindow: model.externalWindowId(tag.focusedWindow),
        occupied: tagId != NullTagId and model.tagHasNonStickyLiveWindows(tagId),
        outputName:
          if tagId != NullTagId:
            model.shellWorkspaceOutputName(tagId)
          else:
            "triad-0",
        columns:
          if tagId != NullTagId:
            model.shellColumns(tagId)
          else:
            @[],
        frames:
          if tagId != NullTagId:
            model.shellFrames(tagId)
          else:
            @[],
        bspNodes:
          if tagId != NullTagId:
            model.shellBspNodes(tagId)
          else:
            @[],
        masterCount: tag.masterCount,
        masterSplitRatio: tag.masterSplitRatio,
        targetViewportXOffset: tag.targetViewportXOffset,
        currentViewportXOffset: tag.currentViewportXOffset,
        targetViewportYOffset: tag.targetViewportYOffset,
        currentViewportYOffset: tag.currentViewportYOffset,
      )
    )

  for winId in model.sortedWindowIdsByExternal():
    let win = model.windowData(winId).get()
    if not win.windowAdmitted():
      continue
    if model.windowHiddenBySwallow(winId):
      continue
    let pos = model.firstWindowPosition(winId)
    let tagOpt =
      if pos.found:
        model.tagData(pos.tagId)
      else:
        none(TagData)
    let focused =
      pos.found and pos.tagId == model.activeTag and tagOpt.isSome and
      tagOpt.get().focusedWindow == winId
    let isFocused =
      winId == activeScratchpad or (activeScratchpad == NullWindowId and focused)
    result.windows.add(
      ShellWindow(
        id: uint32(win.externalId),
        pid: win.pid,
        parentId: uint32(win.parentExternalId),
        title: win.title,
        appId: win.appId,
        identifier: win.identifier,
        tagId:
          if pos.found:
            some(pos.slot)
          else:
            none(uint32),
        workspaceIdx:
          if pos.found:
            model.workspaceIndexForSlot(pos.slot)
          else:
            0'u32,
        outputName:
          if pos.found:
            model.shellWorkspaceOutputName(pos.tagId)
          else:
            "",
        colIdx: pos.colIdx,
        winIdx: pos.winIdx,
        isFocused: isFocused,
        isFloating: win.isFloating,
        isFullscreen: win.isFullscreen,
        isMaximized: win.isMaximized,
        isMinimized: win.isMinimized,
        isSticky: win.isSticky,
        isOverlay: win.isOverlay,
        isUnmanagedGlobal: win.isUnmanagedGlobal,
        fullscreenOutput: uint32(win.fullscreenOutput),
        widthProportion: win.widthProportion,
        heightProportion: win.heightProportion,
        actualW: win.actualW,
        actualH: win.actualH,
        floatingGeom: win.floatingGeom,
        keyboardShortcutsInhibit: win.keyboardShortcutsInhibit,
        idleInhibitMode: win.idleInhibitMode,
        isTerminal: win.isTerminal,
        allowSwallow: win.allowSwallow,
        swallowedBy: model.externalWindowId(model.swallowedByWindow(winId)),
        swallowing: model.externalWindowId(model.swallowingWindow(winId)),
      )
    )

  if model.outputCount() == 0:
    result.outputs.add(
      ShellOutput(
        id: 0,
        name: "triad-0",
        x: 0,
        y: 0,
        w: max(0'i32, model.screenWidth),
        h: max(0'i32, model.screenHeight),
        refreshRate: 0,
        isPrimary: true,
      )
    )
  else:
    for outputId in model.sortedOutputIdsByExternal():
      let output = model.outputData(outputId).get()
      result.outputs.add(
        ShellOutput(
          id: uint32(output.externalId),
          name: model.shellOutputName(outputId),
          x: output.x,
          y: output.y,
          w: max(0'i32, output.w),
          h: max(0'i32, output.h),
          refreshRate: output.refreshRate,
          isPrimary: outputId == model.primaryOutput,
        )
      )
