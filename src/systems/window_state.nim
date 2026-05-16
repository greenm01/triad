import std/options
import window_policy, window_rules
import ../state/engine
from ../types/runtime_values import LayoutMode, WindowRuleMaximizePolicy

proc chooseFullscreenOutput*(
    model: Model, requested: ExternalOutputId
): ExternalOutputId =
  if requested != NullExternalOutputId and
      model.outputForExternal(requested) != NullOutputId:
    return requested
  if model.primaryOutput != NullOutputId and model.hasOutput(model.primaryOutput):
    let output = model.output(model.primaryOutput)
    if output.isSome:
      return output.get().externalId
  if requested != NullExternalOutputId:
    return requested
  NullExternalOutputId

proc updateWindowDimensionsForExternal*(
    model: var Model, externalId: ExternalWindowId, w, h: int32
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDimensions(winId, w, h)

proc updateWindowDecorationHintForExternal*(
    model: var Model, externalId: ExternalWindowId, hint: uint32
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowDecorationHint(winId, hint)

proc updateWindowPresentationHintForExternal*(
    model: var Model, externalId: ExternalWindowId, hint: uint32
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowPresentationHint(winId, hint)

proc updateWindowParentForExternal*(
    model: var Model, externalId: ExternalWindowId, parentExternalId: ExternalWindowId
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  if winOpt.get().parentExternalId == parentExternalId:
    return false
  let wasPending = winOpt.get().admissionState == WindowAdmissionState.PendingAdmission
  result = true
  if wasPending:
    discard model.setWindowAdmission(winId, WindowAdmissionState.Admitted)
  discard model.setWindowParent(winId, parentExternalId)
  if parentExternalId != NullExternalWindowId:
    result = model.applyParentFloatingPolicy(winId, parentExternalId) or result

proc updateWindowIdentifierForExternal*(
    model: var Model, externalId: ExternalWindowId, identifier: string
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowIdentifier(winId, identifier)

proc updateWindowAppIdForExternal*(
    model: var Model, externalId: ExternalWindowId, appId: string
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  if not model.setWindowAppId(winId, appId):
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    discard model.setWindowKeyboardShortcutsInhibit(
      winId, model.windowKeyboardShortcutsInhibit(winOpt.get()), false
    )
    discard model.applyWindowRuleBounds(winId)
  true

proc updateWindowTitleForExternal*(
    model: var Model, externalId: ExternalWindowId, title: string
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  if not model.setWindowTitle(winId, title):
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    discard model.setWindowKeyboardShortcutsInhibit(
      winId, model.windowKeyboardShortcutsInhibit(winOpt.get()), false
    )
    discard model.applyWindowRuleBounds(winId)
  true

proc updateWindowTitleForExternalDetailed*(
    model: var Model, externalId: ExternalWindowId, title: string
): tuple[dirty: bool, manageDirty: bool] =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return
  if not model.setWindowTitle(winId, title):
    return
  result.dirty = true
  let winOpt = model.windowData(winId)
  if winOpt.isSome:
    result.manageDirty =
      model.setWindowKeyboardShortcutsInhibit(
        winId, model.windowKeyboardShortcutsInhibit(winOpt.get()), false
      ) or result.manageDirty
    result.manageDirty = model.applyWindowRuleBounds(winId) or result.manageDirty

proc updateWindowDimensionsHintForExternal*(
    model: var Model,
    externalId: ExternalWindowId,
    minWidth, minHeight, maxWidth, maxHeight: int32,
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  result =
    model.setWindowDimensionsHint(winId, minWidth, minHeight, maxWidth, maxHeight)
  result = model.applyWindowRuleBounds(winId) or result
  let winOpt = model.windowData(winId)
  if winOpt.isSome and winOpt.get().parentExternalId != NullExternalWindowId:
    result = model.reconcileParentedWindowPolicy(winId) or result
  else:
    result = model.applyFixedSizeFloatingPolicy(winId) or result

proc requestFullscreenForExternal*(
    model: var Model, externalId: ExternalWindowId, requestedOutput: ExternalOutputId
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  model.setWindowFullscreen(winId, true, model.chooseFullscreenOutput(requestedOutput))

proc exitFullscreenForExternal*(model: var Model, externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.setWindowFullscreen(winId, false)

proc toggleFullscreenForExternal*(
    model: var Model, externalId: ExternalWindowId
): bool =
  let winId = model.windowForExternal(externalId)
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFullscreen = not win.get().isFullscreen
  model.setWindowFullscreen(
    winId,
    nextFullscreen,
    if nextFullscreen:
      model.chooseFullscreenOutput(NullExternalOutputId)
    else:
      NullExternalOutputId,
  )

proc maximizePolicyFor(
    model: Model, winId: WindowId, win: WindowData
): WindowRuleMaximizePolicy =
  let ruleMatch = model.windowRuleFor(winId, win)
  if ruleMatch.found and ruleMatch.rule.maximizePolicySet:
    ruleMatch.rule.maximizePolicy
  else:
    WindowRuleMaximizePolicy.Edge

proc firstPolicyColumnPosition(
    model: Model, winId: WindowId
): tuple[found: bool, tagId: TagId, columnId: ColumnId] =
  let position = model.firstWindowPosition(winId)
  if not position.found:
    return (false, NullTagId, NullColumnId)
  let tagOpt = model.tagData(position.tagId)
  if tagOpt.isNone or
      tagOpt.get().layoutMode notin {LayoutMode.Scroller, LayoutMode.VerticalScroller}:
    return (false, NullTagId, NullColumnId)
  let placement = model.placementForWindowOnTag(position.tagId, winId)
  if placement.isNone:
    return (false, NullTagId, NullColumnId)
  (true, position.tagId, placement.get().columnId)

proc setPolicyColumnFullWidth(
    model: var Model, winId: WindowId, fullWidth: bool
): bool =
  let position = model.firstPolicyColumnPosition(winId)
  if not position.found:
    return false
  result = model.setColumnFullWidth(position.columnId, fullWidth)
  if result and position.tagId == model.activeTag:
    discard model.requestTagViewportRetarget(position.tagId)

proc policyColumnFullWidth(model: Model, winId: WindowId): bool =
  let position = model.firstPolicyColumnPosition(winId)
  if not position.found:
    return false
  let columnOpt = model.columnData(position.columnId)
  columnOpt.isSome and columnOpt.get().isFullWidth

proc applyMaximizePolicy*(model: var Model, winId: WindowId): bool =
  let win = model.window(winId)
  if win.isNone:
    return false
  case model.maximizePolicyFor(winId, win.get())
  of WindowRuleMaximizePolicy.Edge:
    result = model.setWindowMaximized(winId, true)
  of WindowRuleMaximizePolicy.Column:
    let columnChanged = model.setPolicyColumnFullWidth(winId, true)
    if columnChanged or model.policyColumnFullWidth(winId):
      result = model.setWindowMaximized(winId, false) or columnChanged
  of WindowRuleMaximizePolicy.Ignore:
    result = false

proc clearMaximizePolicy*(model: var Model, winId: WindowId): bool =
  let win = model.window(winId)
  if win.isNone:
    return false
  let policy = model.maximizePolicyFor(winId, win.get())
  result = model.setWindowMaximized(winId, false)
  if policy in {WindowRuleMaximizePolicy.Column, WindowRuleMaximizePolicy.Ignore}:
    result = model.setPolicyColumnFullWidth(winId, false) or result

proc requestMaximizeForExternal*(model: var Model, externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.applyMaximizePolicy(winId)

proc requestUnmaximizeForExternal*(
    model: var Model, externalId: ExternalWindowId
): bool =
  let winId = model.windowForExternal(externalId)
  winId != NullWindowId and model.clearMaximizePolicy(winId)

proc requestMinimizeForExternal*(model: var Model, externalId: ExternalWindowId): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId or not model.setWindowMinimized(winId, true):
    return false

  for tagId, tag in model.tagsWithId():
    if tag.focusedWindow == winId:
      var focused = NullWindowId
      for candidateId, candidate in model.windowsOnTagWithId(tagId):
        if not candidate.isMinimized and candidate.windowAdmitted():
          focused = candidateId
          break
      discard model.setTagFocus(tagId, focused)
  true

proc focusedWindow*(model: Model): WindowId =
  let tagOpt = model.tag(model.activeTag)
  if tagOpt.isNone:
    return NullWindowId
  tagOpt.get().focusedWindow

proc toggleFloatingFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFloating = not win.get().isFloating
  model.setWindowFloating(
    winId,
    nextFloating,
    if nextFloating:
      model.floatingGeomForWindow(winId, win.get().parentExternalId)
    else:
      GeometryRect(),
  )

proc setFloatingForExternal*(
    model: var Model, externalId: ExternalWindowId, floating: bool
): bool =
  let winId = model.windowForExternal(externalId)
  let win = model.window(winId)
  if win.isNone:
    return false
  model.setWindowFloating(
    winId,
    floating,
    if floating:
      model.floatingGeomForWindow(winId, win.get().parentExternalId)
    else:
      GeometryRect(),
  )

proc setMaximizedForExternal*(
    model: var Model, externalId: ExternalWindowId, maximized: bool
): bool =
  let winId = model.windowForExternal(externalId)
  if winId == NullWindowId:
    return false
  let position = model.firstWindowPosition(winId)
  let tagId = if position.found: position.tagId else: NullTagId
  if maximized and tagId == model.activeTag and
      model.columnFullWidthForWindowOnTag(tagId, winId):
    let placement = model.placementForWindowOnTag(tagId, winId)
    if placement.isSome:
      result = model.setColumnFullWidth(placement.get().columnId, false)
      if result:
        discard model.requestTagViewportRetarget(tagId)
  result = model.setWindowMaximized(winId, maximized) or result

proc toggleFullscreenFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let nextFullscreen = not win.get().isFullscreen
  model.setWindowFullscreen(
    winId,
    nextFullscreen,
    if nextFullscreen:
      model.chooseFullscreenOutput(NullExternalOutputId)
    else:
      NullExternalOutputId,
  )

proc toggleMaximizedFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  let win = model.window(winId)
  if win.isNone:
    return false
  let policy = model.maximizePolicyFor(winId, win.get())
  if policy in {WindowRuleMaximizePolicy.Column, WindowRuleMaximizePolicy.Ignore}:
    if win.get().isMaximized or model.policyColumnFullWidth(winId):
      return model.clearMaximizePolicy(winId)
    return model.applyMaximizePolicy(winId)
  if model.columnFullWidthForWindowOnTag(model.activeTag, winId):
    let placement = model.placementForWindowOnTag(model.activeTag, winId)
    if placement.isSome:
      result = model.setColumnFullWidth(placement.get().columnId, false)
      if result:
        discard model.requestTagViewportRetarget(model.activeTag)
    if win.get().isMaximized:
      return result
  result = model.setWindowMaximized(winId, not win.get().isMaximized)

proc minimizeFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  if winId == NullWindowId:
    return false
  let win = model.window(winId)
  if win.isNone:
    return false
  model.requestMinimizeForExternal(win.get().externalId)

proc toggleKeyboardShortcutsInhibitFocused*(model: var Model): bool =
  let winId = model.focusedWindow()
  winId != NullWindowId and model.toggleWindowKeyboardShortcutsInhibit(winId)
