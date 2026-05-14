import std/[options, re]
import ../state/engine
from ../types/runtime_values import
  ParentedRole, PresentationMode, WindowRuleBorderConfig, WindowRuleFloatingConfig,
  WindowRuleFloatingPositionConfig, WindowRuleFocusRingConfig, WindowRuleIdleInhibitMode

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
    matcher.isFloatingSet or matcher.atStartupSet

proc usesStateMatchers(rule: WindowRuleData): bool =
  for matcher in rule.matches:
    if matcher.stateMatcherSet():
      return true
  for matcher in rule.excludes:
    if matcher.stateMatcherSet():
      return true

proc startupMatcherSet(matcher: WindowRuleMatcherData): bool =
  matcher.atStartupSet

proc usesStartupMatchers(rule: WindowRuleData): bool =
  for matcher in rule.matches:
    if matcher.startupMatcherSet():
      return true
  for matcher in rule.excludes:
    if matcher.startupMatcherSet():
      return true

proc windowRuleStateMatchersEnabled*(model: Model): bool =
  for rule in model.windowRules:
    if rule.usesStateMatchers():
      return true

proc windowRuleStartupMatchersEnabled*(model: Model): bool =
  for rule in model.windowRules:
    if rule.usesStartupMatchers():
      return true

proc expireStartupWindowRules*(model: var Model): bool =
  let hadStartupRules = model.windowRuleStartupMatchersEnabled()
  if not model.setStartupWindowRulesActive(false):
    return false
  hadStartupRules

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
  let columnOpt = model.columnData(columnId)
  if columnOpt.isSome:
    let columnFocused = columnOpt.get().focusedWindow
    let focusedPlacement = model.placementForWindowOnTag(tagId, columnFocused)
    if focusedPlacement.isSome and focusedPlacement.get().columnId == columnId and
        model.visibleTiledColumnWindow(columnFocused):
      return columnFocused == winId

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

proc contextIsAtStartup(model: Model, context: WindowRuleMatchContext): bool =
  discard context
  model.startupWindowRulesActive

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
  if matcher.atStartupSet and matcher.atStartup != model.contextIsAtStartup(context):
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
    target.widthSet = false
    target.widthRatio = source.widthRatio
  if source.widthSet:
    target.widthSet = true
    target.widthRatioSet = false
    target.width = source.width
  if source.heightRatioSet:
    target.heightRatioSet = true
    target.heightSet = false
    target.heightRatio = source.heightRatio
  if source.heightSet:
    target.heightSet = true
    target.heightRatioSet = false
    target.height = source.height

proc mergeFloatingPositionRule(
    target: var WindowRuleFloatingPositionConfig,
    source: WindowRuleFloatingPositionConfig,
) =
  if source.set:
    target = source

proc mergeBorderRule(
    target: var WindowRuleBorderConfig, source: WindowRuleBorderConfig
) =
  if source.widthSet:
    target.widthSet = true
    target.width = source.width
  if source.activeColorSet:
    target.activeColorSet = true
    target.activeColor = source.activeColor
  if source.inactiveColorSet:
    target.inactiveColorSet = true
    target.inactiveColor = source.inactiveColor

proc mergeFocusRingRule(
    target: var WindowRuleFocusRingConfig, source: WindowRuleFocusRingConfig
) =
  if source.widthSet:
    target.widthSet = true
    target.width = source.width
  if source.activeColorSet:
    target.activeColorSet = true
    target.activeColor = source.activeColor

