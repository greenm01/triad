import json, options, tables
import model
import model_utils

const TriadIpcVersion* = 1

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

proc triadSupportedLayoutsJson*(): JsonNode =
  result = newJArray()
  for mode in LayoutMode:
    result.add(%*{"id": layoutModeId(mode), "ordinal": ord(mode)})

proc triadLayoutCycleJson*(model: Model): JsonNode =
  result = newJArray()
  let cycle = if model.layoutCycle.len > 0:
    model.layoutCycle
  else:
    @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]
  for mode in cycle:
    result.add(%layoutModeId(mode))

proc workspaceIndexForTag(model: Model; tagId: uint32): uint32 =
  let ids = model.visibleWorkspaceIds()
  for idx, id in ids:
    if id == tagId:
      return uint32(idx + 1)
  0

proc tagColumnsJson(tag: TagState): JsonNode =
  result = newJArray()
  for idx, col in tag.columns:
    let windows = newJArray()
    for winId in col.windows:
      windows.add(%winId)
    result.add(%*{
      "idx": idx + 1,
      "width_proportion": col.widthProportion,
      "windows": windows
    })

proc triadWorkspaceLayoutJson*(model: Model; tagId: uint32; workspaceIdx: uint32): JsonNode =
  let tag =
    if model.tags.hasKey(tagId):
      model.tags[tagId]
    else:
      model.initTagStateForModel(tagId)

  %*{
    "tag_id": tagId,
    "workspace_idx": workspaceIdx,
    "name": if tag.name.len == 0: newJNull() else: %tag.name,
    "layout": layoutModeId(tag.layoutMode),
    "is_active": tagId == model.activeTag,
    "focused_window_id": if tag.focusedWindow == 0: newJNull() else: %tag.focusedWindow,
    "columns": tagColumnsJson(tag),
    "master_count": tag.masterCount,
    "master_split_ratio": tag.masterSplitRatio,
    "viewport": {
      "target_x": tag.targetViewportXOffset,
      "current_x": tag.currentViewportXOffset,
      "target_y": tag.targetViewportYOffset,
      "current_y": tag.currentViewportYOffset
    }
  }

proc triadLayoutStateJson*(model: Model): JsonNode =
  let ids = model.visibleWorkspaceIds()
  let workspaces = newJArray()
  for idx, tagId in ids:
    workspaces.add(triadWorkspaceLayoutJson(model, tagId, uint32(idx + 1)))

  %*{
    "version": TriadIpcVersion,
    "layouts": triadSupportedLayoutsJson(),
    "layout_cycle": triadLayoutCycleJson(model),
    "active_tag": model.activeTag,
    "active_workspace_idx": model.workspaceIndexForTag(model.activeTag),
    "workspaces": workspaces
  }

proc triadLayoutStateChangedEvent*(model: Model): string =
  $(%*{
    "triad": {
      "version": TriadIpcVersion,
      "event": "layout-state-changed",
      "state": triadLayoutStateJson(model)
    }
  })
