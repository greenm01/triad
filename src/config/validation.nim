import std/[editdistance, strutils]
import kdl

const
  MaxSuggestionDistance = 2
  KnownTopLevelConfigNodes = [
    "layout", "workspaces", "output", "workspace-rules", "window-rule",
    "spawn-at-startup", "environment", "window-menu-command", "bindings",
    "switch-events", "shells", "janet", "terminal", "screen-lock", "scratchpad",
    "overview", "recent-windows", "layout-switch-toast", "floating", "screenshot",
    "input", "cursor", "hotkey-overlay", "config-notification", "presentation-mode",
    "allow-exit-session", "protocol-surfaces",
  ]

proc oneOf(value: string, choices: openArray[string]): bool =
  for choice in choices:
    if value == choice:
      return true
  false

proc isIntegerValue(value: KdlVal): bool =
  value.kind in {KInt, KInt8, KInt16, KInt32, KInt64}

proc isNumberValue(value: KdlVal): bool =
  value.kind in {KInt, KInt8, KInt16, KInt32, KInt64, KFloat, KFloat32, KFloat64}

proc nearestName(name: string, candidates: openArray[string]): string =
  var bestDistance = MaxSuggestionDistance + 1
  let normalized = name.toLowerAscii()
  for candidate in candidates:
    let distance = editDistanceAscii(normalized, candidate)
    if distance < bestDistance:
      bestDistance = distance
      result = candidate
  if bestDistance > MaxSuggestionDistance:
    result = ""

proc unknownField(context, name: string, candidates: openArray[string]): string =
  result = context & ": unknown field \"" & name & "\""
  let suggestion = name.nearestName(candidates)
  if suggestion.len > 0:
    result.add("; did you mean \"" & suggestion & "\"?")

proc unknownTopLevelNode(name: string): string =
  result = "unknown top-level config node \"" & name & "\""
  var candidates: seq[string]
  for candidate in KnownTopLevelConfigNodes:
    candidates.add(candidate)
  candidates.add("include")
  let suggestion = name.nearestName(candidates)
  if suggestion.len > 0:
    result.add("; did you mean \"" & suggestion & "\"?")

proc expectArgs(node: KdlNode, context: string, count: int): string =
  if node.args.len != count:
    return context & ": expected " & $count & " argument(s)"

proc expectMinArgs(node: KdlNode, context: string, count: int): string =
  if node.args.len < count:
    return context & ": expected at least " & $count & " argument(s)"

proc expectNoArgs(node: KdlNode, context: string): string =
  if node.args.len != 0:
    return context & ": expected no arguments"

proc expectNoProps(node: KdlNode, context: string): string =
  if node.props.len > 0:
    return context & ": properties are not supported"

proc expectNoChildren(node: KdlNode, context: string): string =
  if node.children.len > 0:
    return context & ": children are not supported"

proc expectStringArg(node: KdlNode, context: string, index = 0): string =
  if node.args.len <= index or node.args[index].kind != KString:
    return context & ": expected string argument " & $index

proc expectBoolArg(node: KdlNode, context: string, index = 0): string =
  if node.args.len <= index or node.args[index].kind != KBool:
    return context & ": expected bool argument " & $index

proc expectIntegerArg(node: KdlNode, context: string, index = 0): string =
  if node.args.len <= index or not node.args[index].isIntegerValue():
    return context & ": expected integer argument " & $index

proc expectNumberArg(node: KdlNode, context: string, index = 0): string =
  if node.args.len <= index or not node.args[index].isNumberValue():
    return context & ": expected numeric argument " & $index

proc expectFlagOrBool(node: KdlNode, context: string): string =
  if node.args.len > 1:
    return context & ": expected a flag or bool"
  if node.args.len == 1 and node.args[0].kind != KBool:
    return context & ": expected a bool value"

proc validateProps(node: KdlNode, context: string, allowed: openArray[string]): string =
  for key, _ in node.props.pairs:
    if not key.oneOf(allowed):
      return unknownField(context, key, allowed)

proc validateCommandNode(node: KdlNode, context: string): string =
  result = node.expectMinArgs(context, 1)
  if result.len > 0:
    return
  for i, arg in node.args:
    if arg.kind != KString:
      return context & ": expected string argument " & $i
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  result = node.expectNoChildren(context)

