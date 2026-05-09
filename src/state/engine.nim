import options, strutils
import entity_manager
import id_gen
import dod_iterators
import dod_queries
import dod_invariants
import dod_snapshot
import ../core/defaults
import ../entities/dod_ops
import ../types/core
import ../types/dod_model
import ../types/shell_snapshot
from ../types/legacy_model import Grid, LayoutMode, MasterStack, Monocle,
  Scroller, VerticalScroller

export defaults
export dod_iterators
export dod_queries
export dod_invariants
export dod_snapshot
export dod_ops
export core
export dod_model
export shell_snapshot
export id_gen

type LegacyRect* = typeof(WindowData().floatingGeom)

proc clampProportion*(value: float32; lo = 0.05'f32; hi = 1.0'f32):
    float32 =
  clamp(value, lo, hi)

proc dodDefaultWindowWidth*(model: DodModel): float32 =
  if model.defaultWindowWidth > 0:
    clampProportion(model.defaultWindowWidth)
  else:
    DefaultWindowWidth

proc dodDefaultWindowHeight*(model: DodModel): float32 =
  if model.defaultWindowHeight > 0:
    clampProportion(model.defaultWindowHeight)
  else:
    DefaultWindowHeight

proc dodDefaultMasterCount*(model: DodModel): int =
  if model.defaultMasterCount > 0:
    max(1, model.defaultMasterCount)
  else:
    DefaultMasterCount

proc dodDefaultMasterRatio*(model: DodModel): float32 =
  if model.defaultMasterRatio > 0:
    clamp(model.defaultMasterRatio, 0.05'f32, 0.95'f32)
  else:
    DefaultMasterRatio

proc dodDefaultWorkspaceCount*(model: DodModel): uint32 =
  if model.defaultWorkspaceCount == 0:
    DefaultWorkspaceCount
  else:
    min(model.defaultWorkspaceCount, MaxTagBits)

proc dodDefaultColumnWidth*(model: DodModel): float32 =
  if model.defaultColumnWidth > 0:
    clamp(model.defaultColumnWidth, 0.05'f32, 1.0'f32)
  else:
    DefaultColumnWidth

proc dodLayoutCycle*(model: DodModel): seq[LayoutMode] =
  if model.layoutCycle.len > 0:
    model.layoutCycle
  else:
    @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]

proc dodSafeLayoutMode*(stored: int; fallback = Scroller): LayoutMode =
  if stored >= ord(low(LayoutMode)) + 1 and
      stored <= ord(high(LayoutMode)) + 1:
    LayoutMode(stored - 1)
  else:
    fallback

proc dodFloatingMinWidth*(model: DodModel): int32 =
  if model.floatingMinWidth > 0:
    model.floatingMinWidth
  else:
    DefaultFloatingMinWidth

proc dodFloatingMinHeight*(model: DodModel): int32 =
  if model.floatingMinHeight > 0:
    model.floatingMinHeight
  else:
    DefaultFloatingMinHeight

proc dodScratchpadWidthRatio*(model: DodModel): float32 =
  if model.scratchpadWidthRatio > 0:
    clamp(model.scratchpadWidthRatio, 0.1'f32, 1.0'f32)
  else:
    DefaultScratchpadWidthRatio

proc dodScratchpadHeightRatio*(model: DodModel): float32 =
  if model.scratchpadHeightRatio > 0:
    clamp(model.scratchpadHeightRatio, 0.1'f32, 1.0'f32)
  else:
    DefaultScratchpadHeightRatio

proc dodDefaultFloatingGeom*(model: DodModel): LegacyRect =
  let screenW = max(0'i32, model.screenWidth)
  let screenH = max(0'i32, model.screenHeight)
  let xRatio =
    if model.floatingXRatio > 0: model.floatingXRatio
    else: DefaultFloatingXRatio
  let yRatio =
    if model.floatingYRatio > 0: model.floatingYRatio
    else: DefaultFloatingYRatio
  let widthRatio =
    if model.floatingWidthRatio > 0: model.floatingWidthRatio
    else: DefaultFloatingWidthRatio
  let heightRatio =
    if model.floatingHeightRatio > 0: model.floatingHeightRatio
    else: DefaultFloatingHeightRatio
  LegacyRect(
    x: int32(float32(screenW) * clamp(xRatio, 0.0'f32, 1.0'f32)),
    y: int32(float32(screenH) * clamp(yRatio, 0.0'f32, 1.0'f32)),
    w: max(model.dodFloatingMinWidth(),
      int32(float32(screenW) * clampProportion(widthRatio))),
    h: max(model.dodFloatingMinHeight(),
      int32(float32(screenH) * clampProportion(heightRatio)))
  )

proc matches(rule: WindowRuleData; appId, title: string): bool =
  let appIdMatches = rule.appIdMatch == "" or appId.contains(rule.appIdMatch)
  let titleMatches = rule.titleMatch == "" or title.contains(rule.titleMatch)
  appIdMatches and titleMatches

proc tagRuleForSlot*(model: DodModel; slot: uint32):
    tuple[found: bool, rule: TagRuleData] =
  for rule in model.tagRules:
    if rule.slot == slot:
      return (true, rule)
  (false, TagRuleData())

proc windowRuleFor*(model: DodModel; appId, title: string):
    tuple[found: bool, rule: WindowRuleData] =
  for rule in model.windowRules:
    if rule.matches(appId, title):
      return (true, rule)
  (false, WindowRuleData())

proc windowKeyboardShortcutsInhibit*(
    model: DodModel; appId, title: string): bool =
  let ruleMatch = model.windowRuleFor(appId, title)
  ruleMatch.found and ruleMatch.rule.keyboardShortcutsInhibit

proc window*(model: DodModel; winId: WindowId): Option[WindowData] =
  model.windowData(winId)

proc tag*(model: DodModel; tagId: TagId): Option[TagData] =
  model.tagData(tagId)

proc column*(model: DodModel; columnId: ColumnId): Option[ColumnData] =
  model.columnData(columnId)

proc output*(model: DodModel; outputId: OutputId): Option[OutputData] =
  model.outputData(outputId)

proc hasWindow*(model: DodModel; winId: WindowId): bool =
  model.window(winId).isSome

proc hasTag*(model: DodModel; tagId: TagId): bool =
  model.tag(tagId).isSome

proc hasColumn*(model: DodModel; columnId: ColumnId): bool =
  model.column(columnId).isSome

proc hasOutput*(model: DodModel; outputId: OutputId): bool =
  model.output(outputId).isSome

proc windowsCount*(model: DodModel): int =
  model.windows.len

proc tagsCount*(model: DodModel): int =
  model.tags.len

proc columnsCount*(model: DodModel): int =
  model.columns.len

proc outputsCount*(model: DodModel): int =
  model.outputs.len
