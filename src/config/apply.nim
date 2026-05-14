import std/[options, re, strutils]
import chronicles
import parser
import defaults
import ../state/engine
import ../systems/window_rules
import ../systems/workspaces
import ../types/runtime_values as rv

proc legacyWindowRuleMatcher(rule: rv.WindowRule): rv.WindowRuleMatcher =
  if rule.appIdMatch.len > 0:
    result.appIdSet = true
    result.appId = rule.appIdMatch
  if rule.titleMatch.len > 0:
    result.titleSet = true
    result.title = rule.titleMatch

proc ruleMatchers(rule: rv.WindowRule): seq[rv.WindowRuleMatcher] =
  result = rule.matches
  if result.len == 0 and (rule.appIdMatch.len > 0 or rule.titleMatch.len > 0):
    result.add(rule.legacyWindowRuleMatcher())

proc windowRuleMatcherData(
    matcher: rv.WindowRuleMatcher, context: string
): Option[WindowRuleMatcherData] =
  try:
    result = some(
      WindowRuleMatcherData(
        appIdSet: matcher.appIdSet,
        appIdPattern: matcher.appId,
        appIdRegex:
          if matcher.appIdSet:
            re(matcher.appId)
          else:
            nil,
        titleSet: matcher.titleSet,
        titlePattern: matcher.title,
        titleRegex:
          if matcher.titleSet:
            re(matcher.title)
          else:
            nil,
        isActiveSet: matcher.isActiveSet,
        isActive: matcher.isActive,
        isFocusedSet: matcher.isFocusedSet,
        isFocused: matcher.isFocused,
        isActiveInColumnSet: matcher.isActiveInColumnSet,
        isActiveInColumn: matcher.isActiveInColumn,
        isFloatingSet: matcher.isFloatingSet,
        isFloating: matcher.isFloating,
        atStartupSet: matcher.atStartupSet,
        atStartup: matcher.atStartup,
      )
    )
  except RegexError as e:
    warn "Skipping invalid window rule regex",
      context = context, appId = matcher.appId, title = matcher.title, error = e.msg
    result = none(WindowRuleMatcherData)

proc windowRuleData(rule: rv.WindowRule, ruleIdx: int): Option[WindowRuleData] =
  var matches: seq[WindowRuleMatcherData] = @[]
  for matcherIdx, matcher in rule.ruleMatchers():
    let compiled = matcher.windowRuleMatcherData(
      "window-rule[" & $ruleIdx & "].match[" & $matcherIdx & "]"
    )
    if compiled.isNone:
      return none(WindowRuleData)
    matches.add(compiled.get())

  var excludes: seq[WindowRuleMatcherData] = @[]
  for matcherIdx, matcher in rule.excludes:
    let compiled = matcher.windowRuleMatcherData(
      "window-rule[" & $ruleIdx & "].exclude[" & $matcherIdx & "]"
    )
    if compiled.isNone:
      return none(WindowRuleData)
    excludes.add(compiled.get())

  some(
    WindowRuleData(
      matches: matches,
      excludes: excludes,
      defaultSlot: rule.defaultWorkspace,
      openOnOutput: rule.openOnOutput,
      defaultColumnWidthSet: rule.defaultColumnWidthSet or rule.defaultColumnWidth > 0,
      defaultColumnWidth: rule.defaultColumnWidth,
      scrollerProportionSet: rule.scrollerProportionSet or rule.scrollerProportion > 0,
      scrollerProportion: rule.scrollerProportion,
      scrollerSingleProportionSet:
        rule.scrollerSingleProportionSet or rule.scrollerSingleProportion > 0,
      scrollerSingleProportion: rule.scrollerSingleProportion,
      defaultWindowWidthSet: rule.defaultWindowWidthSet or rule.defaultWindowWidth > 0,
      defaultWindowWidth: rule.defaultWindowWidth,
      defaultWindowHeightSet:
        rule.defaultWindowHeightSet or rule.defaultWindowHeight > 0,
      defaultWindowHeight: rule.defaultWindowHeight,
      minWidthSet: rule.minWidthSet,
      minWidth: rule.minWidth,
      minHeightSet: rule.minHeightSet,
      minHeight: rule.minHeight,
      maxWidthSet: rule.maxWidthSet,
      maxWidth: rule.maxWidth,
      maxHeightSet: rule.maxHeightSet,
      maxHeight: rule.maxHeight,
      openFloatingSet: rule.openFloatingSet or rule.openFloating,
      openFloating: rule.openFloating,
      openFocusedSet: rule.openFocusedSet,
      openFocused: rule.openFocused,
      openFullscreenSet: rule.openFullscreenSet or rule.openFullscreen,
      openFullscreen: rule.openFullscreen,
      openMaximizedSet: rule.openMaximizedSet or rule.openMaximized,
      openMaximized: rule.openMaximized,
      openMaximizedToEdgesSet: rule.openMaximizedToEdgesSet or rule.openMaximizedToEdges,
      openMaximizedToEdges: rule.openMaximizedToEdges,
      maximizePolicySet: rule.maximizePolicySet,
      maximizePolicy: rule.maximizePolicy,
      parentedRoleSet: rule.parentedRoleSet or rule.parentedRole != ParentedRole.Dialog,
      parentedRole: rule.parentedRole,
      openNamedScratchpad: rule.openNamedScratchpad,
      floating: rule.floating,
      defaultFloatingPosition: rule.defaultFloatingPosition,
      dialogViewportJumpSet: rule.dialogViewportJumpSet or rule.dialogViewportJump,
      dialogViewportJump: rule.dialogViewportJump,
      keyboardShortcutsInhibitSet:
        rule.keyboardShortcutsInhibitSet or rule.keyboardShortcutsInhibit,
      keyboardShortcutsInhibit: rule.keyboardShortcutsInhibit,
      tiledStateSet: rule.tiledStateSet or rule.tiledState,
      tiledState: rule.tiledState,
      forcedLayoutSet: rule.forcedLayoutSet or rule.forcedLayout != 0,
      forcedLayout: rule.forcedLayout,
    )
  )

