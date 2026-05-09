import options, strutils
import parser
import defaults
import ../state/engine
import ../systems/dod_workspaces
import ../types/runtime_values as rv

proc dodWindowRule(rule: rv.WindowRule): WindowRuleData =
  WindowRuleData(
    appIdMatch: rule.appIdMatch,
    titleMatch: rule.titleMatch,
    defaultSlot: rule.defaultTag,
    openFloating: rule.openFloating,
    keyboardShortcutsInhibit: rule.keyboardShortcutsInhibit,
    forcedLayout: rule.forcedLayout
  )

proc dodTagRule(rule: rv.TagRule): TagRuleData =
  TagRuleData(
    slot: rule.tagId,
    name: rule.name,
    defaultLayout: rule.defaultLayout
  )

proc applyConfig*(model: var DodModel; config: Config) =
  model.outerGaps = configClamp32(config.layout.gaps, 0, 512)
  model.borderWidth = configClamp32(config.layout.borderWidth, 0, 64)
  model.focusedBorderColor = config.layout.focusedBorderColor
  model.unfocusedBorderColor = config.layout.unfocusedBorderColor
  model.scrollerFocusCenter = config.layout.scrollerFocusCenter
  model.scrollerPreferCenter = config.layout.scrollerPreferCenter
  model.innerGaps = model.outerGaps div 2
  model.centerFocusedColumn =
    runtimeCenterFocusedColumn(config.layout.centerFocusedColumn)
  model.defaultColumnWidth =
    configClampF32(config.layout.defaultColumnWidth, 0.05, 1.0)
  model.defaultWindowWidth =
    configClampF32(config.layout.defaultWindowWidth, 0.05, 1.0)
  model.defaultWindowHeight =
    configClampF32(config.layout.defaultWindowHeight, 0.05, 1.0)
  model.defaultMasterCount = max(1, config.layout.defaultMasterCount)
  model.defaultMasterRatio =
    configClampF32(config.layout.defaultMasterRatio, 0.05, 0.95)
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed =
    configClampF32(config.layout.animationSpeed, 0.0, 1.0)
  model.smartGaps = config.layout.smartGaps
  model.defaultWorkspaceCount =
    runtimeWorkspaceCount(config.workspaces.defaultCount)

  model.tagRules = @[]
  for rule in config.tagRules:
    model.tagRules.add(rule.dodTagRule())
  model.windowRules = @[]
  for rule in config.windowRules:
    model.windowRules.add(rule.dodWindowRule())

  for winId, win in model.windowsWithId():
    let inhibited =
      model.windowKeyboardShortcutsInhibit(win.appId, win.title)
    discard model.setWindowKeyboardShortcutsInhibit(winId, inhibited, false)

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
    model.screenshot.regionSelectorCommand =
      DefaultScreenshotRegionSelectorCommand

  model.overviewOuterGap = config.overview.outerGap
  if model.overviewOuterGap < 0:
    model.overviewOuterGap = DefaultOverviewOuterGap
  model.overviewInnerGapMultiplier = config.overview.innerGapMultiplier
  model.floatingXRatio = config.floating.xRatio
  model.floatingYRatio = config.floating.yRatio
  model.floatingWidthRatio = config.floating.widthRatio
  model.floatingHeightRatio = config.floating.heightRatio
  model.floatingMinWidth = config.floating.minWidth
  model.floatingMinHeight = config.floating.minHeight
  model.screenLockCommand = config.screenLock.command
  model.windowMenuCommand = config.windowMenu.command
  model.scratchpadWidthRatio =
    configClampF32(config.scratchpad.widthRatio, 0.1, 1.0)
  model.scratchpadHeightRatio =
    configClampF32(config.scratchpad.heightRatio, 0.1, 1.0)
  model.cursor = config.cursor
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
        model.columnsForTag(tagId).len == 0 and
        not model.tagHasLiveWindows(tagId):
      discard model.setTagMasterCount(tagId, model.defaultMasterCount)
      discard model.setTagMasterRatio(tagId, model.defaultMasterRatio)
    let tagRule = model.tagRuleForSlot(slot)
    if tagId != NullTagId and tagRule.found:
      discard model.setTagLayout(tagId, tagRule.rule.defaultLayout)
      discard model.setTagName(tagId, tagRule.rule.name)

  discard model.pruneDynamicWorkspaces()
  model.refreshVisibleWorkspaceSlots()
