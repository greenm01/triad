import std/options
import floating_geometry, focus, layout_projection, placement
import ../state/engine
from ../types/runtime_values import nil

type ParentedWindowIntent* {.pure.} = enum
  None
  Float
  Tile

const LargeParentedRatio = 0.9'f32

proc parentRenderRect(
    model: Model, parentExternalId: ExternalWindowId
): tuple[found: bool, rect: runtime_values.Rect] =
  if parentExternalId == NullExternalWindowId:
    return (false, runtime_values.Rect())
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if ExternalWindowId(uint32(instr.windowId)) == parentExternalId:
      return (true, instr.geom)
  (false, runtime_values.Rect())

proc parentVisibleInProjection*(
    model: Model, parentExternalId: ExternalWindowId
): bool =
  let parent = model.parentRenderRect(parentExternalId)
  parent.found and parent.rect.fullyWithin(model.primaryScreen())

proc parentWorkspaceSlot*(model: Model, parentExternalId: ExternalWindowId): uint32 =
  let parentId = model.windowForExternal(parentExternalId)
  if parentId == NullWindowId:
    return 0'u32
  let position = model.firstWindowPosition(parentId)
  if position.found:
    return position.slot
  0'u32

proc floatingGeomFromRule(model: Model, win: WindowData): runtime_values.Rect =
  let screenW = max(0'i32, model.screenWidth)
  let screenH = max(0'i32, model.screenHeight)
  result = model.defaultFloatingGeom()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  if ruleMatch.found:
    let floating = ruleMatch.rule.floating
    if floating.xRatioSet:
      result.x = int32(float32(screenW) * floating.xRatio)
    if floating.yRatioSet:
      result.y = int32(float32(screenH) * floating.yRatio)
    if floating.widthRatioSet:
      result.w = max(
        model.effectiveFloatingMinWidth(), int32(float32(screenW) * floating.widthRatio)
      )
    if floating.heightRatioSet:
      result.h = max(
        model.effectiveFloatingMinHeight(),
        int32(float32(screenH) * floating.heightRatio),
      )

proc floatingGeomForWindow*(
    model: Model, winId: WindowId, parentExternalId = NullExternalWindowId
): runtime_values.Rect =
  let screen = model.primaryScreen()
  result = model.defaultFloatingGeom()
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return result.clampToScreen(screen)
  let win = winOpt.get()
  result = model.floatingGeomFromRule(win)
  let parent = model.parentRenderRect(parentExternalId)
  if parent.found and model.parentedRoleFor(win) == runtime_values.ParentedRole.Dialog:
    return win.anchoredFloatingGeom(parent.rect, result, screen)
  result = win.applyFloatingSizeHints(result).clampToScreen(screen)

proc nearSize(size, bounds: int32): bool =
  size > 0 and bounds > 0 and float32(size) >= float32(bounds) * LargeParentedRatio

proc parentedPrimarySurfaceIntent(
    win: WindowData, parentRect: runtime_values.Rect
): bool =
  win.minWidth.nearSize(parentRect.w) and win.minHeight.nearSize(parentRect.h)

proc parentFloatingRule(model: Model, win: WindowData): tuple[set: bool, value: bool] =
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  if ruleMatch.found and ruleMatch.rule.openFloatingSet:
    return (true, ruleMatch.rule.openFloating)
  (false, false)

proc parentedWindowIntent*(model: Model, winId: WindowId): ParentedWindowIntent =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return ParentedWindowIntent.None
  let win = winOpt.get()
  if win.parentExternalId == NullExternalWindowId:
    return ParentedWindowIntent.None

  let rule = model.parentFloatingRule(win)
  if rule.set:
    if rule.value:
      return ParentedWindowIntent.Float
    return ParentedWindowIntent.Tile

  let role = model.parentedRoleFor(win)
  if role in {runtime_values.ParentedRole.Tool, runtime_values.ParentedRole.Plain}:
    return ParentedWindowIntent.Float

  let parent = model.parentRenderRect(win.parentExternalId)
  if parent.found and win.parentedPrimarySurfaceIntent(parent.rect):
    return ParentedWindowIntent.Tile
  ParentedWindowIntent.Float

proc moveWindowToParentWorkspace(
    model: var Model, winId: WindowId, parentExternalId: ExternalWindowId
): bool =
  let parentId = model.windowForExternal(parentExternalId)
  if parentId == NullWindowId:
    return false
  let position = model.firstWindowPosition(parentId)
  if not position.found:
    return false
  if model.placementForWindowOnTag(position.tagId, winId).isSome:
    return false
  discard model.removeWindowFromAllTagsAndRefreshFocus(winId)
  discard model.addPlacedWindowColumn(position.tagId, winId)
  true

proc clearWindowViewportRetarget(model: var Model, winId: WindowId): bool =
  let tagId = model.tagForWindow(winId)
  if tagId == NullTagId:
    return false
  model.clearTagViewportRetarget(tagId)

proc parentFloatingAllowed*(model: Model, winId: WindowId): bool =
  model.parentedWindowIntent(winId) == ParentedWindowIntent.Float

proc parentWorkspaceAdoptionAllowed(model: Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  model.parentedRoleFor(win) != runtime_values.ParentedRole.Plain and
    not (ruleMatch.found and ruleMatch.rule.defaultSlot != 0)

proc parentFocusAllowed*(
    model: Model, winId: WindowId, parentExternalId: ExternalWindowId
): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  if ruleMatch.found and ruleMatch.rule.openFocusedSet:
    return ruleMatch.rule.openFocused
  if model.parentedRoleFor(win) == runtime_values.ParentedRole.Plain:
    let tagId = model.tagForWindow(winId)
    return tagId != NullTagId and tagId == model.activeTag
  model.parentWorkspaceSlot(parentExternalId) == model.activeSlot

proc parentDialogViewportJump*(model: Model, parentExternalId: ExternalWindowId): bool =
  let parentId = model.windowForExternal(parentExternalId)
  if parentId == NullWindowId:
    return false
  let parentOpt = model.windowData(parentId)
  if parentOpt.isNone:
    return false
  let parent = parentOpt.get()
  let ruleMatch = model.windowRuleFor(parent.appId, parent.title)
  ruleMatch.found and ruleMatch.rule.dialogViewportJump

proc parentIsDeckBackground(model: Model, parentId: WindowId): bool =
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isNone or
      tagOpt.get().layoutMode notin
      {runtime_values.LayoutMode.Deck, runtime_values.LayoutMode.VerticalDeck}:
    return false
  parentId != model.activeFocus()

proc parentReadyForDialogFocus*(
    model: Model, parentExternalId: ExternalWindowId
): bool =
  let parentId = model.windowForExternal(parentExternalId)
  parentId != NullWindowId and model.parentVisibleInProjection(parentExternalId) and
    not model.parentIsDeckBackground(parentId)

proc applyParentFocusPolicy*(
    model: var Model, winId: WindowId, parentExternalId: ExternalWindowId
): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let role = model.parentedRoleFor(winOpt.get())
  if role != runtime_values.ParentedRole.Dialog:
    discard model.clearPendingDialogFocus(winId)
    if model.parentFocusAllowed(winId, parentExternalId):
      return model.focusWindow(winId, retargetViewport = false)
    return false

  if not model.parentFocusAllowed(winId, parentExternalId):
    discard model.clearPendingDialogFocus(winId)
    return false

  let parentId = model.windowForExternal(parentExternalId)
  if model.parentReadyForDialogFocus(parentExternalId):
    return model.focusWindow(winId, retargetViewport = false)

  if parentId != NullWindowId and parentId == model.activeFocus():
    return model.focusWindow(winId, retargetViewport = true)

  if model.parentDialogViewportJump(parentExternalId):
    return model.focusWindow(winId, retargetViewport = true, snapViewport = true)

  model.enqueuePendingDialogFocus(winId)

proc ensureFloatingAt*(
    model: var Model,
    winId: WindowId,
    geom: runtime_values.Rect,
    parentAutoFloating = false,
): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if win.isFloating and win.floatingGeom == geom and
      win.parentAutoFloating == parentAutoFloating:
    return false
  model.setWindowFloating(winId, true, geom, parentAutoFloating)

proc reconcileParentedWindowPolicy*(
    model: var Model, winId: WindowId, allowFloatCreation = false
): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if win.parentExternalId == NullExternalWindowId:
    return false

  let intent = model.parentedWindowIntent(winId)
  let rule = model.parentFloatingRule(win)
  case intent
  of ParentedWindowIntent.None:
    false
  of ParentedWindowIntent.Tile:
    if win.isFloating and (win.parentAutoFloating or (rule.set and not rule.value)):
      model.setWindowFloating(winId, false)
    else:
      false
  of ParentedWindowIntent.Float:
    let autoFloat =
      not rule.set and model.parentedRoleFor(win) == runtime_values.ParentedRole.Dialog
    if win.parentAutoFloating or (allowFloatCreation and not win.isFloating):
      let geom = model.floatingGeomForWindow(winId, win.parentExternalId)
      model.ensureFloatingAt(winId, geom, parentAutoFloating = autoFloat)
    else:
      false

proc applyParentFloatingPolicy*(
    model: var Model, winId: WindowId, parentExternalId: ExternalWindowId
): bool =
  if parentExternalId == NullExternalWindowId:
    return false
  if model.parentWorkspaceAdoptionAllowed(winId):
    result = model.moveWindowToParentWorkspace(winId, parentExternalId)
  result =
    model.reconcileParentedWindowPolicy(winId, allowFloatCreation = true) or result
  result = model.clearWindowViewportRetarget(winId) or result
  result = model.applyParentFocusPolicy(winId, parentExternalId) or result

proc applyFixedSizeFloatingPolicy*(model: var Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().hasFixedSizeHint():
    return false
  let geom = model.floatingGeomForWindow(winId, winOpt.get().parentExternalId)
  result = model.ensureFloatingAt(winId, geom)
  result = model.clearWindowViewportRetarget(winId) or result
