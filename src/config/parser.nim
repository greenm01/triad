import std/[os, re, strutils]
import chronicles, kdl
import defaults
import ../types/runtime_values

type
  Config* = object
    layout*: LayoutConfig
    workspaces*: WorkspaceConfig
    tagRules*: seq[TagRule]
    windowRules*: seq[WindowRule]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    overview*: OverviewConfig
    floating*: FloatingConfig
    screenLock*: ScreenLockConfig
    windowMenu*: WindowMenuConfig
    scratchpad*: ScratchpadConfig
    cursor*: CursorConfig
    hotkeyOverlay*: HotkeyOverlayConfig
    presentationMode*: PresentationMode
    allowExitSession*: bool
    protocolSurfaces*: ProtocolSurfacesConfig
    mirrorHjklArrows*: bool
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]

  LayoutConfig* = object
    gaps*: int32
    centerFocusedColumn*: string # "never", "always", "on-overflow"
    defaultColumnWidth*: float32
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    borderWidth*: int32
    focusedBorderColor*: uint32
    unfocusedBorderColor*: uint32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    enableAnimations*: bool
    animationSpeed*: float32
    smartGaps*: bool
    layoutCycle*: seq[LayoutMode]

  ConfigLoadResult* = object
    ok*: bool
    config*: Config
    error*: string

proc clamp32(value, lo, hi: int32): int32 =
  min(hi, max(lo, value))

proc clampF32(value, lo, hi: float32): float32 =
  min(hi, max(lo, value))

proc configClamp32*(value, lo, hi: int32): int32 =
  clamp32(value, lo, hi)

proc configClampF32*(value, lo, hi: float32): float32 =
  clampF32(value, lo, hi)

proc proportionChild(
    node: KdlNode, lo = 0.05'f32, hi = 1.0'f32
): tuple[found: bool, value: float32] =
  if node.children.len > 0 and node.children[0].name == "proportion" and
      node.children[0].args.len > 0:
    result.found = true
    result.value = clampF32(float32(node.children[0].args[0].kFloat()), lo, hi)

proc runtimeWorkspaceCount*(count: uint32): uint32 =
  if count == 0:
    DefaultWorkspaceCount
  else:
    min(count, MaxWorkspaceCount)

proc runtimeCenterFocusedColumn*(value: string): string =
  if value in ["never", "always", "on-overflow"]: value else: "never"

proc runtimeLayoutCycle*(cycle: seq[LayoutMode]): seq[LayoutMode] =
  if cycle.len > 0:
    cycle
  else:
    @[
      LayoutMode.Scroller, LayoutMode.MasterStack, LayoutMode.Grid, LayoutMode.Monocle,
      LayoutMode.VerticalScroller,
    ]

proc normalizeWorkspaceCountFromConfig(count: int): uint32 =
  if count <= 0:
    DefaultWorkspaceCount
  else:
    runtimeWorkspaceCount(uint32(count))

proc parseColor(value: string, fallback: uint32): uint32 =
  var hex = value.strip()
  if hex.startsWith("#"):
    hex = hex[1 ..^ 1]
  if hex.len == 6:
    hex.add("ff")
  if hex.len != 8:
    return fallback

  try:
    result = uint32(parseHexInt(hex))
  except CatchableError:
    result = fallback

proc parseLayoutName(name: string, fallback: LayoutMode): LayoutMode =
  case name
  of "scroller": LayoutMode.Scroller
  of "vertical-scroller": LayoutMode.VerticalScroller
  of "tile": LayoutMode.MasterStack
  of "grid": LayoutMode.Grid
  of "monocle": LayoutMode.Monocle
  of "deck": LayoutMode.Deck
  of "center-tile", "center_tile": LayoutMode.CenterTile
  of "right-tile", "right_tile": LayoutMode.RightTile
  of "vertical-tile", "vertical_tile": LayoutMode.VerticalTile
  of "vertical-grid", "vertical_grid": LayoutMode.VerticalGrid
  of "vertical-deck", "vertical_deck": LayoutMode.VerticalDeck
  of "tgmix", "tg_mix": LayoutMode.TGMix
  else: fallback

proc forcedLayoutValue(name: string): int =
  case name
  of "scroller":
    ord(LayoutMode.Scroller) + 1
  of "vertical-scroller":
    ord(LayoutMode.VerticalScroller) + 1
  of "tile":
    ord(LayoutMode.MasterStack) + 1
  of "grid":
    ord(LayoutMode.Grid) + 1
  of "monocle":
    ord(LayoutMode.Monocle) + 1
  of "deck":
    ord(LayoutMode.Deck) + 1
  of "center-tile", "center_tile":
    ord(LayoutMode.CenterTile) + 1
  of "right-tile", "right_tile":
    ord(LayoutMode.RightTile) + 1
  of "vertical-tile", "vertical_tile":
    ord(LayoutMode.VerticalTile) + 1
  of "vertical-grid", "vertical_grid":
    ord(LayoutMode.VerticalGrid) + 1
  of "vertical-deck", "vertical_deck":
    ord(LayoutMode.VerticalDeck) + 1
  of "tgmix", "tg_mix":
    ord(LayoutMode.TGMix) + 1
  else:
    0