proc tagRuleData(rule: rv.TagRule): TagRuleData =
  TagRuleData(
    slot: rule.tagId,
    name: rule.name,
    defaultLayoutSet: rule.defaultLayoutSet,
    defaultLayout: rule.defaultLayout,
  )

proc applyConfig*(model: var Model, config: Config) =
  model.outerGaps = configClamp32(config.layout.gaps, 0, 512)
  model.borderWidth = configClamp32(config.layout.borderWidth, 0, 64)
  model.focusedBorderColor = config.layout.focusedBorderColor
  model.unfocusedBorderColor = config.layout.unfocusedBorderColor
  model.scrollerFocusCenter = config.layout.scrollerFocusCenter
  model.scrollerPreferCenter = config.layout.scrollerPreferCenter
  model.innerGaps = model.outerGaps div 2
  model.centerFocusedColumn =
    runtimeCenterFocusedColumn(config.layout.centerFocusedColumn)
  model.defaultColumnWidth = configClampF32(config.layout.defaultColumnWidth, 0.05, 1.0)
  model.defaultWindowWidth = configClampF32(config.layout.defaultWindowWidth, 0.05, 1.0)
  model.defaultWindowHeight =
    configClampF32(config.layout.defaultWindowHeight, 0.05, 1.0)
  model.defaultMasterCount = max(1, config.layout.defaultMasterCount)
  model.defaultMasterRatio =
    configClampF32(config.layout.defaultMasterRatio, 0.05, 0.95)
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed = configClampF32(config.layout.animationSpeed, 0.0, 1.0)
  model.smartGaps = config.layout.smartGaps
  model.defaultWorkspaceCount = runtimeWorkspaceCount(config.workspaces.defaultCount)
  model.defaultWorkspaceLayout = config.workspaces.defaultLayout

  model.tagRules = @[]
  for rule in config.tagRules:
    model.tagRules.add(rule.tagRuleData())
  model.windowRules = @[]
  for ruleIdx, rule in config.windowRules:
    let compiled = rule.windowRuleData(ruleIdx)
    if compiled.isSome:
      model.windowRules.add(compiled.get())

  discard model.refreshWindowRuleDerivedState()

  model.startupCommands = config.startupCommands
  model.quickshell = config.quickshell
  if model.quickshell.command.strip().len == 0:
    model.quickshell.command = DefaultQuickshellCommand
  model.terminal = config.terminal
  model.screenshot = config.screenshot
  if model.screenshot.directory.strip().len == 0:
    model.screenshot.directory = DefaultScreenshotDirectory
  if model.screenshot.filenamePrefix.strip().len == 0:
    model.screenshot.filenamePrefix = DefaultScreenshotFilenamePrefix
  if model.screenshot.captureCommand.strip().len == 0:
    model.screenshot.captureCommand = DefaultScreenshotCaptureCommand
  if model.screenshot.regionSelectorCommand.strip().len == 0:
    model.screenshot.regionSelectorCommand = DefaultScreenshotRegionSelectorCommand
  if model.screenshot.clipboardCommand.strip().len == 0:
    model.screenshot.clipboardCommand = DefaultScreenshotClipboardCommand

  model.overviewOuterGap = config.overview.outerGap
  if model.overviewOuterGap < 0:
    model.overviewOuterGap = DefaultOverviewOuterGap
  model.overviewInnerGapMultiplier = config.overview.innerGapMultiplier
  model.overviewZoom =
    if config.overview.zoom > 0:
      configClampF32(config.overview.zoom, 0.0001, 0.75)
    else:
      DefaultOverviewZoom
  model.overviewHotCorners = config.overview.hotCorners
  model.overviewHotCorners.size =
    if model.overviewHotCorners.size > 0:
      configClamp32(model.overviewHotCorners.size, 1, 1000)
    else:
      DefaultOverviewHotCornerSize
  model.floatingXRatio = config.floating.xRatio
  model.floatingYRatio = config.floating.yRatio
  model.floatingWidthRatio = config.floating.widthRatio
  model.floatingHeightRatio = config.floating.heightRatio
  model.floatingMinWidth = config.floating.minWidth
  model.floatingMinHeight = config.floating.minHeight
  model.screenLockCommand = config.screenLock.command
  model.windowMenuCommand = config.windowMenu.command
  model.scratchpadWidthRatio = configClampF32(config.scratchpad.widthRatio, 0.1, 1.0)
  model.scratchpadHeightRatio = configClampF32(config.scratchpad.heightRatio, 0.1, 1.0)
  model.cursor = config.cursor
  model.hotkeyOverlay = config.hotkeyOverlay
  model.presentationMode = config.presentationMode
  model.allowExitSession = config.allowExitSession
  model.protocolSurfaces = config.protocolSurfaces
  model.keyBindings = config.keyBindings
  model.pointerBindings = config.pointerBindings
  model.layoutCycle = runtimeLayoutCycle(config.layout.layoutCycle)

  for slot in 1'u32 .. model.defaultWorkspaceCount:
    discard model.ensureWorkspaceSlot(slot)

  for slot in model.sortedSlots():
    let tagId = model.tagForSlot(slot)
    let tagOpt = model.tagData(tagId)
    if tagOpt.isSome and slot <= model.defaultWorkspaceCount and
        tagOpt.get().focusedWindow == NullWindowId and
        model.columnCountForTag(tagId) == 0 and not model.tagHasLiveWindows(tagId):
      discard model.setTagMasterCount(tagId, model.defaultMasterCount)
      discard model.setTagMasterRatio(tagId, model.defaultMasterRatio)
    let tagRule = model.tagRuleForSlot(slot)
    if tagId != NullTagId:
      let emptyWorkspace =
        tagOpt.isSome and tagOpt.get().focusedWindow == NullWindowId and
        model.columnCountForTag(tagId) == 0 and not model.tagHasLiveWindows(tagId)
      if emptyWorkspace:
        discard model.setTagLayout(
          tagId,
          if tagRule.found and tagRule.rule.defaultLayoutSet:
            tagRule.rule.defaultLayout
          else:
            model.defaultWorkspaceLayout,
        )
      if tagRule.found:
        discard model.setTagName(tagId, tagRule.rule.name)

  discard model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()
