import std/[options, os, re, strutils]
import chronicles, kdl
import defaults
import keysyms
import ../types/config_values
import ../types/runtime_values

export config_values

const MaxConfigIncludeDepth* = 10

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

proc runtimeFrameRate*(value: int32): int32 =
  if value <= 0:
    DefaultFrameRate
  else:
    clamp32(value, MinFrameRate, MaxFrameRate)

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

proc workspaceTargets(node: KdlNode): seq[uint32] =
  for arg in node.args:
    let rawWorkspace = arg.kInt()
    if rawWorkspace > 0:
      let slot = uint32(rawWorkspace)
      if result.find(slot) == -1:
        result.add(slot)

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

proc validEnvironmentName(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0].isAlphaAscii() or name[0] == '_'):
    return false
  for ch in name:
    if not (ch.isAlphaNumeric() or ch == '_'):
      return false
  true

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

proc parseMaximizePolicy(name: string): WindowRuleMaximizePolicy =
  case name.toLowerAscii()
  of "edge":
    WindowRuleMaximizePolicy.Edge
  of "column":
    WindowRuleMaximizePolicy.Column
  of "ignore":
    WindowRuleMaximizePolicy.Ignore
  else:
    raise newException(ValueError, "invalid maximize-policy: " & name)

proc parseFloatingPositionAnchor(name: string): FloatingPositionAnchor =
  case name.toLowerAscii()
  of "top-left":
    FloatingPositionAnchor.TopLeft
  of "top-right":
    FloatingPositionAnchor.TopRight
  of "bottom-left":
    FloatingPositionAnchor.BottomLeft
  of "bottom-right":
    FloatingPositionAnchor.BottomRight
  of "top":
    FloatingPositionAnchor.Top
  of "bottom":
    FloatingPositionAnchor.Bottom
  of "left":
    FloatingPositionAnchor.Left
  of "right":
    FloatingPositionAnchor.Right
  else:
    raise newException(ValueError, "invalid default-floating-position anchor: " & name)

proc parseInputAccelProfile(name: string): InputAccelProfile =
  case name.normalize()
  of "none":
    InputAccelProfile.AccelNone
  of "flat":
    InputAccelProfile.AccelFlat
  of "adaptive":
    InputAccelProfile.AccelAdaptive
  else:
    raise newException(ValueError, "invalid input accel-profile: " & name)

proc parseInputScrollMethod(name: string): InputScrollMethod =
  case name.normalize()
  of "no-scroll", "none":
    InputScrollMethod.ScrollNone
  of "two-finger":
    InputScrollMethod.ScrollTwoFinger
  of "edge":
    InputScrollMethod.ScrollEdge
  of "on-button-down":
    InputScrollMethod.ScrollOnButtonDown
  else:
    raise newException(ValueError, "invalid input scroll-method: " & name)

proc parseInputClickMethod(name: string): InputClickMethod =
  case name.normalize()
  of "button-areas":
    InputClickMethod.ClickButtonAreas
  of "clickfinger":
    InputClickMethod.ClickFinger
  else:
    raise newException(ValueError, "invalid input click-method: " & name)

proc parseInputButtonMap(name: string): InputButtonMap =
  case name.normalize()
  of "left-right-middle", "lrm":
    InputButtonMap.ButtonMapLeftRightMiddle
  of "left-middle-right", "lmr":
    InputButtonMap.ButtonMapLeftMiddleRight
  else:
    raise newException(ValueError, "invalid input button map: " & name)

proc parseHotkeyOverlayPosition(name: string): HotkeyOverlayPosition =
  case name.normalize()
  of "top":
    HotkeyOverlayPosition.Top
  of "center":
    HotkeyOverlayPosition.Center
  of "bottom":
    HotkeyOverlayPosition.Bottom
  else:
    raise newException(ValueError, "invalid hotkey-overlay position: " & name)

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

proc canonicalKeyName(rawKey: string): string =
  case rawKey.strip().normalize()
  of "/":
    "Slash"
  of "?":
    "Question"
  else:
    rawKey.strip()

proc shiftedKeyName(rawKey: string): string =
  case rawKey.strip().normalize()
  of "~": "~"
  of "!": "!"
  of "@": "@"
  of "#": "#"
  of "$": "$"
  of "%": "%"
  of "^": "^"
  of "&": "&"
  of "*": "*"
  of "(": "("
  of ")": ")"
  of "_": "_"
  of "+": "+"
  of "{": "{"
  of "}": "}"
  of "|": "|"
  of ":": ":"
  of "\"": "\""
  of "<": "<"
  of ">": ">"
  of "`", "grave", "backtick": "~"
  of "1": "!"
  of "2": "@"
  of "3": "#"
  of "4": "$"
  of "5": "%"
  of "6": "^"
  of "7": "&"
  of "8": "*"
  of "9": "("
  of "0": ")"
  of "-", "minus": "_"
  of "=", "equal", "equals": "+"
  of "[", "bracketleft", "leftbracket": "{"
  of "]", "bracketright", "rightbracket": "}"
  of "\\", "backslash": "|"
  of ";", "semicolon": ":"
  of "'", "apostrophe", "quote": "\""
  of ",", "comma": "<"
  of ".", "period", "dot": ">"
  of "/", "slash", "?", "question": "Question"
  else: ""

proc normalizeKeySpec(
    rawKey: string, modifiers: uint32
): tuple[key: string, modifiers: uint32] =
  result.key = rawKey.canonicalKeyName()
  result.modifiers = modifiers
  let shifted = rawKey.shiftedKeyName()
  if (modifiers and ShiftModifier) != 0 and shifted.len > 0:
    result.key = shifted
    result.modifiers = modifiers and not ShiftModifier

