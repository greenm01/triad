import algorithm, options, tables
import model
import model_utils

const TriadIpcVersion* = 1

type
  ShellColumn* = object
    idx*: uint32
    widthProportion*: float32
    windows*: seq[WindowId]

  ShellWorkspace* = object
    tagId*: uint32
    workspaceIdx*: uint32
    name*: string
    layoutMode*: LayoutMode
    isActive*: bool
    focusedWindow*: WindowId
    occupied*: bool
    outputName*: string
    columns*: seq[ShellColumn]
    masterCount*: int
    masterSplitRatio*: float32
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32

  ShellWindow* = object
    id*: WindowId
    title*: string
    appId*: string
    tagId*: Option[uint32]
    workspaceIdx*: uint32
    outputName*: string
    colIdx*: uint32
    winIdx*: uint32
    isFocused*: bool
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    fullscreenOutput*: uint32
    widthProportion*: float32
    heightProportion*: float32
    actualW*: int32
    actualH*: int32
    floatingGeom*: Rect
    keyboardShortcutsInhibit*: bool

  ShellOutput* = object
    id*: uint32
    name*: string
    x*, y*, w*, h*: int32
    isPrimary*: bool

  ShellSnapshot* = object
    version*: uint32
    activeTag*: uint32
    activeWorkspaceIdx*: uint32
    overviewActive*: bool
    layoutCycle*: seq[LayoutMode]
    workspaces*: seq[ShellWorkspace]
    windows*: seq[ShellWindow]
    outputs*: seq[ShellOutput]

proc layoutModeId*(mode: LayoutMode): string =
  case mode
  of Scroller: "scroller"
  of VerticalScroller: "vertical-scroller"
  of MasterStack: "tile"
  of Grid: "grid"
  of Monocle: "monocle"
  of Deck: "deck"
  of CenterTile: "center-tile"
  of RightTile: "right-tile"
  of VerticalTile: "vertical-tile"
  of VerticalGrid: "vertical-grid"
  of VerticalDeck: "vertical-deck"

proc parseLayoutModeId*(value: string): Option[LayoutMode] =
  case value
  of "scroller": some(Scroller)
  of "vertical-scroller": some(VerticalScroller)
  of "tile": some(MasterStack)
  of "grid": some(Grid)
  of "monocle": some(Monocle)
  of "deck": some(Deck)
  of "center-tile": some(CenterTile)
  of "right-tile": some(RightTile)
  of "vertical-tile": some(VerticalTile)
  of "vertical-grid": some(VerticalGrid)
  of "vertical-deck": some(VerticalDeck)
  else: none(LayoutMode)

proc shellOutputName*(model: Model; outputId: uint32): string =
  if outputId != 0 and model.outputs.hasKey(outputId):
    let output = model.outputs[outputId]
    if output.name.len > 0:
      return output.name
  if outputId != 0:
    return "river-" & $outputId
  "triad-0"

proc shellWorkspaceOutputName*(model: Model; tagId: uint32): string =
  var outputId = model.primaryOutput
  for candidateId, outputTag in model.outputTags.pairs:
    if outputTag == tagId:
      outputId = candidateId
      break
  model.shellOutputName(outputId)

proc workspaceIndexForTag*(model: Model; tagId: uint32): uint32 =
  let ids = model.visibleWorkspaceIds()
  for idx, id in ids:
    if id == tagId:
      return uint32(idx + 1)
  0

proc windowPosition(model: Model; winId: WindowId): tuple[found: bool, tagId, colIdx, winIdx: uint32] =
  var tagIds: seq[uint32] = @[]
  for tagId in model.tags.keys:
    tagIds.add(tagId)
  tagIds.sort()

  for tagId in tagIds:
    let tag = model.tags[tagId]
    for colIdx, col in tag.columns:
      let winIdx = col.windows.find(winId)
      if winIdx != -1:
        return (true, tagId, uint32(colIdx + 1), uint32(winIdx + 1))
  (false, 0'u32, 0'u32, 0'u32)

proc shellColumns(tag: TagState): seq[ShellColumn] =
  for idx, col in tag.columns:
    result.add(ShellColumn(
      idx: uint32(idx + 1),
      widthProportion: col.widthProportion,
      windows: col.windows
    ))

proc shellSnapshot*(model: Model): ShellSnapshot =
  result.version = TriadIpcVersion
  result.activeTag = model.activeTag
  result.activeWorkspaceIdx = model.workspaceIndexForTag(model.activeTag)
  result.overviewActive = model.overviewActive
  result.layoutCycle =
    if model.layoutCycle.len > 0:
      model.layoutCycle
    else:
      @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]

  let workspaceIds = model.visibleWorkspaceIds()
  for idx, tagId in workspaceIds:
    let tag =
      if model.tags.hasKey(tagId):
        model.tags[tagId]
      else:
        model.initTagStateForModel(tagId)
    let live = if model.tags.hasKey(tagId): tag.liveWindows(model) else: @[]
    result.workspaces.add(ShellWorkspace(
      tagId: tagId,
      workspaceIdx: uint32(idx + 1),
      name: tag.name,
      layoutMode: tag.layoutMode,
      isActive: tagId == model.activeTag,
      focusedWindow: tag.focusedWindow,
      occupied: live.len > 0,
      outputName: model.shellWorkspaceOutputName(tagId),
      columns: shellColumns(tag),
      masterCount: tag.masterCount,
      masterSplitRatio: tag.masterSplitRatio,
      targetViewportXOffset: tag.targetViewportXOffset,
      currentViewportXOffset: tag.currentViewportXOffset,
      targetViewportYOffset: tag.targetViewportYOffset,
      currentViewportYOffset: tag.currentViewportYOffset
    ))

  var winIds: seq[WindowId] = @[]
  for winId in model.windows.keys:
    winIds.add(winId)
  winIds.sort()
  for winId in winIds:
    let win = model.windows[winId]
    let pos = model.windowPosition(winId)
    let tag = if pos.found: some(pos.tagId) else: none(uint32)
    let outputName =
      if pos.found:
        model.shellWorkspaceOutputName(pos.tagId)
      else:
        ""
    let focused =
      pos.found and model.tags.hasKey(pos.tagId) and model.tags[pos.tagId].focusedWindow == winId
    result.windows.add(ShellWindow(
      id: win.id,
      title: win.title,
      appId: win.appId,
      tagId: tag,
      workspaceIdx: if pos.found: model.workspaceIndexForTag(pos.tagId) else: 0'u32,
      outputName: outputName,
      colIdx: pos.colIdx,
      winIdx: pos.winIdx,
      isFocused: focused,
      isFloating: win.isFloating,
      isFullscreen: win.isFullscreen,
      isMaximized: win.isMaximized,
      isMinimized: win.isMinimized,
      fullscreenOutput: win.fullscreenOutput,
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
    var outputIds: seq[uint32] = @[]
    for outputId in model.outputs.keys:
      outputIds.add(outputId)
    outputIds.sort()
    for outputId in outputIds:
      let output = model.outputs[outputId]
      result.outputs.add(ShellOutput(
        id: outputId,
        name: model.shellOutputName(outputId),
        x: output.x,
        y: output.y,
        w: max(0'i32, output.w),
        h: max(0'i32, output.h),
        isPrimary: outputId == model.primaryOutput
      ))