proc applyWindowRule(result: var ResolvedWindowRuleData, rule: WindowRuleData) =
  if rule.defaultSlots.len > 0:
    result.defaultSlots = rule.defaultSlots
    result.defaultSlot = rule.defaultSlots[0]
  elif rule.defaultSlot != 0:
    result.defaultSlots = @[rule.defaultSlot]
    result.defaultSlot = rule.defaultSlot
  if rule.openOnOutput.len > 0:
    result.openOnOutput = rule.openOnOutput
  if rule.defaultColumnWidthSet:
    result.defaultColumnWidthSet = true
    result.defaultColumnWidth = rule.defaultColumnWidth
  if rule.scrollerProportionSet:
    result.scrollerProportionSet = true
    result.scrollerProportion = rule.scrollerProportion
    result.defaultColumnWidthSet = true
    result.defaultColumnWidth = rule.scrollerProportion
  if rule.scrollerSingleProportionSet:
    result.scrollerSingleProportionSet = true
    result.scrollerSingleProportion = rule.scrollerSingleProportion
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
  if rule.openOnAllWorkspacesSet:
    result.openOnAllWorkspacesSet = true
    result.openOnAllWorkspaces = rule.openOnAllWorkspaces
  if rule.openOverlaySet:
    result.openOverlaySet = true
    result.openOverlay = rule.openOverlay
  if rule.terminalSet:
    result.terminalSet = true
    result.terminal = rule.terminal
  if rule.allowSwallowSet:
    result.allowSwallowSet = true
    result.allowSwallow = rule.allowSwallow
  if rule.maximizePolicySet:
    result.maximizePolicySet = true
    result.maximizePolicy = rule.maximizePolicy
  if rule.respectSizeHintsSet:
    result.respectSizeHintsSet = true
    result.respectSizeHints = rule.respectSizeHints
  if rule.centerFloatingSet:
    result.centerFloatingSet = true
    result.centerFloating = rule.centerFloating
  if rule.parentedRoleSet:
    result.parentedRole = rule.parentedRole
  if rule.openNamedScratchpad.len > 0:
    result.openNamedScratchpad = rule.openNamedScratchpad
  result.floating.mergeFloatingRule(rule.floating)
  result.defaultFloatingPosition.mergeFloatingPositionRule(rule.defaultFloatingPosition)
  result.border.mergeBorderRule(rule.border)
  result.focusRing.mergeFocusRingRule(rule.focusRing)
  if rule.clipToGeometrySet:
    result.clipToGeometrySet = true
    result.clipToGeometry = rule.clipToGeometry
  if rule.dialogViewportJumpSet:
    result.dialogViewportJump = rule.dialogViewportJump
  if rule.keyboardShortcutsInhibitSet:
    result.keyboardShortcutsInhibit = rule.keyboardShortcutsInhibit
  if rule.idleInhibitModeSet:
    result.idleInhibitMode = rule.idleInhibitMode
  if rule.presentationModeSet:
    result.presentationModeSet = true
    result.presentationMode = rule.presentationMode
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
  result.rule.allowSwallow = true
  for rule in model.windowRules:
    if rule.matches(model, context):
      result.found = true
      result.rule.applyWindowRule(rule)

proc windowRuleFor*(
    model: Model, winId: WindowId, win: WindowData
): tuple[found: bool, rule: ResolvedWindowRuleData] =
  let context = windowContext(winId, win)
  result.rule.parentedRole = ParentedRole.Dialog
  result.rule.allowSwallow = true
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

proc windowIdleInhibitMode*(
    model: Model, appId, title: string
): WindowRuleIdleInhibitMode =
  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found:
    return ruleMatch.rule.idleInhibitMode
  WindowRuleIdleInhibitMode.IdleInhibitNone

proc windowIdleInhibitMode*(model: Model, win: WindowData): WindowRuleIdleInhibitMode =
  let ruleMatch = model.windowRuleFor(win)
  if ruleMatch.found:
    return ruleMatch.rule.idleInhibitMode
  WindowRuleIdleInhibitMode.IdleInhibitNone

proc windowOverlay*(model: Model, appId, title: string): bool =
  let ruleMatch = model.windowRuleFor(appId, title)
  ruleMatch.found and ruleMatch.rule.openOverlaySet and ruleMatch.rule.openOverlay

proc windowOverlay*(model: Model, win: WindowData): bool =
  let ruleMatch = model.windowRuleFor(win)
  ruleMatch.found and ruleMatch.rule.openOverlaySet and ruleMatch.rule.openOverlay

proc windowTerminalPolicy*(
    model: Model, appId, title: string
): tuple[terminal, allowSwallow: bool] =
  result.allowSwallow = true
  let ruleMatch = model.windowRuleFor(appId, title)
  if ruleMatch.found:
    if ruleMatch.rule.terminalSet:
      result.terminal = ruleMatch.rule.terminal
    if ruleMatch.rule.allowSwallowSet:
      result.allowSwallow = ruleMatch.rule.allowSwallow