proc parseKeySpec(value: string): tuple[key: string, modifiers: uint32] =
  let parts = value.split("+")
  if parts.len == 0:
    return ("", 0'u32)
  let rawKey = parts[^1].strip()
  var modifiers = 0'u32
  if parts.len > 1:
    modifiers = parseModifiers(parts[0 .. ^2].join("+"))
  result = normalizeKeySpec(rawKey, modifiers)

proc applyHotkeyOverlayTitle(binding: var KeyBindingConfig, value: KdlVal) =
  if value.kind == KNull:
    binding.hotkeyOverlayTitleKind = HotkeyOverlayTitleKind.HotkeyTitleHidden
  else:
    binding.hotkeyOverlayTitleKind = HotkeyOverlayTitleKind.HotkeyTitleCustom
    binding.hotkeyOverlayTitle = value.kString()

proc childFlagEnabled(node: KdlNode): bool =
  node.args.len == 0 or node.args[0].kBool()

proc stringArgs(node: KdlNode): seq[string] =
  for arg in node.args:
    result.add(arg.kString())

proc parseInputXkbConfig(config: var InputXkbConfig, node: KdlNode) =
  for child in node.children:
    try:
      if child.name == "rules" and child.args.len > 0:
        config.rulesSet = true
        config.rules = child.args[0].kString()
      elif child.name == "model" and child.args.len > 0:
        config.modelSet = true
        config.model = child.args[0].kString()
      elif child.name == "layout" and child.args.len > 0:
        config.layoutSet = true
        config.layout = child.args[0].kString()
      elif child.name == "variant" and child.args.len > 0:
        config.variantSet = true
        config.variant = child.args[0].kString()
      elif child.name == "options" and child.args.len > 0:
        config.optionsSet = true
        config.options = child.args[0].kString()
    except CatchableError as e:
      warn "Ignoring invalid input xkb field", field = child.name, error = e.msg

proc parseInputKeyboardConfig(config: var InputKeyboardConfig, node: KdlNode) =
  for child in node.children:
    try:
      if child.name == "repeat-rate" and child.args.len > 0:
        config.repeatRateSet = true
        config.repeatRate = clamp32(int32(child.args[0].kInt()), 0, 1000)
      elif child.name == "repeat-delay" and child.args.len > 0:
        config.repeatDelaySet = true
        config.repeatDelay = clamp32(int32(child.args[0].kInt()), 0, 20000)
      elif child.name == "numlock":
        config.numlockSet = true
        config.numlock = child.childFlagEnabled()
      elif child.name == "capslock":
        config.capslockSet = true
        config.capslock = child.childFlagEnabled()
      elif child.name == "xkb":
        config.xkb.parseInputXkbConfig(child)
    except CatchableError as e:
      warn "Ignoring invalid input keyboard field", field = child.name, error = e.msg

proc parseInputPointerConfig(config: var InputPointerConfig, node: KdlNode) =
  for child in node.children:
    try:
      if child.name == "off":
        config.offSet = true
        config.off = child.childFlagEnabled()
      elif child.name == "natural-scroll":
        config.naturalScrollSet = true
        config.naturalScroll = child.childFlagEnabled()
      elif child.name == "accel-profile" and child.args.len > 0:
        config.accelProfileSet = true
        config.accelProfile = parseInputAccelProfile(child.args[0].kString())
      elif child.name == "accel-speed" and child.args.len > 0:
        config.accelSpeedSet = true
        config.accelSpeed = clampF32(float32(child.args[0].kFloat()), -1.0, 1.0)
      elif child.name == "scroll-method" and child.args.len > 0:
        config.scrollMethodSet = true
        config.scrollMethod = parseInputScrollMethod(child.args[0].kString())
      elif child.name == "scroll-button" and child.args.len > 0:
        config.scrollButtonSet = true
        config.scrollButton = uint32(max(0, child.args[0].kInt()))
      elif child.name == "scroll-button-lock":
        config.scrollButtonLockSet = true
        config.scrollButtonLock = child.childFlagEnabled()
      elif child.name == "left-handed":
        config.leftHandedSet = true
        config.leftHanded = child.childFlagEnabled()
      elif child.name == "middle-emulation":
        config.middleEmulationSet = true
        config.middleEmulation = child.childFlagEnabled()
      elif child.name == "scroll-factor" and child.args.len > 0:
        config.scrollFactorSet = true
        config.scrollFactor = clampF32(float32(child.args[0].kFloat()), 0.0, 100.0)
    except CatchableError as e:
      warn "Ignoring invalid input pointer field", field = child.name, error = e.msg

proc parseInputTouchpadConfig(config: var InputTouchpadConfig, node: KdlNode) =
  config.pointer.parseInputPointerConfig(node)
  for child in node.children:
    try:
      if child.name == "tap":
        config.tapSet = true
        config.tap = child.childFlagEnabled()
      elif child.name == "tap-button-map" and child.args.len > 0:
        config.tapButtonMapSet = true
        config.tapButtonMap = parseInputButtonMap(child.args[0].kString())
      elif child.name == "drag":
        config.dragSet = true
        config.drag = child.childFlagEnabled()
      elif child.name == "drag-lock":
        config.dragLockSet = true
        config.dragLock = child.childFlagEnabled()
      elif child.name == "dwt":
        config.dwtSet = true
        config.dwt = child.childFlagEnabled()
      elif child.name == "dwtp":
        config.dwtpSet = true
        config.dwtp = child.childFlagEnabled()
      elif child.name == "click-method" and child.args.len > 0:
        config.clickMethodSet = true
        config.clickMethod = parseInputClickMethod(child.args[0].kString())
      elif child.name == "disabled-on-external-mouse":
        config.disabledOnExternalMouseSet = true
        config.disabledOnExternalMouse = child.childFlagEnabled()
    except CatchableError as e:
      warn "Ignoring invalid input touchpad field", field = child.name, error = e.msg

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
  if node.props.hasKey("at-startup"):
    result.atStartupSet = true
    result.atStartup = node.props["at-startup"].kBool()

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

proc axisDirectionValue(name: string): AxisBindingDirection =
  case name.toLowerAscii()
  of "wheel-up": AxisBindingDirection.AxisUp
  of "wheel-down": AxisBindingDirection.AxisDown
  of "wheel-left": AxisBindingDirection.AxisLeft
  of "wheel-right": AxisBindingDirection.AxisRight
  else: AxisBindingDirection.AxisNone

proc gestureDirectionValue(name: string): GestureBindingDirection =
  case name.toLowerAscii()
  of "swipe-left": GestureBindingDirection.GestureSwipeLeft
  of "swipe-right": GestureBindingDirection.GestureSwipeRight
  of "swipe-up": GestureBindingDirection.GestureSwipeUp
  of "swipe-down": GestureBindingDirection.GestureSwipeDown
  else: GestureBindingDirection.GestureNone

proc switchEventKindValue(name: string): SwitchEventKind =
  case name.toLowerAscii()
  of "lid-close": SwitchEventKind.SwitchLidClose
  of "lid-open": SwitchEventKind.SwitchLidOpen
  of "tablet-mode-on": SwitchEventKind.SwitchTabletModeOn
  of "tablet-mode-off": SwitchEventKind.SwitchTabletModeOff
  else: SwitchEventKind.SwitchNone

proc parseBindingMode(value: string): BindingMode =
  case value.normalize()
  of "normal": BindingMode.BindNormal
  of "overview": BindingMode.BindOverview
  of "recent": BindingMode.BindRecent
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

proc hasPhysicalKeySlot(
    bindings: seq[KeyBindingConfig], candidate: KeyBindingConfig
): bool =
  for binding in bindings:
    if binding.key.toLowerAscii() == candidate.key.toLowerAscii() and
        binding.modifiers == candidate.modifiers:
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
    key: "Question",
    modifiers: 64'u32,
    command: "toggle-hotkey-overlay",
    bypassShortcutsInhibit: true,
    hotkeyOverlayTitleKind: HotkeyOverlayTitleKind.HotkeyTitleCustom,
    hotkeyOverlayTitle: "Show Important Hotkeys",
  )