proc parseParentedRole(name: string): ParentedRole =
  case name.toLowerAscii()
  of "dialog":
    ParentedRole.Dialog
  of "tool":
    ParentedRole.Tool
  of "plain":
    ParentedRole.Plain
  else:
    raise newException(ValueError, "invalid parented-role: " & name)

proc modifierValue(name: string): uint32 =
  case name
  of "Shift", "shift", "SHIFT":
    1'u32
  of "Ctrl", "Control", "ctrl", "control", "CTRL", "CONTROL":
    4'u32
  of "Alt", "Mod1", "alt", "mod1", "ALT", "MOD1":
    8'u32
  of "Mod3", "mod3", "MOD3":
    32'u32
  of "Super", "Logo", "Mod4", "super", "logo", "mod4", "SUPER", "LOGO", "MOD4":
    64'u32
  of "Mod5", "mod5", "MOD5":
    128'u32
  of "None", "none", "NONE":
    0'u32
  else:
    0'u32

proc parseModifiers(value: string): uint32 =
  for part in value.split("+"):
    result = result or modifierValue(part.strip())

proc buttonValue(name: string): uint32 =
  case name
  of "left", "Left", "BTN_LEFT", "btn-left", "btn_left":
    0x110'u32
  of "right", "Right", "BTN_RIGHT", "btn-right", "btn_right":
    0x111'u32
  of "middle", "Middle", "BTN_MIDDLE", "btn-middle", "btn_middle":
    0x112'u32
  of "side", "Side", "BTN_SIDE", "btn-side", "btn_side":
    0x113'u32
  of "extra", "Extra", "BTN_EXTRA", "btn-extra", "btn_extra":
    0x114'u32
  of "forward", "Forward", "BTN_FORWARD", "btn-forward", "btn_forward":
    0x115'u32
  of "back", "Back", "BTN_BACK", "btn-back", "btn_back":
    0x116'u32
  of "task", "Task", "BTN_TASK", "btn-task", "btn_task":
    0x117'u32
  else:
    try:
      let parsed = parseInt(name)
      if parsed > 0:
        return uint32(parsed)
    except CatchableError:
      discard
    0'u32

