import kdl, tables, ../core/model, ../core/model_utils, os, chronicles, strutils
import defaults

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
    presentationMode*: PresentationMode
    allowExitSession*: bool
    protocolSurfaces*: ProtocolSurfacesConfig
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

proc clamp32(value, lo, hi: int32): int32 =
  min(hi, max(lo, value))

proc clampF32(value, lo, hi: float32): float32 =
  min(hi, max(lo, value))

proc normalizeWorkspaceCountFromConfig(count: int): uint32 =
  if count <= 0:
    DefaultWorkspaceCount
  else:
    normalizeWorkspaceCount(uint32(count))

proc parseColor(value: string; fallback: uint32): uint32 =
  var hex = value.strip()
  if hex.startsWith("#"):
    hex = hex[1..^1]
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
  of "scroller": Scroller
  of "vertical-scroller": VerticalScroller
  of "tile": MasterStack
  of "grid": Grid
  of "monocle": Monocle
  of "deck": Deck
  of "center-tile", "center_tile": CenterTile
  of "right-tile", "right_tile": RightTile
  of "vertical-tile", "vertical_tile": VerticalTile
  of "vertical-grid", "vertical_grid": VerticalGrid
  of "vertical-deck", "vertical_deck": VerticalDeck
  else: fallback

proc forcedLayoutValue(name: string): int =
  case name
  of "scroller": ord(Scroller) + 1
  of "vertical-scroller": ord(VerticalScroller) + 1
  of "tile": ord(MasterStack) + 1
  of "grid": ord(Grid) + 1
  of "monocle": ord(Monocle) + 1
  of "deck": ord(Deck) + 1
  of "center-tile", "center_tile": ord(CenterTile) + 1
  of "right-tile", "right_tile": ord(RightTile) + 1
  of "vertical-tile", "vertical_tile": ord(VerticalTile) + 1
  of "vertical-grid", "vertical_grid": ord(VerticalGrid) + 1
  of "vertical-deck", "vertical_deck": ord(VerticalDeck) + 1
  else: 0

proc modifierValue(name: string): uint32 =
  case name
  of "Shift", "shift": 1'u32
  of "Ctrl", "Control", "ctrl", "control": 4'u32
  of "Alt", "Mod1", "alt", "mod1": 8'u32
  of "Mod3", "mod3": 32'u32
  of "Super", "Logo", "Mod4", "super", "logo", "mod4": 64'u32
  of "Mod5", "mod5": 128'u32
  else: 0'u32

proc parseModifiers(value: string): uint32 =
  for part in value.split("+"):
    result = result or modifierValue(part.strip())

proc buttonValue(name: string): uint32 =
  case name
  of "left", "Left", "BTN_LEFT", "btn-left": 0x110'u32
  of "right", "Right", "BTN_RIGHT", "btn-right": 0x111'u32
  of "middle", "Middle", "BTN_MIDDLE", "btn-middle": 0x112'u32
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
  result.key = parts[^1].strip()
  if parts.len > 1:
    result.modifiers = parseModifiers(parts[0 .. ^2].join("+"))

proc parsePointerOp(value: string): PointerOpKind =
  case value
  of "move", "Move": OpMove
  of "resize", "Resize": OpResize
  else: OpNone

proc parseBindingMode(value: string): BindingMode =
  case value.normalize()
  of "normal": BindNormal
  of "overview": BindOverview
  else: BindAlways

proc parsePresentationMode(value: string): PresentationMode =
  case value
  of "vsync", "Vsync", "VSYNC": PresentationVsync
  of "async", "Async", "ASYNC": PresentationAsync
  else: PresentationDefault

