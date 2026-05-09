import algorithm, options, tables
import dod_queries
import entity_manager
import ../core/shell_state
import ../types/core except Rect
import ../types/dod_model
from ../types/legacy_model import nil

proc externalWindowId(model: DodModel; winId: WindowId): legacy_model.WindowId =
  if winId != NullWindowId and model.windows.hasEntity(winId):
    return legacy_model.WindowId(uint32(model.windows.getEntity(winId).externalId))
  0'u32

proc shellColumns(model: DodModel; tagId: TagId): seq[ShellColumn] =
  for idx, columnId in model.columnsForTag(tagId):
    if not model.columns.hasEntity(columnId):
      continue
    var windows: seq[legacy_model.WindowId] = @[]
    for winId in model.windowsForColumn(columnId):
      windows.add(model.externalWindowId(winId))
    result.add(ShellColumn(
      idx: uint32(idx + 1),
      widthProportion: model.columns.getEntity(columnId).widthProportion,
      windows: windows
    ))

proc firstWindowPosition(model: DodModel; winId: WindowId):
    tuple[found: bool, tagId: TagId, slot, colIdx, winIdx: uint32] =
  for slot in model.visibleWorkspaceSlots():
    let tagId = model.tagForSlot(slot)
    if tagId == NullTagId:
      continue
    if model.windowsForTag(tagId).find(winId) == -1:
      continue
    let placement = model.placementByTagWindow.getOrDefault((tagId, winId), WindowPlacement())
    if placement.columnId == NullColumnId:
      continue
    return (
      true,
      tagId,
      slot,
      model.columnIndexForTag(tagId, placement.columnId),
      placement.windowIdx
    )
  (false, NullTagId, 0'u32, 0'u32, 0'u32)

proc dodShellSnapshot*(model: DodModel): ShellSnapshot =
  result.version = TriadIpcVersion
  result.activeTag = model.activeSlot
  result.activeWorkspaceIdx = model.workspaceIndexForSlot(model.activeSlot)
  result.overviewActive = model.overviewActive
  result.layoutCycle =
    if model.layoutCycle.len > 0:
      model.layoutCycle
    else:
      @[legacy_model.Scroller, legacy_model.MasterStack, legacy_model.Grid, legacy_model.Monocle, legacy_model.VerticalScroller]

  for idx, slot in model.visibleWorkspaceSlots():
    let tagId = model.tagForSlot(slot)
    let tag =
      if tagId != NullTagId and model.tags.hasEntity(tagId):
        model.tags.getEntity(tagId)
      else:
        TagData(slot: slot, layoutMode: legacy_model.Scroller, masterCount: 1, masterSplitRatio: 0.55'f32)

    result.workspaces.add(ShellWorkspace(
      tagId: slot,
      workspaceIdx: uint32(idx + 1),
      name: tag.name,
      layoutMode: tag.layoutMode,
      isActive: slot == model.activeSlot,
      focusedWindow: model.externalWindowId(tag.focusedWindow),
      occupied: tagId != NullTagId and model.tagHasLiveWindows(tagId),
      outputName: if tagId != NullTagId: model.shellWorkspaceOutputName(tagId) else: "triad-0",
      columns: if tagId != NullTagId: model.shellColumns(tagId) else: @[],
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio,
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset
    ))

  var winIds: seq[WindowId] = @[]
  for win in model.windows.entities:
    winIds.add(win.id)
  winIds.sort(proc(a, b: WindowId): int =
    cmp(uint32(model.windows.getEntity(a).externalId), uint32(model.windows.getEntity(b).externalId)))

  for winId in winIds:
    let win = model.windows.getEntity(winId)
    let pos = model.firstWindowPosition(winId)
    let focused =
      pos.found and model.tags.hasEntity(pos.tagId) and model.tags.getEntity(pos.tagId).focusedWindow == winId
    result.windows.add(ShellWindow(
      id: legacy_model.WindowId(uint32(win.externalId)),
      title: win.title,
      appId: win.appId,
      tagId: if pos.found: some(pos.slot) else: none(uint32),
      workspaceIdx: if pos.found: model.workspaceIndexForSlot(pos.slot) else: 0'u32,
      outputName: if pos.found: model.shellWorkspaceOutputName(pos.tagId) else: "",
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

  if model.outputs.len == 0:
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
    var outputIds: seq[OutputId] = @[]
    for output in model.outputs.entities:
      outputIds.add(output.id)
    outputIds.sort(proc(a, b: OutputId): int =
      cmp(uint32(model.outputs.getEntity(a).externalId), uint32(model.outputs.getEntity(b).externalId)))

    for outputId in outputIds:
      let output = model.outputs.getEntity(outputId)
      result.outputs.add(ShellOutput(
        id: uint32(output.externalId),
        name: model.shellOutputName(outputId),
        x: output.x,
        y: output.y,
        w: max(0'i32, output.w),
        h: max(0'i32, output.h),
        isPrimary: outputId == model.primaryOutput
      ))
