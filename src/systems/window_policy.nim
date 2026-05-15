import std/options
import floating_geometry, focus, layout_projection, placement, window_rules
import ../state/engine
import ../types/system_views
from ../types/runtime_values import nil

export system_views

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

proc tagHasSameAppNormal(
    model: Model, tagId: TagId, appId: string, exceptWinId: WindowId
): bool =
  for winId, win in model.windowsOnTagWithId(tagId):
    if winId != exceptWinId and win.windowAdmitted() and not win.isFloating and
        not win.isMinimized and win.appId == appId:
      return true

proc leadFloatingAnchorFor*(
    model: Model,
    tagId: TagId,
    winId: WindowId,
    appId: string,
    isFloating: bool,
    parentExternalId: ExternalWindowId,
    pendingAdmission: bool,
): LeadFloatingAnchor =
  if isFloating or pendingAdmission or parentExternalId != NullExternalWindowId or
      tagId == NullTagId or tagId != model.activeTag or appId.len == 0:
    return

  let focused = model.focusedOnActiveTag()
  if focused == NullWindowId or focused == winId:
    return

  let focusedOpt = model.windowData(focused)
  if focusedOpt.isNone:
    return

  let lead = focusedOpt.get()
  if not lead.windowAdmitted() or not lead.isFloating or lead.isMinimized or
      lead.parentExternalId != NullExternalWindowId or lead.appId != appId:
    return
  if model.tagHasSameAppNormal(tagId, appId, winId):
    return

  let placementOpt = model.placementForWindowOnTag(tagId, focused)
  if placementOpt.isNone:
    return

  LeadFloatingAnchor(found: true, winId: focused, columnId: placementOpt.get().columnId)

proc instructionGeomFor(model: Model, winId: WindowId): GeometryRect =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return
  let externalId = uint32(winOpt.get().externalId)
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if uint32(instr.windowId) == externalId:
      return instr.geom

proc floatingGeomForWindow*(
  model: Model, winId: WindowId, parentExternalId = NullExternalWindowId
): runtime_values.Rect

proc recenterLeadFloatingAnchor*(
    model: var Model, anchor: LeadFloatingAnchor, mainWinId: WindowId
): bool =
  if not anchor.found:
    return false
  let leadOpt = model.windowData(anchor.winId)
  if leadOpt.isNone:
    return false

  let mainGeom = model.instructionGeomFor(mainWinId)
  if mainGeom.w <= 0 or mainGeom.h <= 0:
    return false

  var leadGeom = leadOpt.get().floatingGeom
  if leadGeom.w <= 0 or leadGeom.h <= 0:
    leadGeom = model.floatingGeomForWindow(anchor.winId)

  let centered = mainGeom
    .centeredIn(leadOpt.get().applyFloatingSizeHints(leadGeom))
    .clampToScreen(model.primaryScreen())
  model.setWindowFloatingGeom(anchor.winId, centered)

proc floatingGeomFromRule(
    model: Model, win: WindowData
): tuple[
  geom: runtime_values.Rect,
  position: runtime_values.WindowRuleFloatingPositionConfig,
  center: bool,
] =
  let screenW = max(0'i32, model.screenWidth)
  let screenH = max(0'i32, model.screenHeight)
  result.geom = model.defaultFloatingGeom()
  let ruleMatch = model.windowRuleFor(win)
  if ruleMatch.found:
    let floating = ruleMatch.rule.floating
    if floating.xRatioSet:
      result.geom.x = int32(float32(screenW) * floating.xRatio)
    if floating.yRatioSet:
      result.geom.y = int32(float32(screenH) * floating.yRatio)
    if floating.widthRatioSet:
      result.geom.w = max(
        model.effectiveFloatingMinWidth(), int32(float32(screenW) * floating.widthRatio)
      )
    if floating.widthSet:
      result.geom.w = max(model.effectiveFloatingMinWidth(), floating.width)
    if floating.heightRatioSet:
      result.geom.h = max(
        model.effectiveFloatingMinHeight(),
        int32(float32(screenH) * floating.heightRatio),
      )
    if floating.heightSet:
      result.geom.h = max(model.effectiveFloatingMinHeight(), floating.height)
    result.position = ruleMatch.rule.defaultFloatingPosition
    result.center = ruleMatch.rule.centerFloatingSet and ruleMatch.rule.centerFloating

proc floatingGeomForWindow*(
    model: Model, winId: WindowId, parentExternalId: ExternalWindowId
): runtime_values.Rect =
  let screen = model.primaryScreen()
  result = model.defaultFloatingGeom()
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return result.clampToScreen(screen)
  let win = winOpt.get()
  let resolved = model.floatingGeomFromRule(win)
  result = resolved.geom
  let parent = model.parentRenderRect(parentExternalId)
  if parent.found and model.parentedRoleFor(win) == runtime_values.ParentedRole.Dialog:
    return win.anchoredFloatingGeom(parent.rect, result, screen)
  result = win.applyFloatingSizeHints(result)
  if resolved.position.set:
    result = screen.positionedByAnchor(result, resolved.position)
  elif resolved.center:
    result = screen.centeredIn(result)
  result = result.clampToScreen(screen)

proc nearSize(size, bounds: int32): bool =
  size > 0 and bounds > 0 and float32(size) >= float32(bounds) * LargeParentedRatio

proc parentedPrimarySurfaceIntent(
    win: WindowData, parentRect: runtime_values.Rect
): bool =
  win.clientMinWidth.nearSize(parentRect.w) and
    win.clientMinHeight.nearSize(parentRect.h)

proc parentFloatingRule(model: Model, win: WindowData): tuple[set: bool, value: bool] =
  let ruleMatch = model.windowRuleFor(win)
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
  if parent.found and model.windowRespectsSizeHints(winId, win) and
      win.parentedPrimarySurfaceIntent(parent.rect):
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
  let ruleMatch = model.windowRuleFor(win)
  model.parentedRoleFor(win) != runtime_values.ParentedRole.Plain and
    not (ruleMatch.found and ruleMatch.rule.defaultSlot != 0)

proc parentFocusAllowed*(
    model: Model, winId: WindowId, parentExternalId: ExternalWindowId
): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win)
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
  let ruleMatch = model.windowRuleFor(parent)
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
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if not model.windowRespectsSizeHints(winId, win) or not win.hasClientFixedSizeHint():
    return false
  let geom = model.floatingGeomForWindow(winId, win.parentExternalId)
  result = model.ensureFloatingAt(winId, geom)
  result = model.clearWindowViewportRetarget(winId) or result
