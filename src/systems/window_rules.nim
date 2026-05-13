import std/[options, re]
import ../state/engine
from ../types/runtime_values import ParentedRole, WindowRuleFloatingConfig

proc matches(matcher: WindowRuleMatcherData, appId, title: string): bool =
  if matcher.appIdSet and not appId.contains(matcher.appIdRegex):
    return false
  if matcher.titleSet and not title.contains(matcher.titleRegex):
    return false
  true

proc matches(rule: WindowRuleData, appId, title: string): bool =
  var included = rule.matches.len == 0
  for matcher in rule.matches:
    if matcher.matches(appId, title):
      included = true
      break
  if not included:
    return false
  for matcher in rule.excludes:
    if matcher.matches(appId, title):
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
  if rule.dialogViewportJumpSet:
    result.dialogViewportJump = rule.dialogViewportJump
  if rule.keyboardShortcutsInhibitSet:
    result.keyboardShortcutsInhibit = rule.keyboardShortcutsInhibit
  if rule.forcedLayoutSet:
    result.forcedLayout = rule.forcedLayout

proc windowRuleFor*(
    model: Model, appId, title: string
): tuple[found: bool, rule: ResolvedWindowRuleData] =
  result.rule.parentedRole = ParentedRole.Dialog
  for rule in model.windowRules:
    if rule.matches(appId, title):
      result.found = true
      result.rule.applyWindowRule(rule)

proc parentedRoleFor*(model: Model, appId, title: string): ParentedRole =
  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found: ruleMatch.rule.parentedRole else: ParentedRole.Dialog

proc parentedRoleFor*(model: Model, win: WindowData): ParentedRole =
  model.parentedRoleFor(win.appId, win.title)

proc windowKeyboardShortcutsInhibit*(model: Model, appId, title: string): bool =
  let ruleMatch = model.windowRuleFor(appId, title)
  ruleMatch.found and ruleMatch.rule.keyboardShortcutsInhibit

proc applyWindowRuleBounds*(model: var Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(win.appId, win.title)
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
  model.setWindowEffectiveDimensionsHint(
    winId, minWidth, minHeight, maxWidth, maxHeight
  )

proc applyWindowRuleBounds*(model: var Model): bool =
  for winId, _ in model.windowsWithId():
    result = model.applyWindowRuleBounds(winId) or result