proc windowTerminalPolicy*(
    model: Model, win: WindowData
): tuple[terminal, allowSwallow: bool] =
  model.windowTerminalPolicy(win.appId, win.title)

proc windowClipToGeometry*(model: Model, winId: WindowId): bool =
  if winId == NullWindowId:
    return false
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let ruleMatch = model.windowRuleFor(winId, winOpt.get())
  ruleMatch.found and ruleMatch.rule.clipToGeometrySet and ruleMatch.rule.clipToGeometry

proc effectivePresentationMode*(
    model: Model
): tuple[hasPreference: bool, mode: PresentationMode] =
  let focused = model.ruleFocusedWindow()
  if focused != NullWindowId:
    let winOpt = model.windowData(focused)
    if winOpt.isSome:
      let ruleMatch = model.windowRuleFor(focused, winOpt.get())
      if ruleMatch.found and ruleMatch.rule.presentationModeSet:
        if ruleMatch.rule.presentationMode == PresentationMode.PresentationDefault:
          return (
            hasPreference:
              model.presentationMode != PresentationMode.PresentationDefault,
            mode: model.presentationMode,
          )
        return (hasPreference: true, mode: ruleMatch.rule.presentationMode)
  (
    hasPreference: model.presentationMode != PresentationMode.PresentationDefault,
    mode: model.presentationMode,
  )

proc effectiveWindowBorder*(
    model: Model, winId: WindowId, focused = false
): tuple[width: int32, activeColor: uint32, inactiveColor: uint32] =
  result.width = model.borderWidth
  result.activeColor = model.focusedBorderColor
  result.inactiveColor = model.unfocusedBorderColor
  if winId == NullWindowId:
    return
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return
  let ruleMatch = model.windowRuleFor(winId, winOpt.get())
  if ruleMatch.found:
    if ruleMatch.rule.border.widthSet:
      result.width = ruleMatch.rule.border.width
    if ruleMatch.rule.border.activeColorSet:
      result.activeColor = ruleMatch.rule.border.activeColor
    if ruleMatch.rule.border.inactiveColorSet:
      result.inactiveColor = ruleMatch.rule.border.inactiveColor
    if focused:
      if ruleMatch.rule.focusRing.widthSet:
        result.width = ruleMatch.rule.focusRing.width
      if ruleMatch.rule.focusRing.activeColorSet:
        result.activeColor = ruleMatch.rule.focusRing.activeColor

proc windowRespectsSizeHints*(model: Model, winId: WindowId, win: WindowData): bool =
  let ruleMatch = model.windowRuleFor(winId, win)
  not ruleMatch.found or not ruleMatch.rule.respectSizeHintsSet or
    ruleMatch.rule.respectSizeHints

proc applyWindowRuleBounds*(model: var Model, winId: WindowId): bool =
  let winOpt = model.windowData(winId)
  if winOpt.isNone:
    return false
  let win = winOpt.get()
  let ruleMatch = model.windowRuleFor(winId, win)
  let respectSizeHints =
    not ruleMatch.found or not ruleMatch.rule.respectSizeHintsSet or
    ruleMatch.rule.respectSizeHints
  var minWidth = if respectSizeHints: win.clientMinWidth else: 0'i32
  var minHeight = if respectSizeHints: win.clientMinHeight else: 0'i32
  var maxWidth = if respectSizeHints: win.clientMaxWidth else: 0'i32
  var maxHeight = if respectSizeHints: win.clientMaxHeight else: 0'i32
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
    let idleInhibitMode = model.windowIdleInhibitMode(win)
    result = model.setWindowIdleInhibitMode(winId, idleInhibitMode) or result
    let overlay = model.windowOverlay(win)
    result = model.setWindowOverlay(winId, overlay) or result
    let terminalPolicy = model.windowTerminalPolicy(win)
    result =
      model.setWindowTerminalPolicy(
        winId, terminalPolicy.terminal, terminalPolicy.allowSwallow
      ) or result
    result = model.applyWindowRuleBounds(winId) or result
