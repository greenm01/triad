import std/[options, re]
import ../state/engine
from ../types/runtime_values import
  ParentedRole, WindowRuleFloatingConfig, WindowRuleFloatingPositionConfig

type WindowRuleMatchContext = object
  winId: WindowId
  appId: string
  title: string

proc openingContext(appId, title: string): WindowRuleMatchContext =
  WindowRuleMatchContext(winId: NullWindowId, appId: appId, title: title)

proc windowContext(winId: WindowId, win: WindowData): WindowRuleMatchContext =
  WindowRuleMatchContext(winId: winId, appId: win.appId, title: win.title)

proc stateMatcherSet(matcher: WindowRuleMatcherData): bool =
  matcher.isActiveSet or matcher.isFocusedSet or matcher.isActiveInColumnSet or
    matcher.isFloatingSet

proc usesStateMatchers(rule: WindowRuleData): bool =
  for matcher in rule.matches:
    if matcher.stateMatcherSet():
      return true
  for matcher in rule.excludes:
    if matcher.stateMatcherSet():
      return true

proc windowRuleStateMatchersEnabled*(model: Model): bool =
  for rule in model.windowRules:
    if rule.usesStateMatchers():
      return true

proc ruleFocusedWindow(model: Model): WindowId =
  if model.layerFocusExclusive:
    return NullWindowId
  let scratchpad = model.activeScratchpadWindow()
  if scratchpad != NullWindowId:
    return scratchpad
  let tagOpt = model.tagData(model.activeTag)
  if tagOpt.isSome:
    return tagOpt.get().focusedWindow
  NullWindowId

proc contextIsFocused(model: Model, context: WindowRuleMatchContext): bool =
  context.winId != NullWindowId and context.winId == model.ruleFocusedWindow()

proc contextIsActive(model: Model, context: WindowRuleMatchContext): bool =
  if context.winId == NullWindowId:
    return false
  if context.winId == model.activeScratchpadWindow():
    return true
  for tagId, tag in model.tagsWithId():
    if tag.focusedWindow == context.winId and
        model.placementForWindowOnTag(tagId, context.winId).isSome:
      return true

