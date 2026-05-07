import kdl, tables, ../core/model, os, chronicles

type
  Config* = object
    layout*: LayoutConfig
    tagRules*: seq[TagRule]
    windowRules*: seq[WindowRule]

  LayoutConfig* = object
    gaps*: int32
    centerFocusedColumn*: string # "never", "always", "on-overflow"
    defaultColumnWidth*: float32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    enableAnimations*: bool
    animationSpeed*: float32

  TagRule* = object
    tagId*: uint32
    defaultLayout*: LayoutMode

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
  
  try:
    let doc = parseKdlFile(path)
    for node in doc:
      if node.name == "layout":
        for child in node.children:
          if child.name == "gaps":
            result.layout.gaps = int32(child.args[0].kInt())
          elif child.name == "center-focused-column":
            result.layout.centerFocusedColumn = child.args[0].kString()
          elif child.name == "default-column-width":
            if child.children.len > 0 and child.children[0].name == "proportion":
              result.layout.defaultColumnWidth = float32(child.children[0].args[0].kFloat())
          elif child.name == "scroller-focus-center":
            result.layout.scrollerFocusCenter = child.args[0].kBool()
          elif child.name == "scroller-prefer-center":
            result.layout.scrollerPreferCenter = child.args[0].kBool()
          elif child.name == "enable-animations":
            result.layout.enableAnimations = child.args[0].kBool()
          elif child.name == "animation-speed":
            result.layout.animationSpeed = float32(child.args[0].kFloat())
      
      elif node.name == "tag-rules":
        for child in node.children:
          if child.name == "tag":
            let id = uint32(child.args[0].kInt())
            var layout = Scroller
            if child.props.hasKey("default-layout"):
              case child.props["default-layout"].kString()
              of "scroller": layout = Scroller
              of "vertical-scroller": layout = VerticalScroller
              of "tile": layout = MasterStack
              of "grid": layout = Grid
              of "monocle": layout = Monocle
            result.tagRules.add(TagRule(tagId: id, defaultLayout: layout))
            
      elif node.name == "window-rule":
        var rule = WindowRule()
        for child in node.children:
          if child.name == "match":
            if child.props.hasKey("app-id"):
              rule.appIdMatch = child.props["app-id"].kString()
            if child.props.hasKey("title"):
              rule.titleMatch = child.props["title"].kString()
          elif child.name == "default-tag":
            rule.defaultTag = uint32(child.args[0].kInt())
          elif child.name == "open-floating":
            rule.openFloating = child.args[0].kBool()
        result.windowRules.add(rule)
            
  except:
    warn "Could not load config, using defaults", path=path

proc applyConfig*(model: var Model, config: Config) =
  model.outerGaps = config.layout.gaps
  model.innerGaps = config.layout.gaps div 2
  model.scrollerFocusCenter = config.layout.scrollerFocusCenter
  model.scrollerPreferCenter = config.layout.scrollerPreferCenter
  model.centerFocusedColumn = config.layout.centerFocusedColumn
  model.enableAnimations = config.layout.enableAnimations
  model.animationSpeed = config.layout.animationSpeed
  model.windowRules = config.windowRules
  
  for rule in config.tagRules:
    if model.tags.hasKey(rule.tagId):
      model.tags[rule.tagId].layoutMode = rule.defaultLayout
    else:
      model.tags[rule.tagId] = TagState(tagId: rule.tagId, layoutMode: rule.defaultLayout)
