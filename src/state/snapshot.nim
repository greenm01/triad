import std/options
import iterators, queries
import ../core/defaults
import ../types/[core, model, shell_snapshot]
from ../types/runtime_values import nil

proc externalWindowId(model: Model, winId: WindowId): runtime_values.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return runtime_values.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc shellColumns(model: Model, tagId: TagId): seq[ShellColumn] =
  var idx = 0'u32
  for columnId, column in model.columnsOnTagWithId(tagId):
    var windows: seq[runtime_values.WindowId] = @[]
    for winId, win in model.windowsOnColumnWithId(columnId):
      if win.windowAdmitted() and not win.isFloating:
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
  result.layoutCycle =
    if model.layoutCycle.len > 0:
      model.layoutCycle
    else:
      @[
        runtime_values.LayoutMode.Scroller, runtime_values.LayoutMode.MasterStack,
        runtime_values.LayoutMode.Grid, runtime_values.LayoutMode.Monocle,
        runtime_values.LayoutMode.VerticalScroller,
      ]

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
          layoutMode: runtime_values.LayoutMode.Scroller,
          masterCount: model.snapshotDefaultMasterCount(),
          masterSplitRatio: model.snapshotDefaultMasterRatio(),
        )

    result.workspaces.add(
      ShellWorkspace(
        tagId: slot,
        workspaceIdx: uint32(idx + 1),
        name: tag.name,
        layoutMode: tag.layoutMode,
        isActive: slot == model.activeSlot,
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
    let pos = model.firstWindowPosition(winId)
    let tagOpt =
      if pos.found:
        model.tagData(pos.tagId)
      else:
        none(TagData)
    let focused =
      pos.found and pos.tagId == model.activeTag and tagOpt.isSome and
      tagOpt.get().focusedWindow == winId
    result.windows.add(
      ShellWindow(
        id: runtime_values.WindowId(uint32(win.externalId)),
        parentId: runtime_values.WindowId(uint32(win.parentExternalId)),
        title: win.title,
        appId: win.appId,
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
        isFocused: focused,
        isFloating: win.isFloating,
        isFullscreen: win.isFullscreen,
        isMaximized: win.isMaximized,
        isMinimized: win.isMinimized,
        isSticky: win.isSticky,
        fullscreenOutput: uint32(win.fullscreenOutput),
        widthProportion: win.widthProportion,
        heightProportion: win.heightProportion,
        actualW: win.actualW,
        actualH: win.actualH,
        floatingGeom: win.floatingGeom,
        keyboardShortcutsInhibit: win.keyboardShortcutsInhibit,
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
          isPrimary: outputId == model.primaryOutput,
        )
      )
