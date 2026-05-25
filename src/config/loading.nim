import std/[os, strutils]
import kdl
import ../types/config_values

const MaxConfigIncludeDepth* = 10

proc defaultConfigPath*(): string =
  let configHome = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  return configHome / "triad" / "config.kdl"

proc expandConfigPath*(path: string): string =
  let stripped = path.strip()
  if stripped == "~":
    getHomeDir()
  elif stripped.startsWith("~/"):
    getHomeDir() / stripped[2 ..^ 1]
  else:
    stripped

proc absoluteConfigPath*(path: string, baseDir = ""): string =
  let expanded = path.expandConfigPath()
  let candidate =
    if expanded.isAbsolute():
      expanded
    elif baseDir.len > 0:
      baseDir / expanded
    else:
      expanded
  candidate.absolutePath().normalizedPath()

proc addUnique(paths: var seq[string], path: string) =
  if paths.find(path) < 0:
    paths.add(path)

proc includeOptional(node: KdlNode): bool =
  node.props.hasKey("optional") and node.props["optional"].kBool()

proc appendConfigNodes(
    path: string, nodes: var KdlDoc, paths: var seq[string], stack: var seq[string]
) =
  let configPath = path.absoluteConfigPath()
  if stack.find(configPath) >= 0:
    raise newException(ValueError, "recursive config include: " & configPath)
  if stack.len >= MaxConfigIncludeDepth:
    raise newException(ValueError, "config include depth exceeded: " & configPath)

  stack.add(configPath)
  paths.addUnique(configPath)
  let doc = parseKdlFile(configPath)
  let baseDir = configPath.splitFile().dir
  for node in doc:
    if node.name == "include":
      if node.args.len == 0:
        raise newException(ValueError, "include requires a path: " & configPath)
      let includePath = node.args[0].kString().absoluteConfigPath(baseDir)
      if fileExists(includePath):
        appendConfigNodes(includePath, nodes, paths, stack)
      elif not node.includeOptional():
        raise newException(IOError, "included config not found: " & includePath)
    else:
      nodes.add(node)
  stack.setLen(stack.len - 1)

proc loadConfigDocument*(path: string): ConfigDocument =
  var stack: seq[string] = @[]
  appendConfigNodes(path, result.nodes, result.paths, stack)