proc visibleTiledColumnWindow(model: Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  winOpt.isSome and winOpt.get().windowAdmitted() and not winOpt.get().isFloating and
    not winOpt.get().isMinimized and not model.windowHiddenByGroup(winId)

proc contextActiveInColumnOnTag(model: Model, tagId: TagId, winId: WindowId): bool =
  let placementOpt = model.placementForWindowOnTag(tagId, winId)
  if placementOpt.isNone:
    return false
  let columnId = placementOpt.get().columnId
  let tagOpt = model.tagData(tagId)
  if tagOpt.isSome:
    let focused = tagOpt.get().focusedWindow
    let focusedPlacement = model.placementForWindowOnTag(tagId, focused)
    if focusedPlacement.isSome and focusedPlacement.get().columnId == columnId and
        model.visibleTiledColumnWindow(focused):
      return focused == winId

  for candidate, _ in model.windowsOnColumnWithId(columnId):
    if model.visibleTiledColumnWindow(candidate):
      return candidate == winId
  false

proc contextIsActiveInColumn(model: Model, context: WindowRuleMatchContext): bool =
  if context.winId == NullWindowId:
    return true
  for tagId, _ in model.tagsWithId():
    if model.contextActiveInColumnOnTag(tagId, context.winId):
      return true

proc contextIsFloating(model: Model, context: WindowRuleMatchContext): bool =
  if context.winId == NullWindowId:
    return false
  let winOpt = model.windowData(context.winId)
  winOpt.isSome and winOpt.get().isFloating

proc matches(
    matcher: WindowRuleMatcherData, model: Model, context: WindowRuleMatchContext
): bool =
  if matcher.appIdSet and not context.appId.contains(matcher.appIdRegex):
    return false
  if matcher.titleSet and not context.title.contains(matcher.titleRegex):
    return false
  if matcher.isActiveSet and matcher.isActive != model.contextIsActive(context):
    return false
  if matcher.isFocusedSet and matcher.isFocused != model.contextIsFocused(context):
    return false
  if matcher.isActiveInColumnSet and
      matcher.isActiveInColumn != model.contextIsActiveInColumn(context):
    return false
  if matcher.isFloatingSet and matcher.isFloating != model.contextIsFloating(context):
    return false
  true

proc matches(
    rule: WindowRuleData, model: Model, context: WindowRuleMatchContext
): bool =
  var included = rule.matches.len == 0
  for matcher in rule.matches:
    if matcher.matches(model, context):
      included = true
      break
  if not included:
    return false
  for matcher in rule.excludes:
    if matcher.matches(model, context):
      return false
  true

proc mergeFloatingRule(
    target: var WindowRuleFloatingConfig, source: WindowRuleFloatingConfig
) =
  if source.xRatioSet:
    target.xRatioSet = true
    target.xRatio = source.xRatio
  if source.yRatioSet:
    target.yRatioSet = true
    target.yRatio = source.yRatio
  if source.widthRatioSet:
    target.widthRatioSet = true
    target.widthRatio = source.widthRatio
  if source.heightRatioSet:
    target.heightRatioSet = true
    target.heightRatio = source.heightRatio

proc mergeFloatingPositionRule(
    target: var WindowRuleFloatingPositionConfig,
    source: WindowRuleFloatingPositionConfig,
) =
  if source.set:
    target = source

proc applyWindowRule(result: var ResolvedWindowRuleData, rule: WindowRuleData) =
  if rule.defaultSlot != 0:
    result.defaultSlot = rule.defaultSlot
  if rule.openOnOutput.len > 0:
    result.openOnOutput = rule.openOnOutput
  if rule.defaultColumnWidthSet:
    result.defaultColumnWidthSet = true
    result.defaultColumnWidth = rule.defaultColumnWidth
  if rule.defaultWindowWidthSet:
    result.defaultWindowWidthSet = true
    result.defaultWindowWidth = rule.defaultWindowWidth
  if rule.defaultWindowHeightSet:
    result.defaultWindowHeightSet = true
    result.defaultWindowHeight = rule.defaultWindowHeight
  if rule.minWidthSet:
    result.minWidthSet = true
    result.minWidth = rule.minWidth
  if rule.minHeightSet:
    result.minHeightSet = true
    result.minHeight = rule.minHeight
  if rule.maxWidthSet:
    result.maxWidthSet = true
    result.maxWidth = rule.maxWidth
  if rule.maxHeightSet:
    result.maxHeightSet = true
    result.maxHeight = rule.maxHeight
  if rule.openFloatingSet:
    result.openFloatingSet = true
    result.openFloating = rule.openFloating
  if rule.openFocusedSet:
    result.openFocusedSet = true
    result.openFocused = rule.openFocused
  if rule.openFullscreenSet:
    result.openFullscreenSet = true
    result.openFullscreen = rule.openFullscreen
  if rule.openMaximizedSet:
    result.openMaximizedSet = true
    result.openMaximized = rule.openMaximized
  if rule.openMaximizedToEdgesSet:
    result.openMaximizedToEdgesSet = true
    result.openMaximizedToEdges = rule.openMaximizedToEdges
  if rule.parentedRoleSet:
    result.parentedRole = rule.parentedRole
  result.floating.mergeFloatingRule(rule.floating)
  result.defaultFloatingPosition.mergeFloatingPositionRule(rule.defaultFloatingPosition)
  if rule.dialogViewportJumpSet:
    result.dialogViewportJump = rule.dialogViewportJump
  if rule.keyboardShortcutsInhibitSet:
    result.keyboardShortcutsInhibit = rule.keyboardShortcutsInhibit
  if rule.tiledStateSet:
    result.tiledStateSet = true
    result.tiledState = rule.tiledState
  if rule.forcedLayoutSet:
    result.forcedLayout = rule.forcedLayout

proc windowRuleFor*(
    model: Model, appId, title: string
): tuple[found: bool, rule: ResolvedWindowRuleData] =
  let context = openingContext(appId, title)
  result.rule.parentedRole = ParentedRole.Dialog
  for rule in model.windowRules:
    if rule.matches(model, context):
      result.found = true
      result.rule.applyWindowRule(rule)

proc windowRuleFor*(
    model: Model, winId: WindowId, win: WindowData
): tuple[found: bool, rule: ResolvedWindowRuleData] =
  let context = windowContext(winId, win)
  result.rule.parentedRole = ParentedRole.Dialog
  for rule in model.windowRules:
    if rule.matches(model, context):
      result.found = true
      result.rule.applyWindowRule(rule)

proc windowRuleFor*(
    model: Model, win: WindowData
): tuple[found: bool, rule: ResolvedWindowRuleData] =
  model.windowRuleFor(win.id, win)

proc parentedRoleFor*(model: Model, appId, title: string): ParentedRole =
  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found: ruleMatch.rule.parentedRole else: ParentedRole.Dialog

proc parentedRoleFor*(model: Model, win: WindowData): ParentedRole =
  let ruleMatch = model.windowRuleFor(win)
  if ruleMatch.found: ruleMatch.rule.parentedRole else: ParentedRole.Dialog

proc windowKeyboardShortcutsInhibit*(model: Model, appId, title: string): bool =
  let ruleMatch = model.windowRuleFor(appId, title)
  ruleMatch.found and ruleMatch.rule.keyboardShortcutsInhibit

proc windowKeyboardShortcutsInhibit*(model: Model, win: WindowData): bool =
  let ruleMatch = model.windowRuleFor(win)
  ruleMatch.found and ruleMatch.rule.keyboardShortcutsInhibit

proc applyWindowRuleBounds*(model: var Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(winId, win)
  var minWidth = win.clientMinWidth
  var minHeight = win.clientMinHeight
  var maxWidth = win.clientMaxWidth
  var maxHeight = win.clientMaxHeight
  if ruleMatch.found:
    if ruleMatch.rule.minWidthSet:
      minWidth = ruleMatch.rule.minWidth
    if ruleMatch.rule.minHeightSet:
      minHeight = ruleMatch.rule.minHeight
    if ruleMatch.rule.maxWidthSet:
      maxWidth = ruleMatch.rule.maxWidth
    if ruleMatch.rule.maxHeightSet:
      maxHeight = ruleMatch.rule.maxHeight
  if win.minWidth == minWidth and win.minHeight == minHeight and win.maxWidth == maxWidth and
      win.maxHeight == maxHeight:
    return false
  model.setWindowEffectiveDimensionsHint(
    winId, minWidth, minHeight, maxWidth, maxHeight
  )

proc applyWindowRuleBounds*(model: var Model): bool =
  for winId, _ in model.windowsWithId():
    result = model.applyWindowRuleBounds(winId) or result

proc refreshWindowRuleDerivedState*(model: var Model): bool =
  for winId, win in model.windowsWithId():
    let inhibited = model.windowKeyboardShortcutsInhibit(win)
    if win.keyboardShortcutsInhibit != inhibited or
        (not inhibited and win.keyboardShortcutsInhibitBypass):
      result =
        model.setWindowKeyboardShortcutsInhibit(
          winId, inhibited, win.keyboardShortcutsInhibitBypass
        ) or result
    result = model.applyWindowRuleBounds(winId) or result