proc defaultKeyBindings*(): seq[KeyBindingConfig] =
  @[
    KeyBindingConfig(key: "q", modifiers: 64'u32, command: "close-window"),
    KeyBindingConfig(key: "f", modifiers: 64'u32, command: "toggle-fullscreen"),
    KeyBindingConfig(key: "m", modifiers: 64'u32, command: "toggle-maximized"),
    KeyBindingConfig(key: "i", modifiers: 64'u32, command: "minimize"),
    KeyBindingConfig(key: "r", modifiers: 64'u32, command: "reload-config"),
    KeyBindingConfig(key: "t", modifiers: 64'u32, command: "spawn-terminal"),
    KeyBindingConfig(key: "Tab", modifiers: 64'u32, command: "focus-next"),
    KeyBindingConfig(key: "Left", modifiers: 8'u32, command: "focus-left"),
    KeyBindingConfig(key: "Right", modifiers: 8'u32, command: "focus-right"),
    KeyBindingConfig(key: "Up", modifiers: 8'u32, command: "focus-up"),
    KeyBindingConfig(key: "Down", modifiers: 8'u32, command: "focus-down"),
    KeyBindingConfig(key: "n", modifiers: 64'u32, command: "switch-layout"),
    KeyBindingConfig(key: "1", modifiers: 64'u32, command: "focus-tag 1"),
    KeyBindingConfig(key: "2", modifiers: 64'u32, command: "focus-tag 2"),
    KeyBindingConfig(key: "3", modifiers: 64'u32, command: "focus-tag 3"),
    KeyBindingConfig(key: "4", modifiers: 64'u32, command: "focus-tag 4")
  ]

proc defaultPointerBindings*(): seq[PointerBindingConfig] =
  @[
    PointerBindingConfig(button: 0x110'u32, modifiers: 64'u32, op: OpMove),
    PointerBindingConfig(button: 0x111'u32, modifiers: 64'u32, op: OpResize)
  ]

proc getConfigPath*(): string =
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
  result.layout.layoutCycle = @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]
  result.workspaces.defaultCount = DefaultWorkspaceCount
  result.scratchpad.widthRatio = DefaultScratchpadWidthRatio
  result.scratchpad.heightRatio = DefaultScratchpadHeightRatio
  result.overview.outerGap = DefaultOverviewOuterGap
  result.overview.innerGapMultiplier = DefaultOverviewInnerGapMultiplier
  result.floating.xRatio = DefaultFloatingXRatio
  result.floating.yRatio = DefaultFloatingYRatio
  result.floating.widthRatio = DefaultFloatingWidthRatio
  result.floating.heightRatio = DefaultFloatingHeightRatio
  result.floating.minWidth = DefaultFloatingMinWidth
  result.floating.minHeight = DefaultFloatingMinHeight
  result.quickshell.command = DefaultQuickshellCommand
  result.screenshot.directory = DefaultScreenshotDirectory
  result.screenshot.filenamePrefix = DefaultScreenshotFilenamePrefix
  result.screenshot.captureCommand = DefaultScreenshotCaptureCommand
  result.screenshot.regionSelectorCommand = DefaultScreenshotRegionSelectorCommand
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
              if child.children.len > 0 and child.children[0].name == "proportion" and child.children[0].args.len > 0:
                result.layout.defaultColumnWidth = clampF32(float32(child.children[0].args[0].kFloat()), 0.05, 1.0)
            elif child.name == "default-window-width":
              if child.children.len > 0 and child.children[0].name == "proportion" and child.children[0].args.len > 0:
                result.layout.defaultWindowWidth = clampF32(float32(child.children[0].args[0].kFloat()), 0.05, 1.0)
            elif child.name == "default-window-height":
              if child.children.len > 0 and child.children[0].name == "proportion" and child.children[0].args.len > 0:
                result.layout.defaultWindowHeight = clampF32(float32(child.children[0].args[0].kFloat()), 0.05, 1.0)
            elif child.name == "master":
              for masterChild in child.children:
                try:
                  if masterChild.name == "count" and masterChild.args.len > 0:
                    result.layout.defaultMasterCount = max(1, masterChild.args[0].kInt())
                  elif masterChild.name == "split-ratio" and masterChild.args.len > 0:
                    result.layout.defaultMasterRatio = clampF32(float32(masterChild.args[0].kFloat()), 0.05, 0.95)
                except CatchableError as e:
                  warn "Ignoring invalid master config field", field=masterChild.name, error=e.msg
            elif child.name == "border":
              for borderChild in child.children:
                try:
                  if borderChild.name == "width" and borderChild.args.len > 0:
                    result.layout.borderWidth = clamp32(int32(borderChild.args[0].kInt()), 0, 64)
                  elif borderChild.name == "active-color" and borderChild.args.len > 0:
                    result.layout.focusedBorderColor = parseColor(borderChild.args[0].kString(), result.layout.focusedBorderColor)
                  elif borderChild.name == "inactive-color" and borderChild.args.len > 0:
                    result.layout.unfocusedBorderColor = parseColor(borderChild.args[0].kString(), result.layout.unfocusedBorderColor)
                except CatchableError as e:
                  warn "Ignoring invalid border config field", field=borderChild.name, error=e.msg
            elif child.name == "scroller-focus-center" and child.args.len > 0:
              result.layout.scrollerFocusCenter = child.args[0].kBool()
            elif child.name == "scroller-prefer-center" and child.args.len > 0:
              result.layout.scrollerPreferCenter = child.args[0].kBool()
            elif child.name == "enable-animations" and child.args.len > 0:
              result.layout.enableAnimations = child.args[0].kBool()
            elif child.name == "animation-speed" and child.args.len > 0:
              result.layout.animationSpeed = clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "smart-gaps" and child.args.len > 0:
              result.layout.smartGaps = child.args[0].kBool()
            elif child.name == "layout-cycle":
              result.layout.layoutCycle = @[]
              for arg in child.args:
                result.layout.layoutCycle.add(parseLayoutName(arg.kString(), Scroller))
          except CatchableError as e:
            warn "Ignoring invalid layout config field", field=child.name, error=e.msg
      
      elif node.name == "workspaces":
        for child in node.children:
          try:
            if child.name == "default-count" and child.args.len > 0:
              let count = child.args[0].kInt()
              result.workspaces.defaultCount = normalizeWorkspaceCountFromConfig(count)
          except CatchableError as e:
            warn "Ignoring invalid workspace config field", field=child.name, error=e.msg

      elif node.name == "tag-rules":
        for child in node.children:
          if child.name == "tag" and child.args.len > 0:
            try:
              let rawId = child.args[0].kInt()
              if rawId <= 0: continue
              let id = uint32(rawId)
              var layout = Scroller
              var tagName = ""
              if child.props.hasKey("name"):
                tagName = child.props["name"].kString()
              if child.props.hasKey("default-layout"):
                layout = parseLayoutName(child.props["default-layout"].kString(), layout)
              result.tagRules.add(TagRule(tagId: id, defaultLayout: layout, name: tagName))
            except CatchableError as e:
              warn "Ignoring invalid tag rule", error=e.msg
            
      elif node.name == "window-rule":
        var rule = WindowRule()
        for child in node.children:
          try:
            if child.name == "match":
              if child.props.hasKey("app-id"):
                rule.appIdMatch = child.props["app-id"].kString()
              if child.props.hasKey("title"):
                rule.titleMatch = child.props["title"].kString()
            elif child.name == "default-tag" and child.args.len > 0:
              let rawTag = child.args[0].kInt()
              if rawTag > 0: rule.defaultTag = uint32(rawTag)
            elif child.name == "open-floating" and child.args.len > 0:
              rule.openFloating = child.args[0].kBool()
            elif child.name == "forced-layout" and child.args.len > 0:
              rule.forcedLayout = forcedLayoutValue(child.args[0].kString())
          except CatchableError as e:
            warn "Ignoring invalid window rule field", field=child.name, error=e.msg
        result.windowRules.add(rule)

      elif node.name == "spawn-at-startup":
        var cmd: seq[string] = @[]
        try:
          for arg in node.args:
            cmd.add(arg.kString())
        except CatchableError as e:
          warn "Ignoring invalid startup command", error=e.msg
        if cmd.len > 0:
          result.startupCommands.add(cmd)

      elif node.name == "window-menu-command":
        var cmd: seq[string] = @[]
        try:
          for arg in node.args:
            cmd.add(arg.kString())
        except CatchableError as e:
          warn "Ignoring invalid window menu command", error=e.msg
        if cmd.len > 0:
          result.windowMenu.command = cmd

      elif node.name == "bindings":
        for child in node.children:
          try:
            if child.name == "bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              if spec.key.len > 0:
                var binding = KeyBindingConfig(
                  key: spec.key,
                  modifiers: spec.modifiers,
                  command: child.args[1].kString(),
                  mode: BindAlways)
                if child.props.hasKey("layout"):
                  let layout = child.props["layout"].kInt()
                  if layout >= 0:
                    binding.hasLayoutOverride = true
                    binding.layoutOverride = uint32(layout)
                if child.props.hasKey("mode"):
                  binding.mode = parseBindingMode(child.props["mode"].kString())
                result.keyBindings.add(binding)
            elif child.name == "pointer-bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              let button = buttonValue(spec.key)
              let op = parsePointerOp(child.args[1].kString())
              if button != 0 and op != OpNone:
                result.pointerBindings.add(PointerBindingConfig(
                  button: button,
                  modifiers: spec.modifiers,
                  op: op))
          except CatchableError as e:
            warn "Ignoring invalid binding config field", field=child.name, error=e.msg

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
            warn "Ignoring invalid quickshell field", field=child.name, error=e.msg

      elif node.name == "terminal":
        for child in node.children:
          try:
            if child.name == "command":
              result.terminal.command = @[]
              for arg in child.args:
                result.terminal.command.add(arg.kString())
          except CatchableError as e:
            warn "Ignoring invalid terminal field", field=child.name, error=e.msg

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
            warn "Ignoring invalid screen-lock field", field=child.name, error=e.msg

      elif node.name == "scratchpad":
        for child in node.children:
          try:
            if child.name == "width-ratio" and child.args.len > 0:
              result.scratchpad.widthRatio = clampF32(float32(child.args[0].kFloat()), 0.1, 1.0)
            elif child.name == "height-ratio" and child.args.len > 0:
              result.scratchpad.heightRatio = clampF32(float32(child.args[0].kFloat()), 0.1, 1.0)
          except CatchableError as e:
            warn "Ignoring invalid scratchpad field", field=child.name, error=e.msg

      elif node.name == "overview":
        for child in node.children:
          try:
            if child.name == "outer-gap" and child.args.len > 0:
              result.overview.outerGap = clamp32(int32(child.args[0].kInt()), 0, 512)
            elif child.name == "inner-gap-multiplier" and child.args.len > 0:
              result.overview.innerGapMultiplier = clampF32(float32(child.args[0].kFloat()), 0.0, 8.0)
          except CatchableError as e:
            warn "Ignoring invalid overview field", field=child.name, error=e.msg

      elif node.name == "floating":
        for child in node.children:
          try:
            if child.name == "x-ratio" and child.args.len > 0:
              result.floating.xRatio = clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "y-ratio" and child.args.len > 0:
              result.floating.yRatio = clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "width-ratio" and child.args.len > 0:
              result.floating.widthRatio = clampF32(float32(child.args[0].kFloat()), 0.05, 1.0)
            elif child.name == "height-ratio" and child.args.len > 0:
              result.floating.heightRatio = clampF32(float32(child.args[0].kFloat()), 0.05, 1.0)
            elif child.name == "min-width" and child.args.len > 0:
              result.floating.minWidth = clamp32(int32(child.args[0].kInt()), 1, 4096)
            elif child.name == "min-height" and child.args.len > 0:
              result.floating.minHeight = clamp32(int32(child.args[0].kInt()), 1, 4096)
          except CatchableError as e:
            warn "Ignoring invalid floating field", field=child.name, error=e.msg

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
            elif child.name == "show-pointer" and child.args.len > 0:
              result.screenshot.showPointer = child.args[0].kBool()
          except CatchableError as e:
            warn "Ignoring invalid screenshot field", field=child.name, error=e.msg

      elif node.name == "cursor":
        for child in node.children:
          try:
            if child.name == "theme" and child.args.len > 0:
              result.cursor.theme = child.args[0].kString()
            elif child.name == "size" and child.args.len > 0:
              let size = child.args[0].kInt()
              if size > 0:
                result.cursor.size = uint32(min(size, 512))
          except CatchableError as e:
            warn "Ignoring invalid cursor field", field=child.name, error=e.msg

      elif node.name == "presentation-mode" and node.args.len > 0:
        try:
          result.presentationMode = parsePresentationMode(node.args[0].kString())
        except CatchableError as e:
          warn "Ignoring invalid presentation mode", error=e.msg

      elif node.name == "allow-exit-session" and node.args.len > 0:
        try:
          result.allowExitSession = node.args[0].kBool()
        except CatchableError as e:
          warn "Ignoring invalid allow-exit-session value", error=e.msg

      elif node.name == "protocol-surfaces":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.protocolSurfaces.enabled = child.args[0].kBool()
            elif child.name == "visible-debug" and child.args.len > 0:
              result.protocolSurfaces.visibleDebug = child.args[0].kBool()
          except CatchableError as e:
            warn "Ignoring invalid protocol-surfaces field", field=child.name, error=e.msg
            
  except:
    let e = getCurrentException()
    warn "Could not load config, using defaults", path=path, error=e.msg

  if result.keyBindings.len == 0:
    result.keyBindings = defaultKeyBindings()
  if result.pointerBindings.len == 0:
    result.pointerBindings = defaultPointerBindings()

proc applyConfig*(model: var Model, config: Config) =
  model.outerGaps = clamp32(config.layout.gaps, 0, 512)
  model.borderWidth = clamp32(config.layout.borderWidth, 0, 64)
  model.focusedBorderColor = config.layout.focusedBorderColor
  model.unfocusedBorderColor = config.layout.unfocusedBorderColor
  model.scrollerFocusCenter = config.layout.scrollerFocusCenter
  model.scrollerPreferCenter = config.layout.scrollerPreferCenter
  model.innerGaps = model.outerGaps div 2
  model.centerFocusedColumn = if config.layout.centerFocusedColumn in ["never", "always", "on-overflow"]: config.layout.centerFocusedColumn else: "never"
  model.defaultColumnWidth = clampF32(config.layout.defaultColumnWidth, 0.05, 1.0)
  model.defaultWindowWidth = clampF32(config.layout.defaultWindowWidth, 0.05, 1.0)
  model.defaultWindowHeight = clampF32(config.layout.defaultWindowHeight, 0.05, 1.0)
  model.defaultMasterCount = max(1, config.layout.defaultMasterCount)
  model.defaultMasterRatio = clampF32(config.layout.defaultMasterRatio, 0.05, 0.95)
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed = clampF32(config.layout.animationSpeed, 0.0, 1.0)
  model.smartGaps = config.layout.smartGaps
  model.workspaces = config.workspaces
  model.workspaces.defaultCount = normalizeWorkspaceCount(model.workspaces.defaultCount)
  model.tagRules = config.tagRules
  model.windowRules = config.windowRules
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
  model.layoutCycle = if config.layout.layoutCycle.len > 0: config.layout.layoutCycle else: @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]
  model.scratchpadWidthRatio = clampF32(config.scratchpad.widthRatio, 0.1, 1.0)
  model.scratchpadHeightRatio = clampF32(config.scratchpad.heightRatio, 0.1, 1.0)
  
  model.ensureDefaultWorkspaces()

  for rule in config.tagRules:
    if model.tags.hasKey(rule.tagId):
      model.tags[rule.tagId].layoutMode = rule.defaultLayout
      model.tags[rule.tagId].name = rule.name
  discard model.pruneDynamicWorkspaces()
