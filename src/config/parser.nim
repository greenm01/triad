import kdl, tables, ../core/model, os, chronicles

type
  Config* = object
    layout*: LayoutConfig
    tagRules*: seq[TagRule]
    windowRules*: seq[WindowRule]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig

  LayoutConfig* = object
    gaps*: int32
    centerFocusedColumn*: string # "never", "always", "on-overflow"
    defaultColumnWidth*: float32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    enableAnimations*: bool
    animationSpeed*: float32
    smartGaps*: bool

  TagRule* = object
    tagId*: uint32
    name*: string
    defaultLayout*: LayoutMode

proc clamp32(value, lo, hi: int32): int32 =
  min(hi, max(lo, value))

proc clampF32(value, lo, hi: float32): float32 =
  min(hi, max(lo, value))

proc parseLayoutName(name: string, fallback: LayoutMode): LayoutMode =
  case name
  of "scroller": Scroller
  of "vertical-scroller": VerticalScroller
  of "tile": MasterStack
  of "grid": Grid
  of "monocle": Monocle
  else: fallback

proc forcedLayoutValue(name: string): int =
  case name
  of "scroller": ord(Scroller) + 1
  of "vertical-scroller": ord(VerticalScroller) + 1
  of "tile": ord(MasterStack) + 1
  of "grid": ord(Grid) + 1
  of "monocle": ord(Monocle) + 1
  else: 0

proc getConfigPath*(): string =
  let configHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  return configHome / "triad" / "config.kdl"

proc loadConfig*(path: string): Config =
  # Default values
  result.layout.gaps = 16
  result.layout.centerFocusedColumn = "never"
  result.layout.defaultColumnWidth = 0.5
  result.layout.scrollerFocusCenter = false
  result.layout.scrollerPreferCenter = false
  result.layout.enableAnimations = true
  result.layout.animationSpeed = 0.15
  result.layout.smartGaps = false
  
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
          except CatchableError as e:
            warn "Ignoring invalid layout config field", field=child.name, error=e.msg
      
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

      elif node.name == "quickshell":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.quickshell.enabled = child.args[0].kBool()
            elif child.name == "theme" and child.args.len > 0:
              result.quickshell.theme = child.args[0].kString()
            elif child.name == "args":
              for arg in child.args:
                result.quickshell.args.add(arg.kString())
          except CatchableError as e:
            warn "Ignoring invalid quickshell field", field=child.name, error=e.msg
            
  except:
    let e = getCurrentException()
    warn "Could not load config, using defaults", path=path, error=e.msg

proc applyConfig*(model: var Model, config: Config) =
  model.outerGaps = clamp32(config.layout.gaps, 0, 512)
  model.scrollerFocusCenter = config.layout.scrollerFocusCenter
  model.scrollerPreferCenter = config.layout.scrollerPreferCenter
  model.innerGaps = model.outerGaps div 2
  model.centerFocusedColumn = if config.layout.centerFocusedColumn in ["never", "always", "on-overflow"]: config.layout.centerFocusedColumn else: "never"
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed = clampF32(config.layout.animationSpeed, 0.0, 1.0)
  model.smartGaps = config.layout.smartGaps
  model.windowRules = config.windowRules
  model.startupCommands = config.startupCommands
  model.quickshell = config.quickshell
  
  for rule in config.tagRules:
    if model.tags.hasKey(rule.tagId):
      model.tags[rule.tagId].layoutMode = rule.defaultLayout
      model.tags[rule.tagId].name = rule.name
    else:
      model.tags[rule.tagId] = TagState(tagId: rule.tagId, layoutMode: rule.defaultLayout, name: rule.name, masterCount: 1, masterSplitRatio: 0.55)