proc defaultRecentWindowBindings*(): seq[KeyBindingConfig] =
  @[
    KeyBindingConfig(
      key: "Tab",
      modifiers: 8'u32,
      command: "recent-window-next",
      mode: BindingMode.BindRecent,
    ),
    KeyBindingConfig(
      key: "Tab",
      modifiers: 9'u32,
      command: "recent-window-prev",
      mode: BindingMode.BindRecent,
    ),
    KeyBindingConfig(
      key: "grave",
      modifiers: 8'u32,
      command: "recent-window-next --filter app-id",
      mode: BindingMode.BindRecent,
    ),
    KeyBindingConfig(
      key: "grave",
      modifiers: 9'u32,
      command: "recent-window-prev --filter app-id",
      mode: BindingMode.BindRecent,
    ),
  ]

proc setJanetManifestAlias(
    aliases: var seq[JanetManifestAlias], appId, manifest: string
) =
  for alias in aliases.mitems:
    if alias.appId == appId:
      alias.manifest = manifest
      return
  aliases.add(JanetManifestAlias(appId: appId, manifest: manifest))

proc recentWindowFallbackBindings*(): seq[KeyBindingConfig] =
  @[
    KeyBindingConfig(
      key: "Escape", command: "recent-window-cancel", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "Return", command: "recent-window-confirm", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "Left", command: "recent-window-prev", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "Right", command: "recent-window-next", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "Home", command: "recent-window-first", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "End", command: "recent-window-last", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "a", command: "recent-window-scope all", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "w", command: "recent-window-scope workspace", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "o", command: "recent-window-scope output", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "s", command: "recent-window-cycle-scope", mode: BindingMode.BindRecent
    ),
    KeyBindingConfig(
      key: "q", command: "recent-window-close-current", mode: BindingMode.BindRecent
    ),
  ]

proc isRecentWindowCommand(command: string): bool =
  let parts = command.strip().splitWhitespace()
  parts.len > 0 and parts[0].startsWith("recent-window-")

proc addRecentWindowBindings(
    bindings: var seq[KeyBindingConfig], recent: seq[KeyBindingConfig]
) =
  for binding in recent:
    if not bindings.hasPhysicalKeySlot(binding):
      bindings.add(binding)
  for binding in recentWindowFallbackBindings():
    if not bindings.hasPhysicalKeySlot(binding):
      bindings.add(binding)

proc keyBindingFromNode(
    node: KdlNode, defaultMode = BindingMode.BindAlways
): Option[KeyBindingConfig] =
  if node.args.len < 2:
    return none(KeyBindingConfig)
  let spec = parseKeySpec(node.args[0].kString())
  if spec.key.len == 0:
    return none(KeyBindingConfig)
  var binding = KeyBindingConfig(
    key: spec.key,
    modifiers: spec.modifiers,
    command: node.args[1].kString(),
    mode: defaultMode,
  )
  if node.props.hasKey("layout"):
    let layout = node.props["layout"].kInt()
    if layout >= 0:
      binding.hasLayoutOverride = true
      binding.layoutOverride = uint32(layout)
  if node.props.hasKey("mode"):
    binding.mode = parseBindingMode(node.props["mode"].kString())
  if node.props.hasKey("allow-inhibiting"):
    binding.bypassShortcutsInhibit = not node.props["allow-inhibiting"].kBool()
  if node.props.hasKey("on-release"):
    binding.onRelease = node.props["on-release"].kBool()
  if node.props.hasKey("while-locked"):
    binding.whileLocked = node.props["while-locked"].kBool()
  if node.props.hasKey("hotkey-overlay-title"):
    binding.applyHotkeyOverlayTitle(node.props["hotkey-overlay-title"])
  some(binding)

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

proc setSwitchEvent(events: var seq[SwitchEventConfig], event: SwitchEventConfig) =
  for i, existing in events.mpairs:
    if existing.kind == event.kind:
      events[i] = event
      return
  events.add(event)