proc parseKeySpec(value: string): tuple[key: string, modifiers: uint32] =
  let parts = value.split("+")
  if parts.len == 0:
    return ("", 0'u32)
  let rawKey = parts[^1].strip()
  result.key =
    case rawKey
    of "/": "Slash"
    of "?": "Question"
    else: rawKey
  if parts.len > 1:
    result.modifiers = parseModifiers(parts[0 .. ^2].join("+"))

proc applyHotkeyOverlayTitle(binding: var KeyBindingConfig, value: KdlVal) =
  if value.kind == KNull:
    binding.hotkeyOverlayTitleKind = HotkeyOverlayTitleKind.HotkeyTitleHidden
  else:
    binding.hotkeyOverlayTitleKind = HotkeyOverlayTitleKind.HotkeyTitleCustom
    binding.hotkeyOverlayTitle = value.kString()

proc childFlagEnabled(node: KdlNode): bool =
  node.args.len == 0 or node.args[0].kBool()

proc windowRuleMatcher(node: KdlNode): WindowRuleMatcher =
  if node.props.hasKey("app-id"):
    result.appIdSet = true
    result.appId = node.props["app-id"].kString()
  if node.props.hasKey("title"):
    result.titleSet = true
    result.title = node.props["title"].kString()
  if node.props.hasKey("is-active"):
    result.isActiveSet = true
    result.isActive = node.props["is-active"].kBool()
  if node.props.hasKey("is-focused"):
    result.isFocusedSet = true
    result.isFocused = node.props["is-focused"].kBool()
  if node.props.hasKey("is-active-in-column"):
    result.isActiveInColumnSet = true
    result.isActiveInColumn = node.props["is-active-in-column"].kBool()
  if node.props.hasKey("is-floating"):
    result.isFloatingSet = true
    result.isFloating = node.props["is-floating"].kBool()

proc validateWindowRuleRegex(pattern, context: string): string =
  try:
    discard re(pattern)
  except RegexError as e:
    return context & ": " & e.msg
  ""

proc validateWindowRuleMatcher(matcher: WindowRuleMatcher, context: string): string =
  if matcher.appIdSet:
    result = validateWindowRuleRegex(matcher.appId, context & " app-id")
    if result.len > 0:
      return
  if matcher.titleSet:
    result = validateWindowRuleRegex(matcher.title, context & " title")

proc validateWindowRuleRegexes(config: Config): string =
  for ruleIdx, rule in config.windowRules:
    for matcherIdx, matcher in rule.matches:
      result = validateWindowRuleMatcher(
        matcher, "window-rule[" & $ruleIdx & "].match[" & $matcherIdx & "]"
      )
      if result.len > 0:
        return
    for matcherIdx, matcher in rule.excludes:
      result = validateWindowRuleMatcher(
        matcher, "window-rule[" & $ruleIdx & "].exclude[" & $matcherIdx & "]"
      )
      if result.len > 0:
        return

proc parsePointerOp(value: string): PointerOpKind =
  case value
  of "move", "Move": PointerOpKind.OpMove
  of "resize", "Resize": PointerOpKind.OpResize
  else: PointerOpKind.OpNone

proc parseBindingMode(value: string): BindingMode =
  case value.normalize()
  of "normal": BindingMode.BindNormal
  of "overview": BindingMode.BindOverview
  else: BindingMode.BindAlways

proc mirroredArrowKey(key: string): string =
  case key.toLowerAscii()
  of "h": "Left"
  of "j": "Down"
  of "k": "Up"
  of "l": "Right"
  else: ""

proc sameKeySlot(a, b: KeyBindingConfig): bool =
  a.key.toLowerAscii() == b.key.toLowerAscii() and a.modifiers == b.modifiers and
    a.mode == b.mode

proc hasKeySlot(bindings: seq[KeyBindingConfig], candidate: KeyBindingConfig): bool =
  for binding in bindings:
    if binding.sameKeySlot(candidate):
      return true
  false

proc mirrorHjklArrowBindings(bindings: var seq[KeyBindingConfig]) =
  let source = bindings
  for binding in source:
    let arrow = binding.key.mirroredArrowKey()
    if arrow.len == 0:
      continue
    var mirrored = binding
    mirrored.key = arrow
    if not bindings.hasKeySlot(mirrored):
      bindings.add(mirrored)

proc hotkeyOverlayFallbackBinding(): KeyBindingConfig =
  KeyBindingConfig(
    key: "Slash",
    modifiers: 65'u32,
    command: "toggle-hotkey-overlay",
    bypassShortcutsInhibit: true,
    hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleCustom,
    hotkeyOverlayTitle: "Show Important Hotkeys",
  )

proc isHotkeyOverlayCommand(command: string): bool =
  let parts = command.strip().splitWhitespace()
  if parts.len == 0:
    return false
  parts[0] in ["show-hotkey-overlay", "hide-hotkey-overlay", "toggle-hotkey-overlay"]

proc hasHotkeyOverlayCommand(bindings: seq[KeyBindingConfig]): bool =
  for binding in bindings:
    if binding.command.isHotkeyOverlayCommand():
      return true
  false

proc ensureHotkeyOverlayFallback(bindings: var seq[KeyBindingConfig]) =
  let fallback = hotkeyOverlayFallbackBinding()
  if not bindings.hasHotkeyOverlayCommand() and not bindings.hasKeySlot(fallback):
    bindings.add(fallback)

proc parsePresentationMode(value: string): PresentationMode =
  case value
  of "vsync", "Vsync", "VSYNC": PresentationMode.PresentationVsync
  of "async", "Async", "ASYNC": PresentationMode.PresentationAsync
  else: PresentationMode.PresentationDefault

proc defaultKeyBindings*(): seq[KeyBindingConfig] =
  @[
    hotkeyOverlayFallbackBinding(),
    KeyBindingConfig(key: "q", modifiers: 64'u32, command: "close-window"),
    KeyBindingConfig(key: "f", modifiers: 64'u32, command: "maximize-window-to-edges"),
    KeyBindingConfig(key: "f", modifiers: 65'u32, command: "fullscreen-window"),
    KeyBindingConfig(key: "m", modifiers: 64'u32, command: "maximize-column"),
    KeyBindingConfig(key: "i", modifiers: 64'u32, command: "minimize"),
    KeyBindingConfig(
      key: "r", modifiers: 12'u32, command: "triad-reload", bypassShortcutsInhibit: true
    ),
    KeyBindingConfig(key: "t", modifiers: 64'u32, command: "spawn-terminal"),
    KeyBindingConfig(key: "Tab", modifiers: 64'u32, command: "focus-next"),
    KeyBindingConfig(key: "Left", modifiers: 8'u32, command: "focus-left"),
    KeyBindingConfig(key: "Right", modifiers: 8'u32, command: "focus-right"),
    KeyBindingConfig(key: "Up", modifiers: 8'u32, command: "focus-up"),
    KeyBindingConfig(key: "Down", modifiers: 8'u32, command: "focus-down"),
    KeyBindingConfig(key: "n", modifiers: 64'u32, command: "switch-layout"),
    KeyBindingConfig(key: "1", modifiers: 64'u32, command: "focus-workspace 1"),
    KeyBindingConfig(key: "2", modifiers: 64'u32, command: "focus-workspace 2"),
    KeyBindingConfig(key: "3", modifiers: 64'u32, command: "focus-workspace 3"),
    KeyBindingConfig(key: "4", modifiers: 64'u32, command: "focus-workspace 4"),
  ]

proc defaultPointerBindings*(): seq[PointerBindingConfig] =
  @[
    PointerBindingConfig(
      button: 0x110'u32, modifiers: 64'u32, op: PointerOpKind.OpMove, command: "move"
    ),
    PointerBindingConfig(
      button: 0x111'u32,
      modifiers: 64'u32,
      op: PointerOpKind.OpResize,
      command: "resize",
    ),
  ]

proc defaultConfigPath*(): string =
  let configHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  return configHome / "triad" / "config.kdl"

proc loadConfig*(path: string): Config =
  # Default values
  result.layout.gaps = DefaultGaps
  result.layout.centerFocusedColumn = DefaultCenterFocusedColumn
  result.layout.defaultColumnWidth = DefaultColumnWidth
  result.layout.defaultWindowWidth = DefaultWindowWidth
  result.layout.defaultWindowHeight = DefaultWindowHeight
  result.layout.defaultMasterCount = DefaultMasterCount
  result.layout.defaultMasterRatio = DefaultMasterRatio
  result.layout.borderWidth = DefaultBorderWidth
  result.layout.focusedBorderColor = DefaultFocusedBorderColor
  result.layout.unfocusedBorderColor = DefaultUnfocusedBorderColor
  result.layout.scrollerFocusCenter = false
  result.layout.scrollerPreferCenter = false
  result.layout.enableAnimations = true
  result.layout.animationSpeed = DefaultAnimationSpeed
  result.layout.smartGaps = false
  result.layout.layoutCycle =
    @[
      LayoutMode.Scroller, LayoutMode.MasterStack, LayoutMode.Grid, LayoutMode.Monocle,
      LayoutMode.VerticalScroller,
    ]
  result.workspaces.defaultCount = DefaultWorkspaceCount
  result.workspaces.defaultLayout = LayoutMode.Scroller
  result.scratchpad.widthRatio = DefaultScratchpadWidthRatio
  result.scratchpad.heightRatio = DefaultScratchpadHeightRatio
  result.overview.outerGap = DefaultOverviewOuterGap
  result.overview.innerGapMultiplier = DefaultOverviewInnerGapMultiplier
  result.overview.zoom = DefaultOverviewZoom
  result.overview.hotCorners.size = DefaultOverviewHotCornerSize
  result.floating.xRatio = DefaultFloatingXRatio
  result.floating.yRatio = DefaultFloatingYRatio
  result.floating.widthRatio = DefaultFloatingWidthRatio
  result.floating.heightRatio = DefaultFloatingHeightRatio
  result.floating.minWidth = DefaultFloatingMinWidth
  result.floating.minHeight = DefaultFloatingMinHeight
  result.quickshell.command = DefaultQuickshellCommand
  result.hotkeyOverlay.skipAtStartup = true
  result.screenshot.directory = DefaultScreenshotDirectory
  result.screenshot.filenamePrefix = DefaultScreenshotFilenamePrefix
  result.screenshot.captureCommand = DefaultScreenshotCaptureCommand
  result.screenshot.regionSelectorCommand = DefaultScreenshotRegionSelectorCommand
  result.screenshot.clipboardCommand = DefaultScreenshotClipboardCommand
  result.protocolSurfaces.enabled = true

  try:
    let doc = parseKdlFile(path)
    for node in doc:
      if node.name == "layout":
        for child in node.children:
          try:
            if child.name == "gaps" and child.args.len > 0:
              result.layout.gaps = clamp32(int32(child.args[0].kInt()), 0, 512)
            elif child.name == "center-focused-column" and child.args.len > 0:
              let mode = child.args[0].kString()
              if mode in ["never", "always", "on-overflow"]:
                result.layout.centerFocusedColumn = mode
            elif child.name == "default-column-width":
              let proportion = child.proportionChild()
              if proportion.found:
                result.layout.defaultColumnWidth = proportion.value
            elif child.name == "default-window-width":
              let proportion = child.proportionChild()
              if proportion.found:
                result.layout.defaultWindowWidth = proportion.value
            elif child.name == "default-window-height":
              let proportion = child.proportionChild()
              if proportion.found:
                result.layout.defaultWindowHeight = proportion.value
            elif child.name == "master":
              for masterChild in child.children:
                try:
                  if masterChild.name == "count" and masterChild.args.len > 0:
                    result.layout.defaultMasterCount =
                      max(1, masterChild.args[0].kInt())
                  elif masterChild.name == "split-ratio" and masterChild.args.len > 0:
                    result.layout.defaultMasterRatio =
                      clampF32(float32(masterChild.args[0].kFloat()), 0.05, 0.95)
                except CatchableError as e:
                  warn "Ignoring invalid master config field",
                    field = masterChild.name, error = e.msg
            elif child.name == "border":
              for borderChild in child.children:
                try:
                  if borderChild.name == "width" and borderChild.args.len > 0:
                    result.layout.borderWidth =
                      clamp32(int32(borderChild.args[0].kInt()), 0, 64)
                  elif borderChild.name == "active-color" and borderChild.args.len > 0:
                    result.layout.focusedBorderColor = parseColor(
                      borderChild.args[0].kString(), result.layout.focusedBorderColor
                    )
                  elif borderChild.name == "inactive-color" and borderChild.args.len > 0:
                    result.layout.unfocusedBorderColor = parseColor(
                      borderChild.args[0].kString(), result.layout.unfocusedBorderColor
                    )
                except CatchableError as e:
                  warn "Ignoring invalid border config field",
                    field = borderChild.name, error = e.msg
            elif child.name == "scroller-focus-center" and child.args.len > 0:
              result.layout.scrollerFocusCenter = child.args[0].kBool()
            elif child.name == "scroller-prefer-center" and child.args.len > 0:
              result.layout.scrollerPreferCenter = child.args[0].kBool()
            elif child.name == "enable-animations" and child.args.len > 0:
              result.layout.enableAnimations = child.args[0].kBool()
            elif child.name == "animation-speed" and child.args.len > 0:
              result.layout.animationSpeed =
                clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "smart-gaps" and child.args.len > 0:
              result.layout.smartGaps = child.args[0].kBool()
            elif child.name == "layout-cycle":
              result.layout.layoutCycle = @[]
              for arg in child.args:
                result.layout.layoutCycle.add(
                  parseLayoutName(arg.kString(), LayoutMode.Scroller)
                )
          except CatchableError as e:
            warn "Ignoring invalid layout config field",
              field = child.name, error = e.msg
      elif node.name == "workspaces":
        for child in node.children:
          try:
            if child.name == "default-count" and child.args.len > 0:
              let count = child.args[0].kInt()
              result.workspaces.defaultCount = normalizeWorkspaceCountFromConfig(count)
            elif child.name == "default-layout" and child.args.len > 0:
              result.workspaces.defaultLayout = parseLayoutName(
                child.args[0].kString(), result.workspaces.defaultLayout
              )
          except CatchableError as e:
            warn "Ignoring invalid workspace config field",
              field = child.name, error = e.msg
      elif node.name == "workspace-rules":
        for child in node.children:
          if child.name == "workspace" and child.args.len > 0:
            try:
              let rawId = child.args[0].kInt()
              if rawId <= 0:
                continue
              let id = uint32(rawId)
              var layout = result.workspaces.defaultLayout
              var layoutSet = false
              var tagName = ""
              if child.props.hasKey("name"):
                tagName = child.props["name"].kString()
              if child.props.hasKey("default-layout"):
                layoutSet = true
                layout =
                  parseLayoutName(child.props["default-layout"].kString(), layout)
              result.tagRules.add(
                TagRule(
                  tagId: id,
                  defaultLayoutSet: layoutSet,
                  defaultLayout: layout,
                  name: tagName,
                )
              )
            except CatchableError as e:
              warn "Ignoring invalid workspace rule", error = e.msg
      elif node.name == "window-rule":
        var rule = WindowRule()
        for child in node.children:
          try:
            if child.name == "match":
              rule.matches.add(child.windowRuleMatcher())
            elif child.name == "exclude":
              rule.excludes.add(child.windowRuleMatcher())
            elif child.name == "default-workspace" and child.args.len > 0:
              let rawWorkspace = child.args[0].kInt()
              if rawWorkspace > 0:
                rule.defaultWorkspace = uint32(rawWorkspace)
            elif child.name == "open-on-output" and child.args.len > 0:
              rule.openOnOutput = child.args[0].kString().strip()
            elif child.name == "default-column-width":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.defaultColumnWidthSet = true
                rule.defaultColumnWidth = proportion.value
            elif child.name == "default-window-width":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.defaultWindowWidthSet = true
                rule.defaultWindowWidth = proportion.value
            elif child.name == "default-window-height":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.defaultWindowHeightSet = true
                rule.defaultWindowHeight = proportion.value
            elif child.name == "min-width" and child.args.len > 0:
              rule.minWidthSet = true
              rule.minWidth = clamp32(int32(child.args[0].kInt()), 0, 65535)
            elif child.name == "min-height" and child.args.len > 0:
              rule.minHeightSet = true
              rule.minHeight = clamp32(int32(child.args[0].kInt()), 0, 65535)
            elif child.name == "max-width" and child.args.len > 0:
              rule.maxWidthSet = true
              rule.maxWidth = clamp32(int32(child.args[0].kInt()), 0, 65535)
            elif child.name == "max-height" and child.args.len > 0:
              rule.maxHeightSet = true
              rule.maxHeight = clamp32(int32(child.args[0].kInt()), 0, 65535)
            elif child.name == "open-floating" and child.args.len > 0:
              rule.openFloatingSet = true
              rule.openFloating = child.args[0].kBool()
            elif child.name == "open-focused" and child.args.len > 0:
              rule.openFocusedSet = true
              rule.openFocused = child.args[0].kBool()
            elif child.name == "open-fullscreen" and child.args.len > 0:
              rule.openFullscreenSet = true
              rule.openFullscreen = child.args[0].kBool()
            elif child.name == "open-maximized" and child.args.len > 0:
              rule.openMaximizedSet = true
              rule.openMaximized = child.args[0].kBool()
            elif child.name == "open-maximized-to-edges" and child.args.len > 0:
              rule.openMaximizedToEdgesSet = true
              rule.openMaximizedToEdges = child.args[0].kBool()
            elif child.name == "parented-role" and child.args.len > 0:
              rule.parentedRoleSet = true
              rule.parentedRole = parseParentedRole(child.args[0].kString())
            elif child.name == "dialog-viewport-jump" and child.args.len > 0:
              rule.dialogViewportJumpSet = true
              rule.dialogViewportJump = child.args[0].kBool()
            elif child.name == "keyboard-shortcuts-inhibit" and child.args.len > 0:
              rule.keyboardShortcutsInhibitSet = true
              rule.keyboardShortcutsInhibit = child.args[0].kBool()
            elif child.name == "tiled-state" and child.args.len > 0:
              rule.tiledStateSet = true
              rule.tiledState = child.args[0].kBool()
            elif child.name == "forced-layout" and child.args.len > 0:
              rule.forcedLayoutSet = true
              rule.forcedLayout = forcedLayoutValue(child.args[0].kString())
            elif child.name == "floating":
              for floatingChild in child.children:
                if floatingChild.name == "x-ratio" and floatingChild.args.len > 0:
                  rule.floating.xRatioSet = true
                  rule.floating.xRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.0, 1.0)
                elif floatingChild.name == "y-ratio" and floatingChild.args.len > 0:
                  rule.floating.yRatioSet = true
                  rule.floating.yRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.0, 1.0)
                elif floatingChild.name == "width-ratio" and floatingChild.args.len > 0:
                  rule.floating.widthRatioSet = true
                  rule.floating.widthRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.05, 1.0)
                elif floatingChild.name == "height-ratio" and floatingChild.args.len > 0:
                  rule.floating.heightRatioSet = true
                  rule.floating.heightRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.05, 1.0)
          except CatchableError as e:
            warn "Ignoring invalid window rule field", field = child.name, error = e.msg
        result.windowRules.add(rule)
      elif node.name == "spawn-at-startup":
        var cmd: seq[string] = @[]
        try:
          for arg in node.args:
            cmd.add(arg.kString())
        except CatchableError as e:
          warn "Ignoring invalid startup command", error = e.msg
        if cmd.len > 0:
          result.startupCommands.add(cmd)
      elif node.name == "window-menu-command":
        var cmd: seq[string] = @[]
        try:
          for arg in node.args:
            cmd.add(arg.kString())
        except CatchableError as e:
          warn "Ignoring invalid window menu command", error = e.msg
        if cmd.len > 0:
          result.windowMenu.command = cmd
      elif node.name == "bindings":
        for child in node.children:
          try:
            if child.name == "mirror-hjkl-arrows" and child.args.len > 0:
              result.mirrorHjklArrows = child.args[0].kBool()
            elif child.name == "bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              if spec.key.len > 0:
                var binding = KeyBindingConfig(
                  key: spec.key,
                  modifiers: spec.modifiers,
                  command: child.args[1].kString(),
                  mode: BindingMode.BindAlways,
                )
                if child.props.hasKey("layout"):
                  let layout = child.props["layout"].kInt()
                  if layout >= 0:
                    binding.hasLayoutOverride = true
                    binding.layoutOverride = uint32(layout)
                if child.props.hasKey("mode"):
                  binding.mode = parseBindingMode(child.props["mode"].kString())
                if child.props.hasKey("allow-inhibiting"):
                  binding.bypassShortcutsInhibit =
                    not child.props["allow-inhibiting"].kBool()
                if child.props.hasKey("hotkey-overlay-title"):
                  binding.applyHotkeyOverlayTitle(child.props["hotkey-overlay-title"])
                result.keyBindings.add(binding)
            elif child.name == "pointer-bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              let button = buttonValue(spec.key)
              let command = child.args[1].kString()
              if button != 0 and command.len > 0:
                var binding = PointerBindingConfig(
                  button: button,
                  modifiers: spec.modifiers,
                  op: parsePointerOp(command),
                  command: command,
                  mode: BindingMode.BindAlways,
                )
                if child.props.hasKey("mode"):
                  binding.mode = parseBindingMode(child.props["mode"].kString())
                if child.props.hasKey("allow-inhibiting"):
                  binding.bypassShortcutsInhibit =
                    not child.props["allow-inhibiting"].kBool()
                result.pointerBindings.add(binding)
          except CatchableError as e:
            warn "Ignoring invalid binding config field",
              field = child.name, error = e.msg
        if result.mirrorHjklArrows:
          result.keyBindings.mirrorHjklArrowBindings()
      elif node.name == "quickshell":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.quickshell.enabled = child.args[0].kBool()
            elif child.name == "command" and child.args.len > 0:
              result.quickshell.command = child.args[0].kString()
            elif child.name == "theme" and child.args.len > 0:
              result.quickshell.theme = child.args[0].kString()
            elif child.name == "args":
              for arg in child.args:
                result.quickshell.args.add(arg.kString())
          except CatchableError as e:
            warn "Ignoring invalid quickshell field", field = child.name, error = e.msg
      elif node.name == "terminal":
        for child in node.children:
          try:
            if child.name == "command":
              result.terminal.command = @[]
              for arg in child.args:
                result.terminal.command.add(arg.kString())
          except CatchableError as e:
            warn "Ignoring invalid terminal field", field = child.name, error = e.msg
      elif node.name == "screen-lock":
        for child in node.children:
          try:
            if child.name == "command":
              var cmd: seq[string] = @[]
              for arg in child.args:
                cmd.add(arg.kString())
              if cmd.len > 0:
                result.screenLock.command = cmd
          except CatchableError as e:
            warn "Ignoring invalid screen-lock field", field = child.name, error = e.msg
      elif node.name == "scratchpad":
        for child in node.children:
          try:
            if child.name == "width-ratio" and child.args.len > 0:
              result.scratchpad.widthRatio =
                clampF32(float32(child.args[0].kFloat()), 0.1, 1.0)
            elif child.name == "height-ratio" and child.args.len > 0:
              result.scratchpad.heightRatio =
                clampF32(float32(child.args[0].kFloat()), 0.1, 1.0)
          except CatchableError as e:
            warn "Ignoring invalid scratchpad field", field = child.name, error = e.msg
      elif node.name == "overview":
        for child in node.children:
          try:
            if child.name == "outer-gap" and child.args.len > 0:
              result.overview.outerGap = clamp32(int32(child.args[0].kInt()), 0, 512)
            elif child.name == "inner-gap-multiplier" and child.args.len > 0:
              result.overview.innerGapMultiplier =
                clampF32(float32(child.args[0].kFloat()), 0.0, 8.0)
            elif child.name == "zoom" and child.args.len > 0:
              result.overview.zoom =
                clampF32(float32(child.args[0].kFloat()), 0.0001, 0.75)
            elif child.name == "hot-corners":
              for cornerChild in child.children:
                try:
                  if cornerChild.name == "size" and cornerChild.args.len > 0:
                    result.overview.hotCorners.size =
                      clamp32(int32(cornerChild.args[0].kInt()), 1, 1000)
                  elif cornerChild.name == "top-left":
                    result.overview.hotCorners.topLeft = cornerChild.childFlagEnabled()
                  elif cornerChild.name == "top-right":
                    result.overview.hotCorners.topRight = cornerChild.childFlagEnabled()
                  elif cornerChild.name == "bottom-left":
                    result.overview.hotCorners.bottomLeft =
                      cornerChild.childFlagEnabled()
                  elif cornerChild.name == "bottom-right":
                    result.overview.hotCorners.bottomRight =
                      cornerChild.childFlagEnabled()
                except CatchableError as e:
                  warn "Ignoring invalid overview hot-corners field",
                    field = cornerChild.name, error = e.msg
          except CatchableError as e:
            warn "Ignoring invalid overview field", field = child.name, error = e.msg
      elif node.name == "floating":
        for child in node.children:
          try:
            if child.name == "x-ratio" and child.args.len > 0:
              result.floating.xRatio =
                clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "y-ratio" and child.args.len > 0:
              result.floating.yRatio =
                clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "width-ratio" and child.args.len > 0:
              result.floating.widthRatio =
                clampF32(float32(child.args[0].kFloat()), 0.05, 1.0)
            elif child.name == "height-ratio" and child.args.len > 0:
              result.floating.heightRatio =
                clampF32(float32(child.args[0].kFloat()), 0.05, 1.0)
            elif child.name == "min-width" and child.args.len > 0:
              result.floating.minWidth = clamp32(int32(child.args[0].kInt()), 1, 4096)
            elif child.name == "min-height" and child.args.len > 0:
              result.floating.minHeight = clamp32(int32(child.args[0].kInt()), 1, 4096)
          except CatchableError as e:
            warn "Ignoring invalid floating field", field = child.name, error = e.msg
      elif node.name == "screenshot":
        for child in node.children:
          try:
            if child.name == "directory" and child.args.len > 0:
              result.screenshot.directory = child.args[0].kString()
            elif child.name == "filename-prefix" and child.args.len > 0:
              result.screenshot.filenamePrefix = child.args[0].kString()
            elif child.name == "capture-command" and child.args.len > 0:
              result.screenshot.captureCommand = child.args[0].kString()
            elif child.name == "region-selector-command" and child.args.len > 0:
              result.screenshot.regionSelectorCommand = child.args[0].kString()
            elif child.name == "clipboard-command" and child.args.len > 0:
              result.screenshot.clipboardCommand = child.args[0].kString()
            elif child.name == "show-pointer" and child.args.len > 0:
              result.screenshot.showPointer = child.args[0].kBool()
          except CatchableError as e:
            warn "Ignoring invalid screenshot field", field = child.name, error = e.msg
      elif node.name == "cursor":
        for child in node.children:
          try:
            if child.name == "theme" and child.args.len > 0:
              result.cursor.theme = child.args[0].kString()
            elif child.name == "size" and child.args.len > 0:
              let size = child.args[0].kInt()
              if size > 0:
                result.cursor.size = uint32(min(size, 512))
            elif child.name == "shake-to-find":
              result.cursor.shakeToFind = child.childFlagEnabled()
          except CatchableError as e:
            warn "Ignoring invalid cursor field", field = child.name, error = e.msg
      elif node.name == "hotkey-overlay":
        for child in node.children:
          try:
            if child.name == "skip-at-startup":
              result.hotkeyOverlay.skipAtStartup =
                child.args.len == 0 or child.args[0].kBool()
            elif child.name == "hide-not-bound":
              result.hotkeyOverlay.hideNotBound =
                child.args.len == 0 or child.args[0].kBool()
          except CatchableError as e:
            warn "Ignoring invalid hotkey-overlay field",
              field = child.name, error = e.msg
      elif node.name == "presentation-mode" and node.args.len > 0:
        try:
          result.presentationMode = parsePresentationMode(node.args[0].kString())
        except CatchableError as e:
          warn "Ignoring invalid presentation mode", error = e.msg
      elif node.name == "allow-exit-session" and node.args.len > 0:
        try:
          result.allowExitSession = node.args[0].kBool()
        except CatchableError as e:
          warn "Ignoring invalid allow-exit-session value", error = e.msg
      elif node.name == "protocol-surfaces":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.protocolSurfaces.enabled = child.args[0].kBool()
            elif child.name == "visible-debug" and child.args.len > 0:
              result.protocolSurfaces.visibleDebug = child.args[0].kBool()
          except CatchableError as e:
            warn "Ignoring invalid protocol-surfaces field",
              field = child.name, error = e.msg
  except:
    let e = getCurrentException()
    warn "Could not load config, using defaults", path = path, error = e.msg

  if result.keyBindings.len == 0:
    result.keyBindings = defaultKeyBindings()
  else:
    result.keyBindings.ensureHotkeyOverlayFallback()
  if result.pointerBindings.len == 0:
    result.pointerBindings = defaultPointerBindings()

proc loadConfigStrict*(path: string): ConfigLoadResult =
  try:
    discard parseKdlFile(path)
  except CatchableError as e:
    return ConfigLoadResult(ok: false, error: e.msg)

  let config = loadConfig(path)
  let regexError = config.validateWindowRuleRegexes()
  if regexError.len > 0:
    return ConfigLoadResult(ok: false, error: regexError)

  result = ConfigLoadResult(ok: true, config: config)
