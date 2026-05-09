import strutils, tables
import parser
import defaults
import ../core/model
import ../core/model_utils

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
  model.workspaces = config.workspaces
  model.workspaces.defaultCount =
    runtimeWorkspaceCount(model.workspaces.defaultCount)
  model.tagRules = config.tagRules
  model.windowRules = config.windowRules

  for _, win in model.windows.mpairs:
    win.keyboardShortcutsInhibit =
      model.windowKeyboardShortcutsInhibit(win.appId, win.title)
    if not win.keyboardShortcutsInhibit:
      win.keyboardShortcutsInhibitBypass = false

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

  model.overview = config.overview
  if model.overview.outerGap < 0:
    model.overview.outerGap = DefaultOverviewOuterGap
  model.floating = config.floating
  model.screenLock = config.screenLock
  model.windowMenu = config.windowMenu
  model.scratchpad = config.scratchpad
  model.cursor = config.cursor
  model.presentationMode = config.presentationMode
  model.allowExitSession = config.allowExitSession
  model.protocolSurfaces = config.protocolSurfaces
  model.keyBindings = config.keyBindings
  model.pointerBindings = config.pointerBindings
  model.layoutCycle = runtimeLayoutCycle(config.layout.layoutCycle)
  model.scratchpadWidthRatio =
    configClampF32(config.scratchpad.widthRatio, 0.1, 1.0)
  model.scratchpadHeightRatio =
    configClampF32(config.scratchpad.heightRatio, 0.1, 1.0)

  model.ensureDefaultWorkspaces()

  for rule in config.tagRules:
    if model.tags.hasKey(rule.tagId):
      model.tags[rule.tagId].layoutMode = rule.defaultLayout
      model.tags[rule.tagId].name = rule.name
  discard model.pruneDynamicWorkspaces()
