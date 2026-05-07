import kdl, tables, ../core/model, os

type
  Config* = object
    layout*: LayoutConfig
    tagRules*: seq[TagRule]

  LayoutConfig* = object
    gaps*: int32
    centerFocusedColumn*: string # "never", "always", "on-overflow"
    defaultColumnWidth*: float32

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
            # Niri uses: default-column-width { proportion 0.5; }
            if child.children.len > 0 and child.children[0].name == "proportion":
              result.layout.defaultColumnWidth = float32(child.children[0].args[0].kFloat())
      
      elif node.name == "tag-rules":
        for child in node.children:
          if child.name == "tag":
            let id = uint32(child.args[0].kInt())
            var layout = Scroller
            if child.props.hasKey("default-layout"):
              case child.props["default-layout"].kString()
              of "scroller": layout = Scroller
              of "tile": layout = MasterStack
              of "grid": layout = Grid
              of "monocle": layout = Monocle
            result.tagRules.add(TagRule(tagId: id, defaultLayout: layout))
            
  except:
    echo "Warning: Could not load config, using defaults"

proc applyConfig*(model: var Model, config: Config) =
  model.outerGaps = config.layout.gaps
  model.innerGaps = config.layout.gaps div 2
  
  for rule in config.tagRules:
    if model.tags.hasKey(rule.tagId):
      model.tags[rule.tagId].layoutMode = rule.defaultLayout
    else:
      model.tags[rule.tagId] = TagState(tagId: rule.tagId, layoutMode: rule.defaultLayout)
