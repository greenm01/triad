import options
import dod_iterators
import dod_queries
import ../types/core except Rect
import ../types/dod_model
import ../types/shell_snapshot
from ../types/legacy_model import nil

proc externalWindowId(model: DodModel; winId: WindowId): legacy_model.WindowId =
  if winId == NullWindowId:
    return 0'u32
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    return legacy_model.WindowId(uint32(winOpt.get().externalId))
  0'u32

proc shellColumns(model: DodModel; tagId: TagId): seq[ShellColumn] =
  var idx = 0'u32
  for columnId, column in model.columnsOnTagWithId(tagId):
    inc idx
    var windows: seq[legacy_model.WindowId] = @[]
    for winId, _ in model.windowsOnColumnWithId(columnId):
      windows.add(model.externalWindowId(winId))
    result.add(ShellColumn(
      idx: idx,
      widthProportion: column.widthProportion,
      windows: windows
    ))

proc dodShellSnapshot*(model: DodModel): ShellSnapshot =
  result.version = TriadIpcVersion
  result.activeTag = model.activeSlot
  result.activeWorkspaceIdx = model.workspaceIndexForSlot(model.activeSlot)
  result.overviewActive = model.overviewActive
  result.layoutCycle =
    if model.layoutCycle.len > 0:
      model.layoutCycle
    else:
      @[
        legacy_model.Scroller, legacy_model.MasterStack, legacy_model.Grid,
        legacy_model.Monocle, legacy_model.VerticalScroller
      ]

  for idx, slot in model.visibleWorkspaceSlots():
    let tagId = model.tagForSlot(slot)
    let tagOpt =
      if tagId != NullTagId: model.tagData(tagId) else: none(TagData)
    let tag =
      if tagOpt.isSome: tagOpt.get()
      else: TagData(slot: slot, layoutMode: legacy_model.Scroller,
        masterCount: 1, masterSplitRatio: 0.55'f32)

    result.workspaces.add(ShellWorkspace(
      tagId: slot,
      workspaceIdx: uint32(idx + 1),
      name: tag.name,
      layoutMode: tag.layoutMode,
      isActive: slot == model.activeSlot,
      focusedWindow: model.externalWindowId(tag.focusedWindow),
      occupied: tagId != NullTagId and model.tagHasLiveWindows(tagId),
      outputName:
        if tagId != NullTagId: model.shellWorkspaceOutputName(tagId)
        else: "triad-0",
      columns: if tagId != NullTagId: model.shellColumns(tagId) else: @[],
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio,
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset
    ))

  for winId in model.sortedWindowIdsByExternal():
    let win = model.windowData(winId).get()
    let pos = model.firstWindowPosition(winId)
    let tagOpt =
      if pos.found: model.tagData(pos.tagId) else: none(TagData)
    let focused =
      tagOpt.isSome and tagOpt.get().focusedWindow == winId
    result.windows.add(ShellWindow(
      id: legacy_model.WindowId(uint32(win.externalId)),
      title: win.title,
      appId: win.appId,
      tagId: if pos.found: some(pos.slot) else: none(uint32),
      workspaceIdx:
        if pos.found: model.workspaceIndexForSlot(pos.slot) else: 0'u32,
      outputName:
        if pos.found: model.shellWorkspaceOutputName(pos.tagId) else: "",
      colIdx: pos.colIdx,
      winIdx: pos.winIdx,
      isFocused: focused,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      fullscreenOutput: uint32(win.fullscreenOutput),
      widthProportion: win.widthProportion,
      heightProportion: win.heightProportion,
      actualW: win.actualW,
      actualH: win.actualH,
      floatingGeom: win.floatingGeom,
      keyboardShortcutsInhibit: win.keyboardShortcutsInhibit
    ))

  if model.outputCount() == 0:
    result.outputs.add(ShellOutput(
      id: 0,
      name: "triad-0",
      x: 0,
      y: 0,
      w: max(0'i32, model.screenWidth),
      h: max(0'i32, model.screenHeight),
      isPrimary: true
    ))
  else:
    for outputId in model.sortedOutputIdsByExternal():
      let output = model.outputData(outputId).get()
      result.outputs.add(ShellOutput(
        id: uint32(output.externalId),
        name: model.shellOutputName(outputId),
        x: output.x,
        y: output.y,
        w: max(0'i32, output.w),
        h: max(0'i32, output.h),
        isPrimary: outputId == model.primaryOutput
      ))