proc validateProportionChild(node: KdlNode, context: string): string =
  result = node.expectNoArgs(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  if node.children.len != 1 or node.children[0].name != "proportion":
    return context & ": expected proportion child"
  let child = node.children[0]
  result = child.expectArgs(context & ".proportion", 1)
  if result.len > 0:
    return
  result = child.expectNumberArg(context & ".proportion")
  if result.len > 0:
    return
  result = child.expectNoProps(context & ".proportion")
  if result.len > 0:
    return
  result = child.expectNoChildren(context & ".proportion")

proc validateColorNode(node: KdlNode, context: string): string =
  result = node.expectArgs(context, 1)
  if result.len > 0:
    return
  result = node.expectStringArg(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  result = node.expectNoChildren(context)

proc validateSimpleBoolNode(node: KdlNode, context: string): string =
  result = node.expectArgs(context, 1)
  if result.len > 0:
    return
  result = node.expectBoolArg(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  result = node.expectNoChildren(context)

proc validateFlagNode(node: KdlNode, context: string): string =
  result = node.expectFlagOrBool(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  result = node.expectNoChildren(context)

proc validateLayoutNode(node: KdlNode, context: string): string =
  let allowed = [
    "gaps", "center-focused-column", "default-column-width", "default-window-width",
    "default-window-height", "master", "spiral", "border", "initial-split-ratio",
    "frame-tabs", "scroller-focus-center", "scroller-prefer-center",
    "scroller-proportion-presets", "enable-animations", "animation-speed",
    "animation-snap-threshold", "frame-rate", "smart-gaps", "layout-cycle",
  ]
  result = node.expectNoArgs(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  for child in node.children:
    let childContext = context & "." & child.name
    case child.name
    of "gaps":
      result = child.expectArgs(childContext, 1)
      if result.len == 0:
        result = child.expectIntegerArg(childContext)
    of "center-focused-column":
      result = child.expectArgs(childContext, 1)
      if result.len == 0:
        result = child.expectStringArg(childContext)
      if result.len == 0 and
          child.args[0].kString() notin ["never", "always", "on-overflow"]:
        result = childContext & ": expected never, always, or on-overflow"
    of "default-column-width", "default-window-width", "default-window-height":
      result = child.validateProportionChild(childContext)
    of "master":
      result = child.expectNoArgs(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      let masterFields = ["count", "split-ratio"]
      for masterChild in child.children:
        if result.len > 0:
          break
        let nestedContext = childContext & "." & masterChild.name
        case masterChild.name
        of "count":
          result = masterChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = masterChild.expectIntegerArg(nestedContext)
        of "split-ratio":
          result = masterChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = masterChild.expectNumberArg(nestedContext)
        else:
          result = unknownField(childContext, masterChild.name, masterFields)
    of "spiral":
      result = child.expectNoArgs(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      let spiralFields = ["ratio", "main-pane-ratio", "main-pane", "clockwise"]
      for spiralChild in child.children:
        if result.len > 0:
          break
        let nestedContext = childContext & "." & spiralChild.name
        case spiralChild.name
        of "ratio", "main-pane-ratio":
          result = spiralChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = spiralChild.expectNumberArg(nestedContext)
        of "main-pane":
          result = spiralChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = spiralChild.expectStringArg(nestedContext)
          if result.len == 0 and
              spiralChild.args[0].kString() notin ["left", "top", "right", "bottom"]:
            result = nestedContext & ": expected left, top, right, or bottom"
        of "clockwise":
          result = spiralChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = spiralChild.expectBoolArg(nestedContext)
        else:
          result = unknownField(childContext, spiralChild.name, spiralFields)
    of "border":
      result = child.expectNoArgs(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      let borderFields = ["width", "active-color", "inactive-color"]
      for borderChild in child.children:
        if result.len > 0:
          break
        let nestedContext = childContext & "." & borderChild.name
        case borderChild.name
        of "width":
          result = borderChild.expectArgs(nestedContext, 1)
          if result.len == 0:
            result = borderChild.expectIntegerArg(nestedContext)
        of "active-color", "inactive-color":
          result = borderChild.validateColorNode(nestedContext)
        else:
          result = unknownField(childContext, borderChild.name, borderFields)
    of "initial-split-ratio", "animation-speed", "animation-snap-threshold":
      result = child.expectArgs(childContext, 1)
      if result.len == 0:
        result = child.expectNumberArg(childContext)
    of "frame-tabs":
      result = child.expectNoArgs(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      let tabFields = [
        "active-color", "active-unfocused-color", "inactive-color", "active-line-color",
        "active-unfocused-line-color", "empty-background-color",
      ]
      for tabChild in child.children:
        if result.len > 0:
          break
        let nestedContext = childContext & "." & tabChild.name
        if tabChild.name.oneOf(tabFields):
          result = tabChild.validateColorNode(nestedContext)
        else:
          result = unknownField(childContext, tabChild.name, tabFields)
    of "scroller-focus-center", "scroller-prefer-center", "enable-animations",
        "smart-gaps":
      result = child.validateSimpleBoolNode(childContext)
    of "scroller-proportion-presets":
      result = child.expectNoProps(childContext)
      for i, arg in child.args:
        if result.len > 0:
          break
        if not arg.isNumberValue():
          result = childContext & ": expected numeric argument " & $i
      if result.len == 0:
        result = child.expectNoChildren(childContext)
    of "frame-rate":
      result = child.expectArgs(childContext, 1)
      if result.len == 0 and child.args[0].kind == KString:
        if child.args[0].kString() != "auto":
          result = childContext & ": expected auto or integer FPS"
      elif result.len == 0:
        result = child.expectIntegerArg(childContext)
    of "layout-cycle":
      result = child.expectNoProps(childContext)
      for i, arg in child.args:
        if result.len > 0:
          break
        if arg.kind != KString:
          result = childContext & ": expected string argument " & $i
      if result.len == 0:
        result = child.expectNoChildren(childContext)
    else:
      result = unknownField(context, child.name, allowed)
    if result.len > 0:
      return

proc validateBindingsNode(node: KdlNode, context: string): string =
  let allowed = [
    "mirror-hjkl-arrows", "bind", "layout", "pointer-bind", "axis-bind", "gesture-bind"
  ]
  result = node.expectNoArgs(context)
  if result.len > 0:
    return
  result = node.expectNoProps(context)
  if result.len > 0:
    return
  for i, child in node.children:
    let childContext = context & "." & child.name & "[" & $i & "]"
    case child.name
    of "mirror-hjkl-arrows":
      result = child.validateSimpleBoolNode(childContext)
    of "bind":
      result = child.expectArgs(childContext, 2)
      if result.len == 0:
        result = child.expectStringArg(childContext, 0)
      if result.len == 0:
        result = child.expectStringArg(childContext, 1)
      if result.len == 0:
        result = child.validateProps(
          childContext,
          [
            "layout", "mode", "allow-inhibiting", "on-release", "while-locked",
            "hotkey-overlay-title",
          ],
        )
    of "layout":
      result = child.expectArgs(childContext, 1)
      if result.len == 0:
        result = child.expectStringArg(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      for j, scopedChild in child.children:
        if result.len > 0:
          break
        let scopedContext = childContext & "." & scopedChild.name & "[" & $j & "]"
        if scopedChild.name != "bind":
          result = unknownField(childContext, scopedChild.name, ["bind"])
        else:
          result = scopedChild.expectArgs(scopedContext, 2)
          if result.len == 0:
            result = scopedChild.expectStringArg(scopedContext, 0)
          if result.len == 0:
            result = scopedChild.expectStringArg(scopedContext, 1)
          if result.len == 0:
            result = scopedChild.validateProps(
              scopedContext,
              [
                "layout", "mode", "allow-inhibiting", "on-release", "while-locked",
                "hotkey-overlay-title",
              ],
            )
    of "pointer-bind", "axis-bind":
      result = child.expectArgs(childContext, 2)
      if result.len == 0:
        result = child.expectStringArg(childContext, 0)
      if result.len == 0:
        result = child.expectStringArg(childContext, 1)
      if result.len == 0:
        result = child.validateProps(childContext, ["mode", "allow-inhibiting"])
    of "gesture-bind":
      result = child.expectArgs(childContext, 2)
      if result.len == 0:
        result = child.expectStringArg(childContext, 0)
      if result.len == 0:
        result = child.expectStringArg(childContext, 1)
      if result.len == 0:
        result =
          child.validateProps(childContext, ["fingers", "mode", "allow-inhibiting"])
      if result.len == 0:
        if not child.props.hasKey("fingers"):
          result = childContext & ": fingers property is required"
        elif not child.props["fingers"].isIntegerValue():
          result = childContext & ".fingers: expected integer"
    else:
      result = unknownField(context, child.name, allowed)
    if result.len > 0:
      return

proc validateNamedChildren(
  node: KdlNode,
  context: string,
  allowed: openArray[string],
  allowArgs = false,
  allowProps = false,
): string

proc validateWindowRuleNode(node: KdlNode, context: string): string =
  let allowed = [
    "match", "exclude", "default-workspace", "default-workspaces", "open-on-output",
    "default-column-width", "scroller-proportion", "scroller-single-proportion",
    "default-window-width", "default-window-height", "min-width", "min-height",
    "max-width", "max-height", "open-floating", "open-focused", "open-fullscreen",
    "open-maximized", "open-maximized-to-edges", "open-on-all-workspaces",
    "open-overlay", "open-unmanaged-global", "terminal", "allow-swallow",
    "maximize-policy", "respect-size-hints", "center-floating", "parented-role",
    "open-named-scratchpad", "default-floating-position", "border", "focus-ring",
    "clip-to-geometry", "dialog-viewport-jump", "keyboard-shortcuts-inhibit",
    "idle-inhibit", "presentation-mode", "tiled-state", "forced-layout", "floating",
  ]
  for child in node.children:
    let childContext = context & "." & child.name
    if not child.name.oneOf(allowed):
      return unknownField(context, child.name, allowed)
    case child.name
    of "border":
      result = child.validateNamedChildren(
        childContext, ["width", "active-color", "inactive-color"]
      )
    of "focus-ring":
      result = child.validateNamedChildren(childContext, ["width", "active-color"])
    of "floating":
      result = child.validateNamedChildren(
        childContext,
        ["x-ratio", "y-ratio", "width-ratio", "width", "height-ratio", "height"],
      )
    else:
      discard
    if result.len > 0:
      return

proc validateInputNode(node: KdlNode, context: string): string =
  let allowed = ["keyboard", "mouse", "touchpad", "trackpoint", "trackball"]
  for child in node.children:
    if not child.name.oneOf(allowed):
      return unknownField(context, child.name, allowed)
    let childContext = context & "." & child.name
    case child.name
    of "keyboard":
      result = child.validateNamedChildren(
        childContext, ["repeat-rate", "repeat-delay", "numlock", "capslock", "xkb"]
      )
      for keyboardChild in child.children:
        if result.len > 0:
          break
        if keyboardChild.name == "xkb":
          result = keyboardChild.validateNamedChildren(
            childContext & ".xkb", ["rules", "model", "layout", "variant", "options"]
          )
    of "mouse", "trackpoint", "trackball":
      result = child.validateNamedChildren(
        childContext,
        [
          "off", "natural-scroll", "accel-profile", "accel-speed", "scroll-method",
          "scroll-button", "scroll-button-lock", "left-handed", "middle-emulation",
          "scroll-factor",
        ],
      )
    of "touchpad":
      result = child.validateNamedChildren(
        childContext,
        [
          "off", "natural-scroll", "accel-profile", "accel-speed", "scroll-method",
          "scroll-button", "scroll-button-lock", "left-handed", "middle-emulation",
          "scroll-factor", "tap", "tap-button-map", "drag", "drag-lock", "dwt", "dwtp",
          "click-method", "disabled-on-external-mouse",
        ],
      )
    else:
      discard
    if result.len > 0:
      return

proc validateShellsNode(node: KdlNode, context: string): string =
  result = node.validateNamedChildren(
    context, ["enabled", "active", "cycle", "watchdog", "profile"]
  )
  if result.len > 0:
    return
  for child in node.children:
    let childContext = context & "." & child.name
    case child.name
    of "watchdog":
      result = child.validateNamedChildren(
        childContext, ["enabled", "fallback", "exclusive-focus-timeout-ms"]
      )
    of "profile":
      result = child.expectArgs(childContext, 1)
      if result.len == 0:
        result = child.expectStringArg(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      if result.len == 0:
        result = child.validateNamedChildren(
          childContext, ["launch", "stop", "niri-compat"], allowArgs = true
        )
    else:
      discard
    if result.len > 0:
      return

proc validateOverviewNode(node: KdlNode, context: string): string =
  result = node.validateNamedChildren(
    context,
    [
      "outer-gap", "inner-gap-multiplier", "zoom", "tab-mode", "scroller-indicators",
      "hot-corners",
    ],
  )
  if result.len > 0:
    return
  for child in node.children:
    if child.name == "hot-corners":
      result = child.validateNamedChildren(
        context & ".hot-corners",
        ["size", "top-left", "top-right", "bottom-left", "bottom-right"],
      )
      if result.len > 0:
        return

proc validateRecentWindowsNode(node: KdlNode, context: string): string =
  result = node.validateNamedChildren(
    context,
    [
      "on", "off", "enabled", "debounce-ms", "open-delay-ms", "highlight", "previews",
      "binds",
    ],
  )
  if result.len > 0:
    return
  for child in node.children:
    let childContext = context & "." & child.name
    case child.name
    of "highlight":
      result = child.validateNamedChildren(
        childContext, ["active-color", "urgent-color", "padding", "corner-radius"]
      )
    of "previews":
      result = child.validateNamedChildren(childContext, ["max-height", "max-scale"])
    of "binds":
      result = child.expectNoArgs(childContext)
      if result.len == 0:
        result = child.expectNoProps(childContext)
      for i, bindChild in child.children:
        if result.len > 0:
          break
        let bindContext = childContext & "." & bindChild.name & "[" & $i & "]"
        if bindChild.name != "bind":
          result = unknownField(childContext, bindChild.name, ["bind"])
        else:
          result = bindChild.expectArgs(bindContext, 2)
          if result.len == 0:
            result = bindChild.expectStringArg(bindContext)
          if result.len == 0:
            result = bindChild.expectStringArg(bindContext, 1)
    else:
      discard
    if result.len > 0:
      return

proc validateNamedChildren(
    node: KdlNode,
    context: string,
    allowed: openArray[string],
    allowArgs = false,
    allowProps = false,
): string =
  if not allowArgs:
    result = node.expectNoArgs(context)
    if result.len > 0:
      return
  if not allowProps:
    result = node.expectNoProps(context)
    if result.len > 0:
      return
  for child in node.children:
    if not child.name.oneOf(allowed):
      return unknownField(context, child.name, allowed)

proc validateConfigNode(node: KdlNode, index: int): string =
  let context =
    if node.name == "window-rule":
      "window-rule[" & $index & "]"
    else:
      node.name
  case node.name
  of "layout":
    result = node.validateLayoutNode(context)
  of "workspaces":
    result = node.validateNamedChildren(context, ["default-count", "default-layout"])
  of "output":
    discard
  of "workspace-rules":
    result = node.validateNamedChildren(context, ["workspace"])
  of "window-rule":
    result = node.validateWindowRuleNode(context)
  of "spawn-at-startup":
    result = node.validateCommandNode(context)
  of "environment":
    result = node.expectNoArgs(context)
    if result.len == 0:
      result = node.expectNoProps(context)
    for child in node.children:
      if result.len > 0:
        break
      result = child.expectArgs(context & "." & child.name, 1)
  of "window-menu-command":
    result = node.validateCommandNode(context)
  of "bindings":
    result = node.validateBindingsNode(context)
  of "switch-events":
    result = node.validateNamedChildren(
      context, ["lid-close", "lid-open", "tablet-mode-on", "tablet-mode-off"]
    )
  of "shells":
    result = node.validateShellsNode(context)
  of "janet":
    result = node.validateNamedChildren(
      context,
      ["enabled", "automation-dir", "layout-dir", "script-dir", "fuel-limit", "layout"],
    )
  of "terminal", "screen-lock":
    result = node.validateNamedChildren(context, ["command"])
  of "scratchpad":
    result = node.validateNamedChildren(context, ["width-ratio", "height-ratio"])
  of "overview":
    result = node.validateOverviewNode(context)
  of "recent-windows":
    result = node.validateRecentWindowsNode(context)
  of "layout-switch-toast":
    result =
      node.validateNamedChildren(context, ["enabled", "timeout-ms", "ring-color"])
  of "floating":
    result = node.validateNamedChildren(
      context,
      ["x-ratio", "y-ratio", "width-ratio", "height-ratio", "min-width", "min-height"],
    )
  of "screenshot":
    result = node.validateNamedChildren(
      context,
      [
        "directory", "filename-prefix", "capture-command", "region-selector-command",
        "clipboard-command", "show-pointer",
      ],
    )
  of "input":
    result = node.validateInputNode(context)
  of "cursor":
    result = node.validateNamedChildren(
      context,
      ["theme", "size", "shake-to-find", "hide-when-typing", "hide-after-inactive-ms"],
    )
  of "hotkey-overlay":
    result = node.validateNamedChildren(
      context, ["skip-at-startup", "hide-not-bound", "position", "columns"]
    )
  of "config-notification":
    result = node.validateNamedChildren(
      context, ["reload-succeeded", "reload-failed", "reload-rolled-back"]
    )
  of "presentation-mode":
    result = node.expectArgs(context, 1)
    if result.len == 0:
      result = node.expectStringArg(context)
  of "allow-exit-session":
    result = node.validateSimpleBoolNode(context)
  of "protocol-surfaces":
    result = node.validateNamedChildren(context, ["enabled", "visible-debug"])
  else:
    result = unknownTopLevelNode(node.name)

proc validateConfigDocument*(doc: KdlDoc): string =
  var windowRuleIndex = 0
  for node in doc:
    let index =
      if node.name == "window-rule":
        let current = windowRuleIndex
        inc windowRuleIndex
        current
      else:
        0
    result = validateConfigNode(node, index)
    if result.len > 0:
      return
