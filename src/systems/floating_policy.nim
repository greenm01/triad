import options
import focus
import layout_projection
import placement
import ../state/engine
from ../types/runtime_values import nil

proc fixedSizeWidth(win: WindowData): int32 =
  if win.minWidth > 0 and win.maxWidth == win.minWidth:
    win.minWidth
  else:
    0'i32

proc fixedSizeHeight(win: WindowData): int32 =
  if win.minHeight > 0 and win.maxHeight == win.minHeight:
    win.minHeight
  else:
    0'i32

proc hasFixedSizeHint*(win: WindowData): bool =
  win.minWidth > 0 and win.minHeight > 0 and
    (win.fixedSizeWidth() > 0 or win.fixedSizeHeight() > 0)

proc applySizeHints(model: Model; winId: WindowId;
    geom: runtime_values.Rect): runtime_values.Rect =
  result = geom
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return

  let win = winOpt.get()
  let fixedW = win.fixedSizeWidth()
  let fixedH = win.fixedSizeHeight()
  if fixedW > 0:
    result.w = fixedW
  elif win.minWidth > 0:
    result.w = max(result.w, win.minWidth)
  if fixedH > 0:
    result.h = fixedH
  elif win.minHeight > 0:
    result.h = max(result.h, win.minHeight)

  if win.maxWidth > 0:
    result.w = min(result.w, win.maxWidth)
  if win.maxHeight > 0:
    result.h = min(result.h, win.maxHeight)

proc clampToScreen(geom, screen: runtime_values.Rect): runtime_values.Rect =
  result = geom
  result.w = max(0'i32, result.w)
  result.h = max(0'i32, result.h)
  if screen.w > 0:
    result.w = min(result.w, screen.w)
    result.x = clamp(result.x, screen.x, screen.x + screen.w - result.w)
  if screen.h > 0:
    result.h = min(result.h, screen.h)
    result.y = clamp(result.y, screen.y, screen.y + screen.h - result.h)

proc centeredIn(bounds, geom: runtime_values.Rect): runtime_values.Rect =
  result = geom
  result.x = bounds.x + (bounds.w - geom.w) div 2
  result.y = bounds.y + (bounds.h - geom.h) div 2

proc parentRenderRect(model: Model; parentExternalId: ExternalWindowId):
    tuple[found: bool; rect: runtime_values.Rect] =
  if parentExternalId == NullExternalWindowId:
    return (false, runtime_values.Rect())
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if ExternalWindowId(uint32(instr.windowId)) == parentExternalId:
      return (true, instr.geom)
  (false, runtime_values.Rect())

proc parentWorkspaceSlot*(model: Model;
    parentExternalId: ExternalWindowId): uint32 =
  let parentId = model.windowForExternal(parentExternalId)
  if parentId == NullWindowId:
    return 0'u32
  let position = model.firstWindowPosition(parentId)
  if position.found:
    return position.slot
  0'u32

proc floatingGeomForWindow*(model: Model; winId: WindowId;
    parentExternalId = NullExternalWindowId): runtime_values.Rect =
  let screen = model.primaryScreen()
  result = model.applySizeHints(winId, model.defaultFloatingGeom())
  let parent = model.parentRenderRect(parentExternalId)
  if parent.found:
    result = parent.rect.centeredIn(result)
  result = result.clampToScreen(screen)

proc moveWindowToParentWorkspace(model: var Model; winId: WindowId;
    parentExternalId: ExternalWindowId): bool =
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

proc clearWindowViewportRetarget(model: var Model; winId: WindowId): bool =
  let tagId = model.tagForWindow(winId)
  if tagId == NullTagId:
    return false
  model.clearTagViewportRetarget(tagId)

proc parentFloatingAllowed*(model: Model; winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  if ruleMatch.found and ruleMatch.rule.openFloatingSet:
    return ruleMatch.rule.openFloating
  true

proc parentFocusAllowed*(model: Model; winId: WindowId;
    parentExternalId: ExternalWindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
  if ruleMatch.found and ruleMatch.rule.openFocusedSet:
    return ruleMatch.rule.openFocused
  model.parentWorkspaceSlot(parentExternalId) == model.activeSlot

proc ensureFloatingAt*(model: var Model; winId: WindowId;
    geom: runtime_values.Rect): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  if win.isFloating and win.floatingGeom == geom:
    return false
  model.setWindowFloating(winId, true, geom)

proc applyParentFloatingPolicy*(model: var Model; winId: WindowId;
    parentExternalId: ExternalWindowId): bool =
  if parentExternalId == NullExternalWindowId:
    return false
  result = model.moveWindowToParentWorkspace(winId, parentExternalId)
  if model.parentFloatingAllowed(winId):
    let geom = model.floatingGeomForWindow(winId, parentExternalId)
    result = model.ensureFloatingAt(winId, geom) or result
  result = model.clearWindowViewportRetarget(winId) or result
  if model.parentFocusAllowed(winId, parentExternalId):
    result = model.focusWindow(winId, retargetViewport = false) or result

proc applyFixedSizeFloatingPolicy*(model: var Model; winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone or not winOpt.get().hasFixedSizeHint():
    return false
  let geom = model.floatingGeomForWindow(
    winId, winOpt.get().parentExternalId)
  result = model.ensureFloatingAt(winId, geom)
  result = model.clearWindowViewportRetarget(winId) or result