proc commandArgsFromNode(node: KdlNode): seq[string] =
  for arg in node.args:
    let value = arg.kString()
    if node.args.len == 1:
      for part in value.splitWhitespace():
        result.add(part)
    else:
      result.add(value)

proc parsePresentationMode(value: string): tuple[valid: bool, mode: PresentationMode] =
  case value.toLowerAscii()
  of "default":
    (true, PresentationMode.PresentationDefault)
  of "vsync":
    (true, PresentationMode.PresentationVsync)
  of "async":
    (true, PresentationMode.PresentationAsync)
  else:
    (false, PresentationMode.PresentationDefault)

proc parseOutputConfigTransform(
    value: string
): tuple[valid: bool, transform: OutputConfigTransform] =
  case value.toLowerAscii()
  of "normal":
    (true, OutputConfigTransform.OutputTransformNormal)
  of "90":
    (true, OutputConfigTransform.OutputTransform90)
  of "180":
    (true, OutputConfigTransform.OutputTransform180)
  of "270":
    (true, OutputConfigTransform.OutputTransform270)
  of "flipped":
    (true, OutputConfigTransform.OutputTransformFlipped)
  of "flipped-90":
    (true, OutputConfigTransform.OutputTransformFlipped90)
  of "flipped-180":
    (true, OutputConfigTransform.OutputTransformFlipped180)
  of "flipped-270":
    (true, OutputConfigTransform.OutputTransformFlipped270)
  else:
    (false, OutputConfigTransform.OutputTransformNormal)

proc outputModeRefreshMilliHz(value: KdlVal): int32 =
  var hz: float64
  try:
    hz = value.kFloat()
  except CatchableError:
    hz = float64(value.kInt())
  int32(max(0.0, hz * 1000.0 + 0.5))

proc parseIdleInhibitMode(
    value: string
): tuple[valid: bool, mode: WindowRuleIdleInhibitMode] =
  case value.toLowerAscii()
  of "none":
    (true, WindowRuleIdleInhibitMode.IdleInhibitNone)
  of "focused":
    (true, WindowRuleIdleInhibitMode.IdleInhibitFocused)
  of "visible":
    (true, WindowRuleIdleInhibitMode.IdleInhibitVisible)
  else:
    (false, WindowRuleIdleInhibitMode.IdleInhibitNone)

