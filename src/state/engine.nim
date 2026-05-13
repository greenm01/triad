import std/[options, strutils]
import entity_manager, id_gen, invariants, iterators, live_restore, queries, snapshot
import ../core/defaults
import ../entities/ops
import ../types/[core, model, shell_snapshot]
from ../types/runtime_values import LayoutMode, ParentedRole

export defaults
export iterators
export queries
export invariants
export snapshot
export live_restore
export ops
export core
export model
export shell_snapshot
export id_gen

type GeometryRect* = typeof(WindowData().floatingGeom)

proc clampProportion*(value: float32, lo = 0.05'f32, hi = 1.0'f32): float32 =
  clamp(value, lo, hi)

proc defaultWindowWidth*(model: Model): float32 =
  if model.defaultWindowWidth > 0:
    clampProportion(model.defaultWindowWidth)
  else:
    DefaultWindowWidth

proc defaultWindowHeight*(model: Model): float32 =
  if model.defaultWindowHeight > 0:
    clampProportion(model.defaultWindowHeight)
  else:
    DefaultWindowHeight

proc defaultMasterCount*(model: Model): int =
  if model.defaultMasterCount > 0:
    max(1, model.defaultMasterCount)
  else:
    DefaultMasterCount

proc defaultMasterRatio*(model: Model): float32 =
  if model.defaultMasterRatio > 0:
    clamp(model.defaultMasterRatio, 0.05'f32, 0.95'f32)
  else:
    DefaultMasterRatio

proc defaultWorkspaceCount*(model: Model): uint32 =
  if model.defaultWorkspaceCount == 0:
    DefaultWorkspaceCount
  else:
    min(model.defaultWorkspaceCount, MaxTagBits)

proc defaultColumnWidth*(model: Model): float32 =
  if model.defaultColumnWidth > 0:
    clamp(model.defaultColumnWidth, 0.05'f32, 1.0'f32)
  else:
    DefaultColumnWidth

proc layoutCycle*(model: Model): seq[LayoutMode] =
  if model.layoutCycle.len > 0:
    model.layoutCycle
  else:
    @[
      LayoutMode.Scroller, LayoutMode.MasterStack, LayoutMode.Grid, LayoutMode.Monocle,
      LayoutMode.VerticalScroller,
    ]

proc setHotkeyOverlayOpen*(model: var Model, open: bool): bool =
  if model.hotkeyOverlayOpen == open:
    return false
  model.hotkeyOverlayOpen = open
  if open:
    model.hotkeyOverlayShownOnce = true
  true

proc shouldShowHotkeyOverlayAtStartup*(model: Model): bool =
  not model.hotkeyOverlay.skipAtStartup and not model.hotkeyOverlayShownOnce

proc safeLayoutMode*(stored: int, fallback = LayoutMode.Scroller): LayoutMode =
  if stored >= ord(low(LayoutMode)) + 1 and stored <= ord(high(LayoutMode)) + 1:
    LayoutMode(stored - 1)
  else:
    fallback

proc effectiveFloatingMinWidth*(model: Model): int32 =
  if model.floatingMinWidth > 0: model.floatingMinWidth else: DefaultFloatingMinWidth

proc effectiveFloatingMinHeight*(model: Model): int32 =
  if model.floatingMinHeight > 0: model.floatingMinHeight else: DefaultFloatingMinHeight

proc effectiveScratchpadWidthRatio*(model: Model): float32 =
  if model.scratchpadWidthRatio > 0:
    clamp(model.scratchpadWidthRatio, 0.1'f32, 1.0'f32)
  else:
    DefaultScratchpadWidthRatio

proc effectiveScratchpadHeightRatio*(model: Model): float32 =
  if model.scratchpadHeightRatio > 0:
    clamp(model.scratchpadHeightRatio, 0.1'f32, 1.0'f32)
  else:
    DefaultScratchpadHeightRatio

proc defaultFloatingGeom*(model: Model): GeometryRect =
  let screenW = max(0'i32, model.screenWidth)
  let screenH = max(0'i32, model.screenHeight)
  let xRatio =
    if model.floatingXRatio > 0: model.floatingXRatio else: DefaultFloatingXRatio
  let yRatio =
    if model.floatingYRatio > 0: model.floatingYRatio else: DefaultFloatingYRatio
  let widthRatio =
    if model.floatingWidthRatio > 0:
      model.floatingWidthRatio
    else:
      DefaultFloatingWidthRatio
  let heightRatio =
    if model.floatingHeightRatio > 0:
      model.floatingHeightRatio
    else:
      DefaultFloatingHeightRatio
  GeometryRect(
    x: int32(float32(screenW) * clamp(xRatio, 0.0'f32, 1.0'f32)),
    y: int32(float32(screenH) * clamp(yRatio, 0.0'f32, 1.0'f32)),
    w: max(
      model.effectiveFloatingMinWidth(),
      int32(float32(screenW) * clampProportion(widthRatio)),
    ),
    h: max(
      model.effectiveFloatingMinHeight(),
      int32(float32(screenH) * clampProportion(heightRatio)),
    ),
  )

proc matches(rule: WindowRuleData, appId, title: string): bool =
  let appIdMatches = rule.appIdMatch == "" or appId.contains(rule.appIdMatch)
  let titleMatches = rule.titleMatch == "" or title.contains(rule.titleMatch)
  appIdMatches and titleMatches

proc tagRuleForSlot*(
    model: Model, slot: uint32
): tuple[found: bool, rule: TagRuleData] =
  for rule in model.tagRules:
    if rule.slot == slot:
      return (true, rule)
  (false, TagRuleData())

proc windowRuleFor*(
    model: Model, appId, title: string
): tuple[found: bool, rule: WindowRuleData] =
  for rule in model.windowRules:
    if rule.matches(appId, title):
      return (true, rule)
  (false, WindowRuleData())

proc parentedRoleFor*(model: Model, appId, title: string): ParentedRole =
  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found: ruleMatch.rule.parentedRole else: ParentedRole.Dialog

proc parentedRoleFor*(model: Model, win: WindowData): ParentedRole =
  model.parentedRoleFor(win.appId, win.title)

proc windowKeyboardShortcutsInhibit*(model: Model, appId, title: string): bool =
  let ruleMatch = model.windowRuleFor(appId, title)
  ruleMatch.found and ruleMatch.rule.keyboardShortcutsInhibit

proc window*(model: Model, winId: WindowId): Option[WindowData] =
  model.windowData(winId)

proc tag*(model: Model, tagId: TagId): Option[TagData] =
  model.tagData(tagId)

proc column*(model: Model, columnId: ColumnId): Option[ColumnData] =
  model.columnData(columnId)

proc output*(model: Model, outputId: OutputId): Option[OutputData] =
  model.outputData(outputId)

proc hasWindow*(model: Model, winId: WindowId): bool =
  model.window(winId).isSome

proc hasTag*(model: Model, tagId: TagId): bool =
  model.tag(tagId).isSome

proc hasColumn*(model: Model, columnId: ColumnId): bool =
  model.column(columnId).isSome

proc hasOutput*(model: Model, outputId: OutputId): bool =
  model.output(outputId).isSome

proc windowsCount*(model: Model): int =
  model.windows.len

proc tagsCount*(model: Model): int =
  model.tags.len

proc columnsCount*(model: Model): int =
  model.columns.len

proc outputsCount*(model: Model): int =
  model.outputs.len

proc groupsCount*(model: Model): int =
  model.groups.len
