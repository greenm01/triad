import std/[options, re, sets, strutils]
import chronicles
import parser
import defaults
import ../core/shell_profiles
import ../state/engine
import ../systems/outputs
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

proc workspaceTargets(rule: rv.WindowRule): seq[uint32] =
  if rule.defaultWorkspaces.len > 0:
    for slot in rule.defaultWorkspaces:
      if slot > 0 and result.find(slot) == -1:
        result.add(slot)
  elif rule.defaultWorkspace != 0:
    result.add(rule.defaultWorkspace)

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

  let targets = rule.workspaceTargets()
  some(
    WindowRuleData(
      matches: matches,
      excludes: excludes,
      defaultSlot:
        if targets.len > 0:
          targets[0]
        else:
          0'u32,
      defaultSlots: targets,
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
      openOnAllWorkspacesSet: rule.openOnAllWorkspacesSet,
      openOnAllWorkspaces: rule.openOnAllWorkspaces,
      openOverlaySet: rule.openOverlaySet or rule.openOverlay,
      openOverlay: rule.openOverlay,
      openUnmanagedGlobalSet: rule.openUnmanagedGlobalSet or rule.openUnmanagedGlobal,
      openUnmanagedGlobal: rule.openUnmanagedGlobal,
      terminalSet: rule.terminalSet or rule.terminal,
      terminal: rule.terminal,
      allowSwallowSet: rule.allowSwallowSet,
      allowSwallow: rule.allowSwallow,
      maximizePolicySet: rule.maximizePolicySet,
      maximizePolicy: rule.maximizePolicy,
      respectSizeHintsSet: rule.respectSizeHintsSet,
      respectSizeHints: rule.respectSizeHints,
      centerFloatingSet: rule.centerFloatingSet,
      centerFloating: rule.centerFloating,
      parentedRoleSet: rule.parentedRoleSet or rule.parentedRole != ParentedRole.Dialog,
      parentedRole: rule.parentedRole,
      openNamedScratchpad: rule.openNamedScratchpad,
      floating: rule.floating,
      defaultFloatingPosition: rule.defaultFloatingPosition,
      border: rule.border,
      focusRing: rule.focusRing,
      clipToGeometrySet: rule.clipToGeometrySet,
      clipToGeometry: rule.clipToGeometry,
      dialogViewportJumpSet: rule.dialogViewportJumpSet or rule.dialogViewportJump,
      dialogViewportJump: rule.dialogViewportJump,
      keyboardShortcutsInhibitSet:
        rule.keyboardShortcutsInhibitSet or rule.keyboardShortcutsInhibit,
      keyboardShortcutsInhibit: rule.keyboardShortcutsInhibit,
      idleInhibitModeSet: rule.idleInhibitModeSet,
      idleInhibitMode: rule.idleInhibitMode,
      presentationModeSet: rule.presentationModeSet,
      presentationMode: rule.presentationMode,
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
    openOnOutput: rule.openOnOutput.strip(),
  )

proc outputRuleData(rule: rv.OutputRule): OutputRuleData =
  OutputRuleData(
    target: rule.target.strip(),
    focusAtStartup: rule.focusAtStartup,
    workspaceSlots: rule.workspaceSlots,
  )

proc legacyShellsFromQuickshell(config: rv.QuickshellConfig): rv.ShellsConfig =
  var command = config.command.strip()
  if command.len == 0:
    command = DefaultQuickshellCommand
  if not config.enabled or config.theme.strip().len == 0:
    return rv.ShellsConfig(enabled: false)

  var launch = @[command, "-c", config.theme]
  for arg in config.args:
    launch.add(arg)

  rv.ShellsConfig(
    enabled: true,
    active: "quickshell",
    cycle: @["quickshell"],
    profiles:
      @[
        rv.ShellProfileConfig(
          name: "quickshell",
          launch: launch,
          stop: @[command, "kill", "-c", config.theme, "--any-display"],
          niriCompat: true,
        )
      ],
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
  model.scrollerProportionPresets =
    normalizedProportionPresets(config.layout.scrollerProportionPresets)
  model.defaultWindowWidth = configClampF32(config.layout.defaultWindowWidth, 0.05, 1.0)
  model.defaultWindowHeight =
    configClampF32(config.layout.defaultWindowHeight, 0.05, 1.0)
  model.defaultMasterCount = max(1, config.layout.defaultMasterCount)
  model.defaultMasterRatio =
    configClampF32(config.layout.defaultMasterRatio, 0.05, 0.95)
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed = configClampF32(config.layout.animationSpeed, 0.0, 1.0)
  model.animationSnapThreshold =
    configClampF32(config.layout.animationSnapThreshold, 0.01, 64.0)
  model.smartGaps = config.layout.smartGaps
  model.defaultWorkspaceCount = runtimeWorkspaceCount(config.workspaces.defaultCount)
  model.defaultWorkspaceLayout = config.workspaces.defaultLayout

  var pinnedTagOutputs: seq[TagId] = @[]
  for tagId in model.tagHomeOutputPinned:
    pinnedTagOutputs.add(tagId)
  for tagId in pinnedTagOutputs:
    discard model.clearTagHomeOutput(tagId)

  model.outputRules = @[]
  for rule in config.outputRules:
    model.outputRules.add(rule.outputRuleData())
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
  model.shells =
    if config.shells.configured:
      config.shells
    else:
      model.quickshell.legacyShellsFromQuickshell()
  model.shells.normalizeShells()
  model.janet = config.janet
  if model.janet.manifestDir.strip().len == 0:
    model.janet.manifestDir = DefaultJanetManifestDir
  if model.janet.systemManifestDir.strip().len == 0:
    model.janet.systemManifestDir = DefaultJanetSystemManifestDir
  model.janet.fuelLimit = configClamp32(model.janet.fuelLimit, 1_000, 10_000_000)
  model.terminal = config.terminal
  model.screenshot = config.screenshot
  model.input = config.input
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

  model.environment = config.environment
  model.overviewOuterGap = config.overview.outerGap
  if model.overviewOuterGap < 0:
    model.overviewOuterGap = DefaultOverviewOuterGap
  model.overviewInnerGapMultiplier = config.overview.innerGapMultiplier
  model.overviewZoom =
    if config.overview.zoom > 0:
      configClampF32(config.overview.zoom, 0.0001, 0.75)
    else:
      DefaultOverviewZoom
  model.overviewTabMode = config.overview.tabMode
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
  model.configNotification = config.configNotification
  model.recentWindows = config.recentWindows
  model.recentWindows.debounceMs =
    configClamp32(model.recentWindows.debounceMs, 0, 60000)
  model.recentWindows.openDelayMs =
    configClamp32(model.recentWindows.openDelayMs, 0, 60000)
  model.recentWindows.highlight.padding =
    configClamp32(model.recentWindows.highlight.padding, 0, 65535)
  model.recentWindows.highlight.cornerRadius =
    configClamp32(model.recentWindows.highlight.cornerRadius, 0, 65535)
  model.recentWindows.previews.maxHeight =
    configClamp32(model.recentWindows.previews.maxHeight, 1, 65535)
  model.recentWindows.previews.maxScale =
    configClampF32(model.recentWindows.previews.maxScale, 0.01, 1.0)
  if not model.recentWindows.enabled:
    discard model.closeRecentWindows()
  model.presentationMode = config.presentationMode
  model.allowExitSession = config.allowExitSession
  model.protocolSurfaces = config.protocolSurfaces
  model.keyBindings = config.keyBindings
  model.pointerBindings = config.pointerBindings
  model.axisBindings = config.axisBindings
  model.gestureBindings = config.gestureBindings
  model.switchEvents = config.switchEvents
  model.layoutCycle = runtimeLayoutCycle(config.layout.layoutCycle)

  for slot in 1'u32 .. model.defaultWorkspaceCount:
    discard model.ensureWorkspaceSlot(slot)

  for rule in model.outputRules:
    if rule.target.len > 0:
      for slot in rule.workspaceSlots:
        let tagId = model.ensureWorkspaceSlot(slot)
        if tagId != NullTagId:
          discard model.setTagHomeOutput(tagId, rule.target, pinned = true)
          let outputId = model.outputForTarget(rule.target)
          if outputId != NullOutputId:
            discard model.setTagOutput(tagId, outputId)

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
        if tagRule.rule.openOnOutput.len > 0:
          discard
            model.setTagHomeOutput(tagId, tagRule.rule.openOnOutput, pinned = true)
          let outputId = model.outputForTarget(tagRule.rule.openOnOutput)
          if outputId != NullOutputId:
            discard model.setTagOutput(tagId, outputId)

  discard model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()
  discard model.applyStartupOutputFocus()