proc defaultKeyBindings*(): seq[KeyBindingConfig] =
  @[
    hotkeyOverlayFallbackBinding(),
    KeyBindingConfig(key: "q", modifiers: 64'u32, command: "close-window"),
    KeyBindingConfig(key: "f", modifiers: 64'u32, command: "maximize-window-to-edges"),
    KeyBindingConfig(key: "f", modifiers: 65'u32, command: "fullscreen-window"),
    KeyBindingConfig(key: "m", modifiers: 64'u32, command: "maximize-column"),
    KeyBindingConfig(key: "b", modifiers: 65'u32, command: "minimize"),
    KeyBindingConfig(key: "i", modifiers: 64'u32, command: "move-to-scratchpad"),
    KeyBindingConfig(key: "z", modifiers: 8'u32, command: "toggle-scratchpad"),
    KeyBindingConfig(key: "i", modifiers: 65'u32, command: "restore-scratchpad"),
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

proc loadConfig*(path: string): Config =
  var recentWindowBindings = defaultRecentWindowBindings()
  # Default values
  result.layout.gaps = DefaultGaps
  result.layout.centerFocusedColumn = DefaultCenterFocusedColumn
  result.layout.defaultColumnWidth = DefaultColumnWidth
  result.layout.scrollerProportionPresets =
    @[
      DefaultScrollerProportionPresetSmall, DefaultScrollerProportionPresetMedium,
      DefaultScrollerProportionPresetLarge, DefaultScrollerProportionPresetFull,
    ]
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
  result.layout.animationSnapThreshold = DefaultAnimationSnapThreshold
  result.layout.frameRate = DefaultFrameRate
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
  result.recentWindows.enabled = true
  result.recentWindows.debounceMs = DefaultRecentWindowsDebounceMs
  result.recentWindows.openDelayMs = DefaultRecentWindowsOpenDelayMs
  result.recentWindows.highlight.activeColor = DefaultRecentWindowsHighlightActiveColor
  result.recentWindows.highlight.urgentColor = DefaultRecentWindowsHighlightUrgentColor
  result.recentWindows.highlight.padding = DefaultRecentWindowsHighlightPadding
  result.recentWindows.highlight.cornerRadius =
    DefaultRecentWindowsHighlightCornerRadius
  result.recentWindows.previews.maxHeight = DefaultRecentWindowsPreviewMaxHeight
  result.recentWindows.previews.maxScale = DefaultRecentWindowsPreviewMaxScale
  result.layoutSwitchToast.enabled = true
  result.layoutSwitchToast.timeoutMs = DefaultLayoutSwitchToastTimeoutMs
  result.layoutSwitchToast.ringColor = DefaultLayoutSwitchToastRingColor
  result.floating.xRatio = DefaultFloatingXRatio
  result.floating.yRatio = DefaultFloatingYRatio
  result.floating.widthRatio = DefaultFloatingWidthRatio
  result.floating.heightRatio = DefaultFloatingHeightRatio
  result.floating.minWidth = DefaultFloatingMinWidth
  result.floating.minHeight = DefaultFloatingMinHeight
  result.quickshell.command = DefaultQuickshellCommand
  result.shells.watchdog.enabled = true
  result.shells.watchdog.exclusiveFocusTimeoutMs =
    DefaultShellWatchdogExclusiveFocusTimeoutMs
  result.janet.enabled = true
  result.janet.manifestDir = DefaultJanetManifestDir
  result.janet.systemManifestDir = DefaultJanetSystemManifestDir
  result.janet.hookDir = DefaultJanetHookDir
  result.janet.fuelLimit = DefaultJanetFuelLimit
  result.hotkeyOverlay.skipAtStartup = true
  result.hotkeyOverlay.position = HotkeyOverlayPosition.Top
  result.hotkeyOverlay.columns = 2
  result.screenshot.directory = DefaultScreenshotDirectory
  result.screenshot.filenamePrefix = DefaultScreenshotFilenamePrefix
  result.screenshot.captureCommand = DefaultScreenshotCaptureCommand
  result.screenshot.regionSelectorCommand = DefaultScreenshotRegionSelectorCommand
  result.screenshot.clipboardCommand = DefaultScreenshotClipboardCommand
  result.protocolSurfaces.enabled = true

  try:
    let doc = loadConfigDocument(path).nodes
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
            elif child.name == "scroller-proportion-presets":
              result.layout.scrollerProportionPresets = @[]
              for arg in child.args:
                result.layout.scrollerProportionPresets.add(
                  clampF32(float32(arg.kFloat()), 0.05, 1.0)
                )
            elif child.name == "enable-animations" and child.args.len > 0:
              result.layout.enableAnimations = child.args[0].kBool()
            elif child.name == "animation-speed" and child.args.len > 0:
              result.layout.animationSpeed =
                clampF32(float32(child.args[0].kFloat()), 0.0, 1.0)
            elif child.name == "animation-snap-threshold" and child.args.len > 0:
              result.layout.animationSnapThreshold =
                clampF32(float32(child.args[0].kFloat()), 0.01, 64.0)
            elif child.name == "frame-rate" and child.args.len > 0:
              if child.args[0].kind == KString and child.args[0].kString() == "auto":
                result.layout.frameRate = DefaultFrameRate
              else:
                result.layout.frameRate = runtimeFrameRate(int32(child.args[0].kInt()))
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
      elif node.name == "output" and node.args.len > 0:
        try:
          var rule = OutputRule(target: node.args[0].kString().strip())
          for child in node.children:
            try:
              if child.name == "focus-at-startup":
                rule.focusAtStartup = child.childFlagEnabled()
              elif child.name == "workspaces":
                rule.workspaceSlots = child.workspaceTargets()
              elif child.name == "mode" and child.args.len >= 3:
                rule.modeSet = true
                rule.modeWidth = clamp32(int32(child.args[0].kInt()), 1, 65535)
                rule.modeHeight = clamp32(int32(child.args[1].kInt()), 1, 65535)
                rule.modeRefresh = child.args[2].outputModeRefreshMilliHz()
              elif child.name == "scale" and child.args.len > 0:
                rule.scaleSet = true
                rule.scale = clampF32(float32(child.args[0].kFloat()), 0.01, 64.0)
              elif child.name == "position" and child.args.len >= 2:
                rule.positionSet = true
                rule.positionX = clamp32(int32(child.args[0].kInt()), -65535, 65535)
                rule.positionY = clamp32(int32(child.args[1].kInt()), -65535, 65535)
              elif child.name == "transform" and child.args.len > 0:
                let parsed = parseOutputConfigTransform(child.args[0].kString())
                if parsed.valid:
                  rule.transformSet = true
                  rule.transform = parsed.transform
                else:
                  warn "Ignoring invalid output transform",
                    target = rule.target, value = child.args[0].kString()
              elif child.name == "adaptive-sync" and child.args.len > 0:
                rule.adaptiveSyncSet = true
                rule.adaptiveSync = child.args[0].kBool()
              elif child.name == "enabled":
                warn "Ignoring unsupported output rule field",
                  field = child.name, reason = "output disabling is not supported"
              else:
                warn "Ignoring unsupported output rule field", field = child.name
            except CatchableError as e:
              warn "Ignoring invalid output rule field",
                field = child.name, error = e.msg
          if rule.target.len > 0:
            result.outputRules.add(rule)
        except CatchableError as e:
          warn "Ignoring invalid output rule", error = e.msg
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
              var openOnOutput = ""
              if child.props.hasKey("open-on-output"):
                openOnOutput = child.props["open-on-output"].kString().strip()
              result.tagRules.add(
                TagRule(
                  tagId: id,
                  defaultLayoutSet: layoutSet,
                  defaultLayout: layout,
                  name: tagName,
                  openOnOutput: openOnOutput,
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
                rule.defaultWorkspaces = @[rule.defaultWorkspace]
            elif child.name == "default-workspaces":
              let targets = child.workspaceTargets()
              rule.defaultWorkspaces = targets
              rule.defaultWorkspace =
                if targets.len > 0:
                  targets[0]
                else:
                  0'u32
            elif child.name == "open-on-output" and child.args.len > 0:
              rule.openOnOutput = child.args[0].kString().strip()
            elif child.name == "default-column-width":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.defaultColumnWidthSet = true
                rule.defaultColumnWidth = proportion.value
            elif child.name == "scroller-proportion":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.scrollerProportionSet = true
                rule.scrollerProportion = proportion.value
            elif child.name == "scroller-single-proportion":
              let proportion = child.proportionChild()
              if proportion.found:
                rule.scrollerSingleProportionSet = true
                rule.scrollerSingleProportion = proportion.value
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
            elif child.name == "open-on-all-workspaces" and child.args.len > 0:
              rule.openOnAllWorkspacesSet = true
              rule.openOnAllWorkspaces = child.args[0].kBool()
            elif child.name == "open-overlay" and child.args.len > 0:
              rule.openOverlaySet = true
              rule.openOverlay = child.args[0].kBool()
            elif child.name == "open-unmanaged-global" and child.args.len > 0:
              rule.openUnmanagedGlobalSet = true
              rule.openUnmanagedGlobal = child.args[0].kBool()
            elif child.name == "terminal" and child.args.len > 0:
              rule.terminalSet = true
              rule.terminal = child.args[0].kBool()
            elif child.name == "allow-swallow" and child.args.len > 0:
              rule.allowSwallowSet = true
              rule.allowSwallow = child.args[0].kBool()
            elif child.name == "maximize-policy" and child.args.len > 0:
              rule.maximizePolicySet = true
              rule.maximizePolicy = parseMaximizePolicy(child.args[0].kString())
            elif child.name == "respect-size-hints" and child.args.len > 0:
              rule.respectSizeHintsSet = true
              rule.respectSizeHints = child.args[0].kBool()
            elif child.name == "center-floating" and child.args.len > 0:
              rule.centerFloatingSet = true
              rule.centerFloating = child.args[0].kBool()
            elif child.name == "parented-role" and child.args.len > 0:
              rule.parentedRoleSet = true
              rule.parentedRole = parseParentedRole(child.args[0].kString())
            elif child.name == "open-named-scratchpad" and child.args.len > 0:
              rule.openNamedScratchpad = child.args[0].kString().strip()
            elif child.name == "default-floating-position":
              var position = WindowRuleFloatingPositionConfig(
                set: true, relativeTo: FloatingPositionAnchor.TopLeft
              )
              if child.props.hasKey("x"):
                position.x = clamp32(int32(child.props["x"].kInt()), -65535, 65535)
              if child.props.hasKey("y"):
                position.y = clamp32(int32(child.props["y"].kInt()), -65535, 65535)
              if child.props.hasKey("relative-to"):
                position.relativeTo =
                  parseFloatingPositionAnchor(child.props["relative-to"].kString())
              rule.defaultFloatingPosition = position
            elif child.name == "border":
              for borderChild in child.children:
                if borderChild.name == "width" and borderChild.args.len > 0:
                  rule.border.widthSet = true
                  rule.border.width = clamp32(int32(borderChild.args[0].kInt()), 0, 64)
                elif borderChild.name == "active-color" and borderChild.args.len > 0:
                  rule.border.activeColorSet = true
                  rule.border.activeColor =
                    parseColor(borderChild.args[0].kString(), rule.border.activeColor)
                elif borderChild.name == "inactive-color" and borderChild.args.len > 0:
                  rule.border.inactiveColorSet = true
                  rule.border.inactiveColor =
                    parseColor(borderChild.args[0].kString(), rule.border.inactiveColor)
            elif child.name == "focus-ring":
              for ringChild in child.children:
                if ringChild.name == "width" and ringChild.args.len > 0:
                  rule.focusRing.widthSet = true
                  rule.focusRing.width = clamp32(int32(ringChild.args[0].kInt()), 0, 64)
                elif ringChild.name == "active-color" and ringChild.args.len > 0:
                  rule.focusRing.activeColorSet = true
                  rule.focusRing.activeColor =
                    parseColor(ringChild.args[0].kString(), rule.focusRing.activeColor)
            elif child.name == "clip-to-geometry" and child.args.len > 0:
              rule.clipToGeometrySet = true
              rule.clipToGeometry = child.args[0].kBool()
            elif child.name == "dialog-viewport-jump" and child.args.len > 0:
              rule.dialogViewportJumpSet = true
              rule.dialogViewportJump = child.args[0].kBool()
            elif child.name == "keyboard-shortcuts-inhibit" and child.args.len > 0:
              rule.keyboardShortcutsInhibitSet = true
              rule.keyboardShortcutsInhibit = child.args[0].kBool()
            elif child.name == "idle-inhibit" and child.args.len > 0:
              let parsed = parseIdleInhibitMode(child.args[0].kString())
              if parsed.valid:
                rule.idleInhibitModeSet = true
                rule.idleInhibitMode = parsed.mode
              else:
                warn "Ignoring invalid window rule idle inhibit mode",
                  value = child.args[0].kString()
            elif child.name == "presentation-mode" and child.args.len > 0:
              let parsed = parsePresentationMode(child.args[0].kString())
              if parsed.valid:
                rule.presentationModeSet = true
                rule.presentationMode = parsed.mode
              else:
                warn "Ignoring invalid window rule presentation mode",
                  value = child.args[0].kString()
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
                  rule.floating.widthSet = false
                  rule.floating.widthRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.05, 1.0)
                elif floatingChild.name == "width" and floatingChild.args.len > 0:
                  rule.floating.widthSet = true
                  rule.floating.widthRatioSet = false
                  rule.floating.width =
                    clamp32(int32(floatingChild.args[0].kInt()), 1, 65535)
                elif floatingChild.name == "height-ratio" and floatingChild.args.len > 0:
                  rule.floating.heightRatioSet = true
                  rule.floating.heightSet = false
                  rule.floating.heightRatio =
                    clampF32(float32(floatingChild.args[0].kFloat()), 0.05, 1.0)
                elif floatingChild.name == "height" and floatingChild.args.len > 0:
                  rule.floating.heightSet = true
                  rule.floating.heightRatioSet = false
                  rule.floating.height =
                    clamp32(int32(floatingChild.args[0].kInt()), 1, 65535)
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
      elif node.name == "environment":
        for child in node.children:
          try:
            if not validEnvironmentName(child.name):
              warn "Ignoring invalid environment variable name", name = child.name
              continue
            if child.args.len == 0:
              continue
            let value = child.args[0]
            if value.kind == KNull:
              result.environment.add(
                EnvironmentEntryConfig(name: child.name, unset: true)
              )
            else:
              result.environment.add(
                EnvironmentEntryConfig(name: child.name, value: value.kString())
              )
          except CatchableError as e:
            warn "Ignoring invalid environment field", field = child.name, error = e.msg
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
              let binding = child.keyBindingFromNode()
              if binding.isSome:
                result.keyBindings.add(binding.get())
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
            elif child.name == "axis-bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              let direction = axisDirectionValue(spec.key)
              let command = child.args[1].kString()
              if direction != AxisBindingDirection.AxisNone and command.len > 0:
                var binding = AxisBindingConfig(
                  direction: direction,
                  modifiers: spec.modifiers,
                  command: command,
                  mode: BindingMode.BindAlways,
                )
                if child.props.hasKey("mode"):
                  binding.mode = parseBindingMode(child.props["mode"].kString())
                if child.props.hasKey("allow-inhibiting"):
                  binding.bypassShortcutsInhibit =
                    not child.props["allow-inhibiting"].kBool()
                result.axisBindings.add(binding)
            elif child.name == "gesture-bind" and child.args.len >= 2:
              let spec = parseKeySpec(child.args[0].kString())
              let direction = gestureDirectionValue(spec.key)
              let fingers =
                if child.props.hasKey("fingers"):
                  child.props["fingers"].kInt()
                else:
                  0
              let command = child.args[1].kString()
              if direction != GestureBindingDirection.GestureNone and fingers in 3 .. 4 and
                  command.len > 0:
                var binding = GestureBindingConfig(
                  direction: direction,
                  fingers: uint32(fingers),
                  modifiers: spec.modifiers,
                  command: command,
                  mode: BindingMode.BindAlways,
                )
                if child.props.hasKey("mode"):
                  binding.mode = parseBindingMode(child.props["mode"].kString())
                if child.props.hasKey("allow-inhibiting"):
                  binding.bypassShortcutsInhibit =
                    not child.props["allow-inhibiting"].kBool()
                result.gestureBindings.add(binding)
          except CatchableError as e:
            warn "Ignoring invalid binding config field",
              field = child.name, error = e.msg
        if result.mirrorHjklArrows:
          result.keyBindings.mirrorHjklArrowBindings()
      elif node.name == "switch-events":
        for child in node.children:
          try:
            let kind = switchEventKindValue(child.name)
            if kind == SwitchEventKind.SwitchNone:
              warn "Ignoring invalid switch event config field", field = child.name
              continue
            if child.args.len == 0:
              continue
            let command = child.args[0].kString()
            if command.len > 0:
              result.switchEvents.setSwitchEvent(
                SwitchEventConfig(kind: kind, command: command)
              )
          except CatchableError as e:
            warn "Ignoring invalid switch event config field",
              field = child.name, error = e.msg
      elif node.name == "shells":
        result.shells.configured = true
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.shells.enabled = child.args[0].kBool()
            elif child.name == "active" and child.args.len > 0:
              result.shells.active = child.args[0].kString()
            elif child.name == "cycle":
              result.shells.cycle = child.stringArgs()
            elif child.name == "watchdog":
              for watchdogChild in child.children:
                try:
                  if watchdogChild.name == "enabled" and watchdogChild.args.len > 0:
                    result.shells.watchdog.enabled = watchdogChild.args[0].kBool()
                  elif watchdogChild.name == "fallback" and watchdogChild.args.len > 0:
                    result.shells.watchdog.fallback = watchdogChild.args[0].kString()
                  elif watchdogChild.name == "exclusive-focus-timeout-ms" and
                      watchdogChild.args.len > 0:
                    result.shells.watchdog.exclusiveFocusTimeoutMs =
                      clamp32(int32(watchdogChild.args[0].kInt()), 0, 600000)
                except CatchableError as e:
                  warn "Ignoring invalid shell watchdog field",
                    field = watchdogChild.name, error = e.msg
            elif child.name == "profile" and child.args.len > 0:
              var profile = ShellProfileConfig(name: child.args[0].kString())
              for profileChild in child.children:
                try:
                  if profileChild.name == "launch":
                    profile.launch = profileChild.stringArgs()
                  elif profileChild.name == "stop":
                    profile.stop = profileChild.stringArgs()
                  elif profileChild.name == "niri-compat":
                    profile.niriCompat = profileChild.childFlagEnabled()
                except CatchableError as e:
                  warn "Ignoring invalid shell profile field",
                    profile = profile.name, field = profileChild.name, error = e.msg
              if profile.name.strip().len > 0 and profile.launch.len > 0:
                result.shells.profiles.add(profile)
          except CatchableError as e:
            warn "Ignoring invalid shells field", field = child.name, error = e.msg
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
      elif node.name == "janet":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.janet.enabled = child.args[0].kBool()
            elif child.name == "manifest-dir" and child.args.len > 0:
              result.janet.manifestDir = child.args[0].kString()
            elif child.name == "system-manifest-dir" and child.args.len > 0:
              result.janet.systemManifestDir = child.args[0].kString()
            elif child.name == "hook-dir" and child.args.len > 0:
              result.janet.hookDir = child.args[0].kString()
            elif child.name == "fuel-limit" and child.args.len > 0:
              result.janet.fuelLimit =
                clamp32(int32(child.args[0].kInt()), 1_000, 10_000_000)
            elif child.name == "manifest-alias" and child.args.len >= 2:
              result.janet.manifestAliases.setJanetManifestAlias(
                child.args[0].kString(), child.args[1].kString()
              )
          except CatchableError as e:
            warn "Ignoring invalid janet field", field = child.name, error = e.msg
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
            elif child.name == "tab-mode":
              result.overview.tabMode = child.childFlagEnabled()
            elif child.name == "scroller-indicators":
              result.overview.scrollerIndicators = child.childFlagEnabled()
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
      elif node.name == "recent-windows":
        for child in node.children:
          try:
            if child.name == "on":
              result.recentWindows.enabled = child.childFlagEnabled()
            elif child.name == "off":
              result.recentWindows.enabled = false
            elif child.name == "enabled" and child.args.len > 0:
              result.recentWindows.enabled = child.args[0].kBool()
            elif child.name == "debounce-ms" and child.args.len > 0:
              result.recentWindows.debounceMs =
                clamp32(int32(child.args[0].kInt()), 0, 60000)
            elif child.name == "open-delay-ms" and child.args.len > 0:
              result.recentWindows.openDelayMs =
                clamp32(int32(child.args[0].kInt()), 0, 60000)
            elif child.name == "highlight":
              for highlightChild in child.children:
                try:
                  if highlightChild.name == "active-color" and
                      highlightChild.args.len > 0:
                    result.recentWindows.highlight.activeColor = parseColor(
                      highlightChild.args[0].kString(),
                      result.recentWindows.highlight.activeColor,
                    )
                  elif highlightChild.name == "urgent-color" and
                      highlightChild.args.len > 0:
                    result.recentWindows.highlight.urgentColor = parseColor(
                      highlightChild.args[0].kString(),
                      result.recentWindows.highlight.urgentColor,
                    )
                  elif highlightChild.name == "padding" and highlightChild.args.len > 0:
                    result.recentWindows.highlight.padding =
                      clamp32(int32(highlightChild.args[0].kInt()), 0, 65535)
                  elif highlightChild.name == "corner-radius" and
                      highlightChild.args.len > 0:
                    result.recentWindows.highlight.cornerRadius =
                      clamp32(int32(highlightChild.args[0].kInt()), 0, 65535)
                except CatchableError as e:
                  warn "Ignoring invalid recent-windows highlight field",
                    field = highlightChild.name, error = e.msg
            elif child.name == "previews":
              for previewChild in child.children:
                try:
                  if previewChild.name == "max-height" and previewChild.args.len > 0:
                    result.recentWindows.previews.maxHeight =
                      clamp32(int32(previewChild.args[0].kInt()), 1, 65535)
                  elif previewChild.name == "max-scale" and previewChild.args.len > 0:
                    result.recentWindows.previews.maxScale =
                      clampF32(float32(previewChild.args[0].kFloat()), 0.01, 1.0)
                except CatchableError as e:
                  warn "Ignoring invalid recent-windows previews field",
                    field = previewChild.name, error = e.msg
            elif child.name == "binds":
              recentWindowBindings = @[]
              for bindChild in child.children:
                try:
                  if bindChild.name == "bind":
                    let binding = bindChild.keyBindingFromNode(BindingMode.BindRecent)
                    if binding.isSome and binding.get().command.isRecentWindowCommand():
                      recentWindowBindings.add(binding.get())
                except CatchableError as e:
                  warn "Ignoring invalid recent-windows bind",
                    field = bindChild.name, error = e.msg
          except CatchableError as e:
            warn "Ignoring invalid recent-windows field",
              field = child.name, error = e.msg
      elif node.name == "layout-switch-toast":
        for child in node.children:
          try:
            if child.name == "enabled" and child.args.len > 0:
              result.layoutSwitchToast.enabled = child.args[0].kBool()
            elif child.name == "timeout-ms" and child.args.len > 0:
              result.layoutSwitchToast.timeoutMs =
                clamp32(int32(child.args[0].kInt()), 0, 60000)
            elif child.name == "ring-color" and child.args.len > 0:
              result.layoutSwitchToast.ringColor =
                parseColor(child.args[0].kString(), result.layoutSwitchToast.ringColor)
          except CatchableError as e:
            warn "Ignoring invalid layout-switch-toast field",
              field = child.name, error = e.msg
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
      elif node.name == "input":
        for child in node.children:
          try:
            if child.name == "keyboard":
              result.input.keyboard.parseInputKeyboardConfig(child)
            elif child.name == "mouse":
              result.input.mouse.parseInputPointerConfig(child)
            elif child.name == "touchpad":
              result.input.touchpad.parseInputTouchpadConfig(child)
            elif child.name == "trackpoint":
              result.input.trackpoint.parseInputPointerConfig(child)
            elif child.name == "trackball":
              result.input.trackball.parseInputPointerConfig(child)
          except CatchableError as e:
            warn "Ignoring invalid input field", field = child.name, error = e.msg
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
            elif child.name == "hide-when-typing":
              result.cursor.hideWhenTyping = child.childFlagEnabled()
            elif child.name == "hide-after-inactive-ms" and child.args.len > 0:
              result.cursor.hideAfterInactiveMs =
                clamp32(int32(child.args[0].kInt()), 0, 3_600_000)
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
            elif child.name == "position" and child.args.len > 0:
              result.hotkeyOverlay.position =
                parseHotkeyOverlayPosition(child.args[0].kString())
            elif child.name == "columns" and child.args.len > 0:
              result.hotkeyOverlay.columns = clamp32(int32(child.args[0].kInt()), 1, 4)
          except CatchableError as e:
            warn "Ignoring invalid hotkey-overlay field",
              field = child.name, error = e.msg
      elif node.name == "config-notification":
        for child in node.children:
          try:
            let command = child.commandArgsFromNode()
            if command.len == 0:
              continue
            case child.name
            of "reload-succeeded":
              result.configNotification.reloadSucceeded = command
            of "reload-failed":
              result.configNotification.reloadFailed = command
            of "reload-rolled-back":
              result.configNotification.reloadRolledBack = command
            else:
              warn "Ignoring invalid config-notification field", field = child.name
          except CatchableError as e:
            warn "Ignoring invalid config-notification field",
              field = child.name, error = e.msg
      elif node.name == "presentation-mode" and node.args.len > 0:
        try:
          let parsed = parsePresentationMode(node.args[0].kString())
          if parsed.valid:
            result.presentationMode = parsed.mode
          else:
            warn "Ignoring invalid presentation mode", value = node.args[0].kString()
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
  if result.recentWindows.enabled:
    result.keyBindings.addRecentWindowBindings(recentWindowBindings)
  if result.pointerBindings.len == 0:
    result.pointerBindings = defaultPointerBindings()

proc loadConfigStrict*(path: string): ConfigLoadResult =
  var document: ConfigDocument
  try:
    document = loadConfigDocument(path)
  except CatchableError as e:
    return ConfigLoadResult(ok: false, error: e.msg)

  let config = loadConfig(path)
  let regexError = config.validateWindowRuleRegexes()
  if regexError.len > 0:
    return ConfigLoadResult(ok: false, error: regexError)

  result = ConfigLoadResult(ok: true, config: config, configPaths: document.paths)
