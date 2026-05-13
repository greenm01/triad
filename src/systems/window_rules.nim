import std/re
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
