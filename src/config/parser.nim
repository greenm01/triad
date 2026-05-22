import std/[options, os, re, strutils]
import chronicles, kdl
import defaults
import keysyms
import ../core/layout_descriptor_codec
import ../core/layout_mode_codec
import ../core/native_layout_codec
import ../core/layout_selection_codec
import ../janet/bundled_layouts
import ../types/config_values
import ../types/runtime_values

export config_values

const MaxConfigIncludeDepth* = 10

proc clamp32(value, lo, hi: int32): int32 =
  min(hi, max(lo, value))

proc clampF32(value, lo, hi: float32): float32 =
  min(hi, max(lo, value))

proc defaultSpiralLayoutConfig(): SpiralLayoutConfig =
  SpiralLayoutConfig(
    ratio: DefaultSpiralRatio,
    mainPaneRatioSet: false,
    mainPaneRatio: DefaultSpiralMainPaneRatio,
    mainPane: DefaultSpiralMainPane,
    clockwiseSet: true,
    clockwise: DefaultSpiralClockwise,
  )

proc parseSpiralMainPane(value: string): string =
  if value in ["left", "top", "right", "bottom"]: value else: DefaultSpiralMainPane

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

proc parseOutputConfigTransform(
  value: string
): tuple[valid: bool, transform: OutputConfigTransform]

proc parseOutputModeString(
    value: string
): tuple[valid: bool, kind: OutputModeKind, width: int32, height: int32, refresh: int32] =
  let normalized = value.strip().toLowerAscii()
  case normalized
  of "preferred":
    return (true, OutputModeKind.OutputModePreferred, 0'i32, 0'i32, 0'i32)
  of "highres":
    return (true, OutputModeKind.OutputModeHighRes, 0'i32, 0'i32, 0'i32)
  of "highrr":
    return (true, OutputModeKind.OutputModeHighRr, 0'i32, 0'i32, 0'i32)
  of "maxwidth":
    return (true, OutputModeKind.OutputModeMaxWidth, 0'i32, 0'i32, 0'i32)

  let xPos = normalized.find('x')
  if xPos <= 0:
    return (false, OutputModeKind.OutputModeExplicit, 0'i32, 0'i32, 0'i32)
  let atPos = normalized.find('@')
  let widthText = normalized[0 ..< xPos]
  let heightText =
    if atPos > xPos:
      normalized[xPos + 1 ..< atPos]
    else:
      normalized[xPos + 1 ..^ 1]
  try:
    let width = parseInt(widthText)
    let height = parseInt(heightText)
    var refresh = 0'i32
    if atPos > xPos:
      refresh = int32(max(0.0, parseFloat(normalized[atPos + 1 ..^ 1]) * 1000.0 + 0.5))
    if width <= 0 or height <= 0 or refresh < 0:
      return (false, OutputModeKind.OutputModeExplicit, 0'i32, 0'i32, 0'i32)
    (true, OutputModeKind.OutputModeExplicit, int32(width), int32(height), refresh)
  except CatchableError:
    (false, OutputModeKind.OutputModeExplicit, 0'i32, 0'i32, 0'i32)

proc parseOutputPositionString(
    value: string
): tuple[valid: bool, kind: OutputPositionKind, x: int32, y: int32] =
  let normalized = value.strip().toLowerAscii()
  case normalized
  of "auto":
    return (true, OutputPositionKind.OutputPositionAuto, 0'i32, 0'i32)
  of "auto-right":
    return (true, OutputPositionKind.OutputPositionAutoRight, 0'i32, 0'i32)
  of "auto-left":
    return (true, OutputPositionKind.OutputPositionAutoLeft, 0'i32, 0'i32)
  of "auto-up":
    return (true, OutputPositionKind.OutputPositionAutoUp, 0'i32, 0'i32)
  of "auto-down":
    return (true, OutputPositionKind.OutputPositionAutoDown, 0'i32, 0'i32)
  of "auto-center-right":
    return (true, OutputPositionKind.OutputPositionAutoCenterRight, 0'i32, 0'i32)
  of "auto-center-left":
    return (true, OutputPositionKind.OutputPositionAutoCenterLeft, 0'i32, 0'i32)
  of "auto-center-up":
    return (true, OutputPositionKind.OutputPositionAutoCenterUp, 0'i32, 0'i32)
  of "auto-center-down":
    return (true, OutputPositionKind.OutputPositionAutoCenterDown, 0'i32, 0'i32)

  let xPos = normalized.find('x')
  if xPos <= 0:
    return (false, OutputPositionKind.OutputPositionExplicit, 0'i32, 0'i32)
  try:
    let x = parseInt(normalized[0 ..< xPos])
    let y = parseInt(normalized[xPos + 1 ..^ 1])
    (true, OutputPositionKind.OutputPositionExplicit, int32(x), int32(y))
  except CatchableError:
    (false, OutputPositionKind.OutputPositionExplicit, 0'i32, 0'i32)

proc parseOutputLayoutRowAlign(
    value: string
): tuple[valid: bool, align: OutputLayoutRowAlign] =
  case value.strip().toLowerAscii()
  of "left":
    (true, OutputLayoutRowAlign.Left)
  of "center":
    (true, OutputLayoutRowAlign.Center)
  of "right":
    (true, OutputLayoutRowAlign.Right)
  else:
    (false, OutputLayoutRowAlign.Center)

proc targetSeen(targets: openArray[string], target: string): bool =
  for existing in targets:
    if existing.cmpIgnoreCase(target) == 0:
      return true
  false

proc outputConfigError(target, field, message: string): string =
  if field.len > 0:
    "output \"" & target & "\" " & field & ": " & message
  else:
    "output \"" & target & "\": " & message

proc outputNodeError(index: int, message: string): string =
  "output[" & $index & "]: " & message

proc isIntegerValue(value: KdlVal): bool =
  value.kind in {KInt, KInt8, KInt16, KInt32, KInt64}

proc isNumberValue(value: KdlVal): bool =
  value.kind in {KInt, KInt8, KInt16, KInt32, KInt64, KFloat, KFloat32, KFloat64}

proc numberValue(value: KdlVal): float64 =
  if value.kind in {KFloat, KFloat32, KFloat64}:
    value.kFloat()
  else:
    float64(value.kInt())

proc outputFieldHasProps(target: string, child: KdlNode): string =
  if child.props.len > 0:
    result = outputConfigError(target, child.name, "properties are not supported")

proc outputFieldArgs(target: string, child: KdlNode, count: int): string =
  let propError = outputFieldHasProps(target, child)
  if propError.len > 0:
    return propError
  if child.args.len != count:
    result =
      outputConfigError(target, child.name, "expected " & $count & " argument(s)")

proc validateOutputFocusField(target: string, child: KdlNode): string =
  let propError = outputFieldHasProps(target, child)
  if propError.len > 0:
    return propError
  if child.args.len > 1:
    return outputConfigError(target, child.name, "expected a flag or bool")
  if child.args.len == 1 and child.args[0].kind != KBool:
    return outputConfigError(target, child.name, "expected a bool value")

proc validateOutputWorkspaceField(target: string, child: KdlNode): string =
  let propError = outputFieldHasProps(target, child)
  if propError.len > 0:
    return propError
  if child.args.len == 0:
    return outputConfigError(target, child.name, "expected at least one workspace id")
  for arg in child.args:
    if not arg.isIntegerValue():
      return outputConfigError(target, child.name, "workspace ids must be integers")
    if arg.kInt() <= 0:
      return outputConfigError(target, child.name, "workspace ids must be positive")

proc validateOutputModeField(target: string, child: KdlNode): string =
  let propError = outputFieldHasProps(target, child)
  if propError.len > 0:
    return propError
  if child.args.len == 1 and child.args[0].kind == KString:
    let parsed = parseOutputModeString(child.args[0].kString())
    if parsed.valid:
      return
    return outputConfigError(
      target, child.name,
      "expected preferred, highres, highrr, maxwidth, WxH, WxH@Hz, or W H Hz",
    )
  if child.args.len != 3:
    return outputConfigError(target, child.name, "expected 1 or 3 argument(s)")
  if not child.args[0].isIntegerValue() or not child.args[1].isIntegerValue():
    return outputConfigError(target, child.name, "width and height must be integers")
  if child.args[0].kInt() <= 0 or child.args[1].kInt() <= 0:
    return outputConfigError(target, child.name, "width and height must be positive")
  if not child.args[2].isNumberValue():
    return outputConfigError(target, child.name, "refresh must be numeric")
  if child.args[2].numberValue() <= 0.0:
    return outputConfigError(target, child.name, "refresh must be positive")

proc validateOutputScaleField(target: string, child: KdlNode): string =
  result = outputFieldArgs(target, child, 1)
  if result.len > 0:
    return
  if child.args[0].kind == KString and child.args[0].kString().cmpIgnoreCase("auto") == 0:
    return
  if not child.args[0].isNumberValue():
    return outputConfigError(target, child.name, "expected a numeric scale or auto")
  let scale = child.args[0].numberValue()
  if scale < 0.01 or scale > 64.0:
    return outputConfigError(target, child.name, "scale must be in range 0.01..64.0")

proc validateOutputPositionField(target: string, child: KdlNode): string =
  let propError = outputFieldHasProps(target, child)
  if propError.len > 0:
    return propError
  if child.args.len == 1 and child.args[0].kind == KString:
    let parsed = parseOutputPositionString(child.args[0].kString())
    if parsed.valid:
      return
    return outputConfigError(
      target, child.name, "expected XxY, auto, or auto-{right,left,up,down}"
    )
  if child.args.len != 2:
    return outputConfigError(target, child.name, "expected 1 or 2 argument(s)")
  if not child.args[0].isIntegerValue() or not child.args[1].isIntegerValue():
    return outputConfigError(target, child.name, "x and y must be integers")

proc validateOutputLayoutRow(
    row: KdlNode, context: string, targets: var seq[string]
): string =
  if row.args.len == 0:
    return context & ": expected at least one output target"
  for arg in row.args:
    if arg.kind != KString:
      return context & ": output targets must be strings"
    let target = arg.kString().strip()
    if target.len == 0:
      return context & ": output targets must not be empty"
    if targets.targetSeen(target):
      return context & ": duplicate output target \"" & target & "\""
    targets.add(target)
  for key, value in row.props.pairs:
    case key
    of "align":
      if value.kind != KString:
        return context & " align: expected left, center, or right"
      if not parseOutputLayoutRowAlign(value.kString()).valid:
        return context & " align: expected left, center, or right"
    else:
      return context & ": unknown property \"" & key & "\""

proc validateOutputLayoutNode(node: KdlNode, index: int): string =
  var targets: seq[string]
  if node.args.len > 0 and node.children.len > 0:
    return
      outputNodeError(index, "layout: expected arguments or row children, not both")
  if node.args.len > 0:
    if node.props.len > 0:
      return outputNodeError(index, "layout: properties are not supported")
    return validateOutputLayoutRow(node, "output[" & $index & "] layout", targets)
  if node.children.len == 0:
    return outputNodeError(index, "layout: expected at least one row")
  if node.props.len > 0:
    return outputNodeError(index, "layout: properties are not supported")
  var rowIndex = 0
  for child in node.children:
    if child.name != "row":
      return outputNodeError(index, "layout: unknown child \"" & child.name & "\"")
    result = validateOutputLayoutRow(
      child, "output[" & $index & "] layout row[" & $rowIndex & "]", targets
    )
    if result.len > 0:
      return
    inc rowIndex

proc validateOutputTransformField(target: string, child: KdlNode): string =
  result = outputFieldArgs(target, child, 1)
  if result.len > 0:
    return
  if child.args[0].isIntegerValue():
    let value = child.args[0].kInt()
    if value >= 0 and value <= 7:
      return
    return outputConfigError(target, child.name, "integer transform must be 0..7")
  if child.args[0].kind != KString:
    return outputConfigError(target, child.name, "expected a transform string or 0..7")
  let parsed = parseOutputConfigTransform(child.args[0].kString())
  if not parsed.valid:
    return outputConfigError(
      target, child.name,
      "expected one of normal, 90, 180, 270, flipped, flipped-90, flipped-180, flipped-270",
    )

proc validateOutputAdaptiveSyncField(target: string, child: KdlNode): string =
  result = outputFieldArgs(target, child, 1)
  if result.len > 0:
    return
  if child.args[0].kind != KBool:
    return outputConfigError(target, child.name, "expected a bool value")

proc validateOutputEnabledField(target: string, child: KdlNode): string =
  result = outputFieldArgs(target, child, 1)
  if result.len > 0:
    return
  if child.args[0].kind != KBool:
    return outputConfigError(target, child.name, "expected a bool value")

proc validateOutputVrrField(target: string, child: KdlNode): string =
  result = outputFieldArgs(target, child, 1)
  if result.len > 0:
    return
  if not child.args[0].isIntegerValue():
    return outputConfigError(target, child.name, "expected an integer mode 0..3")
  let value = child.args[0].kInt()
  if value < 0 or value > 3:
    return outputConfigError(target, child.name, "expected an integer mode 0..3")

proc validateOutputReservedAreaField(target: string, child: KdlNode): string =
  for key, value in child.props.pairs:
    if key notin ["top", "right", "bottom", "left"]:
      return outputConfigError(target, child.name, "unknown property " & key)
    if not value.isIntegerValue() or value.kInt() < 0:
      return outputConfigError(
        target, child.name, "reserved area values must be non-negative integers"
      )

  if child.props.len > 0:
    if child.args.len > 0:
      return outputConfigError(
        target, child.name, "expected properties or arguments, not both"
      )
    return

  if child.args.len notin [1, 4]:
    return outputConfigError(target, child.name, "expected 1 or 4 argument(s)")
  for arg in child.args:
    if not arg.isIntegerValue() or arg.kInt() < 0:
      return outputConfigError(
        target, child.name, "reserved area values must be non-negative integers"
      )

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

proc builtinLayoutSelection(mode: LayoutMode): LayoutSelection =
  LayoutSelection(kind: LayoutSelectionKind.Builtin, builtin: mode)

proc customLayoutSelection(
    id: JanetLayoutId, fallback: LayoutSelection
): LayoutSelection =
  customSelection(id, fallback)

proc nativeLayoutSelection(
    id: NativeLayoutId, fallback: LayoutSelection
): LayoutSelection =
  LayoutSelection(
    kind: LayoutSelectionKind.Native, builtin: fallback.builtin, nativeId: id
  )

proc customLayoutById(
    layouts: openArray[JanetLayoutConfig], id: JanetLayoutId
): Option[JanetLayoutConfig] =
  for layout in layouts:
    if layout.id.layoutIdString() == id.layoutIdString():
      return some(layout)
  none(JanetLayoutConfig)

proc parseLayoutSelectionName(
    name: string, layouts: openArray[JanetLayoutConfig], fallback: LayoutSelection
): LayoutSelection =
  let builtin = parseCoreLayoutModeId(name)
  if builtin.isSome:
    return builtinLayoutSelection(builtin.get())

  let id = janetLayoutId(name)
  let custom = layouts.customLayoutById(id)
  if custom.isSome:
    return customLayoutSelection(id, custom.get().fallback)

  let native = parseNativeLayoutId(name)
  if native.isSome:
    return nativeLayoutSelection(native.get().id, native.get().fallback)

  fallback

proc parseFallbackLayoutSelectionName(name: string): LayoutSelection =
  let builtin = parseCoreLayoutModeId(name)
  if builtin.isSome:
    return builtinLayoutSelection(builtin.get())
  let native = parseNativeLayoutId(name)
  if native.isSome:
    return nativeLayoutSelection(native.get().id, native.get().fallback)
  builtinLayoutSelection(LayoutMode.Scroller)

proc collectJanetLayoutDeclarations(doc: KdlDoc): seq[JanetLayoutConfig] =
  for node in doc:
    if node.name != "janet":
      continue
    for child in node.children:
      if child.name != "layout" or child.args.len == 0:
        continue
      try:
        let name = child.args[0].kString().strip()
        if name.len == 0:
          continue
        if parseLayoutModeId(name).isSome or parseNativeLayoutId(name).isSome or
            name.isBundledLayoutId():
          warn "Ignoring janet layout with reserved layout id", layout = name
          continue
        let id = janetLayoutId(name)
        if result.customLayoutById(id).isSome:
          warn "Ignoring duplicate janet layout declaration", layout = name
          continue
        let fallbackName =
          if child.props.hasKey("fallback"):
            child.props["fallback"].kString()
          else:
            "scroller"
        result.add(
          JanetLayoutConfig(
            id: id, fallback: parseFallbackLayoutSelectionName(fallbackName)
          )
        )
      except CatchableError as e:
        warn "Ignoring invalid janet layout declaration", error = e.msg

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

proc parseModifiers*(value: string): uint32 =
  for part in value.split("+"):
    result = result or modifierValue(part.strip())

proc buttonValue*(name: string): uint32 =
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

proc parseKeySpec*(value: string): tuple[key: string, modifiers: uint32] =
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

proc validateOutputRuleFields(target: string, node: KdlNode): string =
  var enabledSet = false
  var enabled = true
  var disabledSet = false
  var disabled = false
  for child in node.children:
    if target.len == 0 and child.name in ["focus-at-startup", "workspaces"]:
      return outputConfigError(
        target, child.name, "fallback output rules cannot set workspace or focus fields"
      )
    case child.name
    of "focus-at-startup":
      result = validateOutputFocusField(target, child)
    of "workspaces":
      result = validateOutputWorkspaceField(target, child)
    of "mode":
      result = validateOutputModeField(target, child)
    of "scale":
      result = validateOutputScaleField(target, child)
    of "position":
      result = validateOutputPositionField(target, child)
    of "transform":
      result = validateOutputTransformField(target, child)
    of "adaptive-sync":
      result = validateOutputAdaptiveSyncField(target, child)
    of "enabled":
      result = validateOutputEnabledField(target, child)
      if result.len == 0:
        enabledSet = true
        enabled = child.args[0].kBool()
    of "disabled":
      result = validateOutputEnabledField(target, child)
      if result.len == 0:
        disabledSet = true
        disabled = child.args[0].kBool()
    of "vrr":
      result = validateOutputVrrField(target, child)
    of "reserved", "reserved_area", "reserved-area", "addreserved":
      result = validateOutputReservedAreaField(target, child)
    of "mirror", "auto", "auto-position", "custom", "modeline", "bitdepth", "cm",
        "sdr_eotf", "sdr-eotf", "sdrbrightness", "sdrsaturation", "icc",
        "supports_wide_color", "supports-wide-color", "supports_hdr", "supports-hdr",
        "sdr_min_luminance", "sdr-min-luminance", "sdr_max_luminance",
        "sdr-max-luminance", "min_luminance", "min-luminance", "max_luminance",
        "max-luminance", "max_avg_luminance", "max-avg-luminance":
      result = outputConfigError(
        target, child.name, "field is not supported by Triad output rules"
      )
    else:
      result = outputConfigError(target, child.name, "unknown field")
    if result.len > 0:
      return

  if enabledSet and disabledSet and enabled == disabled:
    return outputConfigError(
      target, "enabled", "enabled and disabled fields request contradictory states"
    )

proc validateOutputGroupChild(target: string, child: KdlNode): string =
  if child.props.len > 0:
    return outputConfigError(target, "", child.name & ": properties are not supported")
  result = validateOutputRuleFields(target, child)

proc validateOutputRuleNode(node: KdlNode, index: int): string =
  if node.props.len > 0:
    return outputNodeError(index, "properties are not supported")
  if node.args.len == 1:
    if node.args[0].kind != KString:
      return outputNodeError(index, "output target must be a string")
    return validateOutputRuleFields(node.args[0].kString().strip(), node)

  if node.args.len > 1:
    return outputNodeError(index, "expected zero or one output target")

  var monitorIndex = 0
  var defaultSeen = false
  var layoutTargets: seq[string]
  var layoutCount = 0
  for child in node.children:
    if child.name == "layout":
      inc layoutCount
      if layoutCount > 1:
        return outputNodeError(index, "layout is duplicated")
      result = validateOutputLayoutNode(child, index)
      if result.len > 0:
        return
      if child.args.len > 0:
        for arg in child.args:
          layoutTargets.add(arg.kString().strip())
      else:
        for row in child.children:
          for arg in row.args:
            layoutTargets.add(arg.kString().strip())

  for child in node.children:
    case child.name
    of "monitor":
      if child.args.len != 1:
        return outputNodeError(
          index, "monitor[" & $monitorIndex & "]: expected exactly one output target"
        )
      if child.args[0].kind != KString:
        return outputNodeError(
          index, "monitor[" & $monitorIndex & "]: output target must be a string"
        )
      let target = child.args[0].kString().strip()
      if layoutTargets.targetSeen(target):
        for ruleChild in child.children:
          if ruleChild.name == "position":
            return outputConfigError(
              target, "position", "cannot be set for an output listed in output layout"
            )
      result = validateOutputGroupChild(target, child)
      if result.len > 0:
        return
      inc monitorIndex
    of "layout":
      discard
    of "default":
      if defaultSeen:
        return outputNodeError(index, "default output rule is duplicated")
      if child.args.len != 0:
        return outputNodeError(index, "default: expected no arguments")
      result = validateOutputGroupChild("", child)
      if result.len > 0:
        return
      defaultSeen = true
    else:
      return
        outputNodeError(index, "unknown grouped output child \"" & child.name & "\"")

proc validateOutputRuleNodes(doc: KdlDoc): string =
  var outputIndex = 0
  for node in doc:
    if node.name == "output":
      result = validateOutputRuleNode(node, outputIndex)
      if result.len > 0:
        return
      inc outputIndex

proc parsePointerOp(value: string): PointerOpKind =
  case value
  of "move", "Move": PointerOpKind.OpMove
  of "resize", "Resize": PointerOpKind.OpResize
  else: PointerOpKind.OpNone

proc axisDirectionValue*(name: string): AxisBindingDirection =
  case name.toLowerAscii()
  of "wheel-up": AxisBindingDirection.AxisUp
  of "wheel-down": AxisBindingDirection.AxisDown
  of "wheel-left": AxisBindingDirection.AxisLeft
  of "wheel-right": AxisBindingDirection.AxisRight
  else: AxisBindingDirection.AxisNone

proc gestureDirectionValue*(name: string): GestureBindingDirection =
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
    a.mode == b.mode and a.layoutScope == b.layoutScope

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
        binding.modifiers == candidate.modifiers and
        binding.layoutScope == candidate.layoutScope:
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

proc canonicalLayoutScope(value: string): string =
  let stripped = value.strip()
  let native = parseNativeLayoutId(stripped)
  if native.isSome:
    native.get().id.nativeLayoutIdString()
  else:
    stripped

proc keyBindingFromNode(
    node: KdlNode, defaultMode = BindingMode.BindAlways, layoutScope = ""
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
    layoutScope: layoutScope,
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
  of "normal", "0":
    (true, OutputConfigTransform.OutputTransformNormal)
  of "90", "1":
    (true, OutputConfigTransform.OutputTransform90)
  of "180", "2":
    (true, OutputConfigTransform.OutputTransform180)
  of "270", "3":
    (true, OutputConfigTransform.OutputTransform270)
  of "flipped", "4":
    (true, OutputConfigTransform.OutputTransformFlipped)
  of "flipped-90", "5":
    (true, OutputConfigTransform.OutputTransformFlipped90)
  of "flipped-180", "6":
    (true, OutputConfigTransform.OutputTransformFlipped180)
  of "flipped-270", "7":
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

proc parseOutputLayoutRowNode(node: KdlNode): OutputLayoutRowConfig =
  result.align = OutputLayoutRowAlign.Center
  if node.props.hasKey("align"):
    let parsed = parseOutputLayoutRowAlign(node.props["align"].kString())
    if parsed.valid:
      result.align = parsed.align
  for arg in node.args:
    let target = arg.kString().strip()
    if target.len > 0 and not result.targets.targetSeen(target):
      result.targets.add(target)

proc parseOutputLayoutNode(node: KdlNode): seq[OutputLayoutRowConfig] =
  if node.args.len > 0:
    result.add(node.parseOutputLayoutRowNode())
  else:
    for child in node.children:
      if child.name == "row":
        let row = child.parseOutputLayoutRowNode()
        if row.targets.len > 0:
          result.add(row)

proc parseOutputRuleNode(node: KdlNode, target: string): OutputRule =
  result = OutputRule(target: target.strip())
  for child in node.children:
    try:
      if child.name == "focus-at-startup":
        result.focusAtStartup = child.childFlagEnabled()
      elif child.name == "workspaces":
        result.workspaceSlots = child.workspaceTargets()
      elif child.name == "mode" and child.args.len > 0:
        if child.args.len == 1 and child.args[0].kind == KString:
          let parsed = parseOutputModeString(child.args[0].kString())
          if parsed.valid:
            result.modeSet = true
            result.modeKind = parsed.kind
            result.modeCustomAllowed = parsed.kind == OutputModeKind.OutputModeExplicit
            result.modeWidth = parsed.width
            result.modeHeight = parsed.height
            result.modeRefresh = parsed.refresh
        elif child.args.len >= 3:
          result.modeSet = true
          result.modeKind = OutputModeKind.OutputModeExplicit
          result.modeWidth = clamp32(int32(child.args[0].kInt()), 1, 65535)
          result.modeHeight = clamp32(int32(child.args[1].kInt()), 1, 65535)
          result.modeRefresh = child.args[2].outputModeRefreshMilliHz()
      elif child.name == "scale" and child.args.len > 0:
        if child.args[0].kind == KString and
            child.args[0].kString().cmpIgnoreCase("auto") == 0:
          result.scaleSet = true
          result.scaleAuto = true
        else:
          result.scaleSet = true
          result.scale = clampF32(float32(child.args[0].kFloat()), 0.01, 64.0)
      elif child.name == "position" and child.args.len >= 2:
        result.positionSet = true
        result.positionKind = OutputPositionKind.OutputPositionExplicit
        result.positionX = clamp32(int32(child.args[0].kInt()), -65535, 65535)
        result.positionY = clamp32(int32(child.args[1].kInt()), -65535, 65535)
      elif child.name == "position" and child.args.len == 1 and
          child.args[0].kind == KString:
        let parsed = parseOutputPositionString(child.args[0].kString())
        if parsed.valid:
          result.positionSet = true
          result.positionKind = parsed.kind
          result.positionX = clamp32(parsed.x, -65535, 65535)
          result.positionY = clamp32(parsed.y, -65535, 65535)
      elif child.name == "transform" and child.args.len > 0:
        let transformValue =
          if child.args[0].isIntegerValue():
            $child.args[0].kInt()
          else:
            child.args[0].kString()
        let parsed = parseOutputConfigTransform(transformValue)
        if parsed.valid:
          result.transformSet = true
          result.transform = parsed.transform
        else:
          warn "Ignoring invalid output transform",
            target = result.target, value = transformValue
      elif child.name == "adaptive-sync" and child.args.len > 0:
        result.adaptiveSyncSet = true
        result.adaptiveSync = child.args[0].kBool()
      elif child.name == "enabled":
        result.enabledSet = true
        result.enabled = child.args[0].kBool()
      elif child.name == "disabled":
        result.enabledSet = true
        result.enabled = not child.args[0].kBool()
      elif child.name == "vrr" and child.args.len > 0:
        result.adaptiveSyncSet = true
        result.adaptiveSync = child.args[0].kInt() != 0
      elif child.name in ["reserved", "reserved_area", "reserved-area", "addreserved"]:
        result.reservedAreaSet = true
        if child.props.len > 0:
          if child.props.hasKey("top"):
            result.reservedTop = int32(child.props["top"].kInt())
          if child.props.hasKey("right"):
            result.reservedRight = int32(child.props["right"].kInt())
          if child.props.hasKey("bottom"):
            result.reservedBottom = int32(child.props["bottom"].kInt())
          if child.props.hasKey("left"):
            result.reservedLeft = int32(child.props["left"].kInt())
        elif child.args.len == 1:
          let inset = int32(child.args[0].kInt())
          result.reservedTop = inset
          result.reservedRight = inset
          result.reservedBottom = inset
          result.reservedLeft = inset
        elif child.args.len >= 4:
          result.reservedTop = int32(child.args[0].kInt())
          result.reservedRight = int32(child.args[1].kInt())
          result.reservedBottom = int32(child.args[2].kInt())
          result.reservedLeft = int32(child.args[3].kInt())
      else:
        warn "Ignoring unsupported output rule field", field = child.name
    except CatchableError as e:
      warn "Ignoring invalid output rule field", field = child.name, error = e.msg

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
    KeyBindingConfig(key: "s", modifiers: 64'u32, command: "move-to-scratchpad"),
    KeyBindingConfig(key: "s", modifiers: 72'u32, command: "toggle-scratchpad"),
    KeyBindingConfig(key: "s", modifiers: 65'u32, command: "restore-scratchpad"),
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
    KeyBindingConfig(key: "n", modifiers: 65'u32, command: "new-workspace"),
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

proc loadConfigNodes*(doc: KdlDoc, path = ""): Config =
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
  result.layout.defaultFrameSplitRatio = DefaultFrameSplitRatio
  result.layout.spiral = defaultSpiralLayoutConfig()
  result.layout.borderWidth = DefaultBorderWidth
  result.layout.focusedBorderColor = DefaultFocusedBorderColor
  result.layout.unfocusedBorderColor = DefaultUnfocusedBorderColor
  result.layout.frameTabs.activeColor = DefaultFrameTabActiveColor
  result.layout.frameTabs.activeUnfocusedColor = DefaultFrameTabActiveUnfocusedColor
  result.layout.frameTabs.inactiveColor = DefaultFrameTabInactiveColor
  result.layout.frameTabs.activeLineColor = DefaultFrameTabActiveLineColor
  result.layout.frameTabs.activeUnfocusedLineColor =
    DefaultFrameTabActiveUnfocusedLineColor
  result.layout.frameTabs.emptyBackgroundColor = DefaultFrameEmptyBackgroundColor
  result.layout.scrollerFocusCenter = false
  result.layout.scrollerPreferCenter = false
  result.layout.enableAnimations = true
  result.layout.animationSpeed = DefaultAnimationSpeed
  result.layout.animationSnapThreshold = DefaultAnimationSnapThreshold
  result.layout.frameRate = DefaultFrameRate
  result.layout.smartGaps = false
  result.layout.layoutCycle =
    @[
      LayoutMode.Scroller, LayoutMode.Scroller, LayoutMode.Scroller,
      LayoutMode.Scroller, LayoutMode.VerticalScroller,
    ]
  result.layout.layoutSelections =
    @[
      builtinLayoutSelection(LayoutMode.Scroller),
      customSelection(janetLayoutId("tile"), LayoutMode.Scroller),
      customSelection(janetLayoutId("grid"), LayoutMode.Scroller),
      customSelection(janetLayoutId("monocle"), LayoutMode.Scroller),
      builtinLayoutSelection(LayoutMode.VerticalScroller),
    ]
  result.workspaces.defaultCount = DefaultWorkspaceCount
  result.workspaces.defaultLayout = LayoutMode.Scroller
  result.workspaces.defaultLayoutSelection = builtinLayoutSelection(LayoutMode.Scroller)
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
  result.janet.automationDir = DefaultJanetAutomationDir
  result.janet.layoutDir = DefaultJanetLayoutDir
  result.janet.fuelLimit = DefaultJanetFuelLimit
  result.janet.layouts = collectJanetLayoutDeclarations(doc)
  let availableJanetLayouts = bundledLayoutConfigs() & result.janet.layouts
  var janetAutomationDirSet = false
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
            elif child.name == "spiral":
              for spiralChild in child.children:
                try:
                  if spiralChild.name == "ratio" and spiralChild.args.len > 0:
                    result.layout.spiral.ratio =
                      clampF32(float32(spiralChild.args[0].kFloat()), 0.05, 0.95)
                  elif spiralChild.name == "main-pane-ratio" and spiralChild.args.len > 0:
                    result.layout.spiral.mainPaneRatioSet = true
                    result.layout.spiral.mainPaneRatio =
                      clampF32(float32(spiralChild.args[0].kFloat()), 0.05, 0.95)
                  elif spiralChild.name == "main-pane" and spiralChild.args.len > 0:
                    result.layout.spiral.mainPane =
                      parseSpiralMainPane(spiralChild.args[0].kString())
                  elif spiralChild.name == "clockwise" and spiralChild.args.len > 0:
                    result.layout.spiral.clockwiseSet = true
                    result.layout.spiral.clockwise = spiralChild.args[0].kBool()
                except CatchableError as e:
                  warn "Ignoring invalid spiral config field",
                    field = spiralChild.name, error = e.msg
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
            elif child.name == "initial-split-ratio" and child.args.len > 0:
              result.layout.defaultFrameSplitRatio =
                clampF32(float32(child.args[0].kFloat()), 0.05, 0.95)
            elif child.name == "frame-tabs":
              for tabChild in child.children:
                try:
                  if tabChild.name == "active-color" and tabChild.args.len > 0:
                    result.layout.frameTabs.activeColor = parseColor(
                      tabChild.args[0].kString(), result.layout.frameTabs.activeColor
                    )
                  elif tabChild.name == "active-unfocused-color" and
                      tabChild.args.len > 0:
                    result.layout.frameTabs.activeUnfocusedColor = parseColor(
                      tabChild.args[0].kString(),
                      result.layout.frameTabs.activeUnfocusedColor,
                    )
                  elif tabChild.name == "inactive-color" and tabChild.args.len > 0:
                    result.layout.frameTabs.inactiveColor = parseColor(
                      tabChild.args[0].kString(), result.layout.frameTabs.inactiveColor
                    )
                  elif tabChild.name == "active-line-color" and tabChild.args.len > 0:
                    result.layout.frameTabs.activeLineColor = parseColor(
                      tabChild.args[0].kString(),
                      result.layout.frameTabs.activeLineColor,
                    )
                  elif tabChild.name == "active-unfocused-line-color" and
                      tabChild.args.len > 0:
                    result.layout.frameTabs.activeUnfocusedLineColor = parseColor(
                      tabChild.args[0].kString(),
                      result.layout.frameTabs.activeUnfocusedLineColor,
                    )
                  elif tabChild.name == "empty-background-color" and
                      tabChild.args.len > 0:
                    result.layout.frameTabs.emptyBackgroundColor = parseColor(
                      tabChild.args[0].kString(),
                      result.layout.frameTabs.emptyBackgroundColor,
                    )
                except CatchableError as e:
                  warn "Ignoring invalid frame-tabs config field",
                    field = tabChild.name, error = e.msg
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
              result.layout.layoutSelections = @[]
              for arg in child.args:
                let selection = parseLayoutSelectionName(
                  arg.kString(),
                  availableJanetLayouts,
                  builtinLayoutSelection(LayoutMode.Scroller),
                )
                result.layout.layoutSelections.add(selection)
                result.layout.layoutCycle.add(selection.builtin)
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
              let fallback = result.workspaces.defaultLayoutSelection
              let selection = parseLayoutSelectionName(
                child.args[0].kString(), availableJanetLayouts, fallback
              )
              result.workspaces.defaultLayoutSelection = selection
              result.workspaces.defaultLayout = selection.builtin
          except CatchableError as e:
            warn "Ignoring invalid workspace config field",
              field = child.name, error = e.msg
      elif node.name == "output":
        try:
          if node.args.len > 0:
            result.outputRules.add(node.parseOutputRuleNode(node.args[0].kString()))
          else:
            for child in node.children:
              if child.name == "layout":
                for row in child.parseOutputLayoutNode():
                  result.outputLayoutRows.add(row)
              elif child.name == "monitor" and child.args.len > 0:
                result.outputRules.add(
                  child.parseOutputRuleNode(child.args[0].kString())
                )
              elif child.name == "default":
                result.outputRules.add(child.parseOutputRuleNode(""))
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
              var layoutSelection = result.workspaces.defaultLayoutSelection
              var layoutSet = false
              var tagName = ""
              if child.props.hasKey("name"):
                tagName = child.props["name"].kString()
              if child.props.hasKey("default-layout"):
                layoutSet = true
                layoutSelection = parseLayoutSelectionName(
                  child.props["default-layout"].kString(),
                  availableJanetLayouts,
                  layoutSelection,
                )
                layout = layoutSelection.builtin
              var openOnOutput = ""
              if child.props.hasKey("open-on-output"):
                openOnOutput = child.props["open-on-output"].kString().strip()
              result.tagRules.add(
                TagRule(
                  tagId: id,
                  defaultLayoutSet: layoutSet,
                  defaultLayout: layout,
                  defaultLayoutSelection: layoutSelection,
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
            elif child.name == "layout" and child.args.len >= 1:
              let layoutScope = canonicalLayoutScope(child.args[0].kString())
              if layoutScope.len == 0:
                continue
              for scopedChild in child.children:
                try:
                  if scopedChild.name == "bind" and scopedChild.args.len >= 2:
                    let binding = scopedChild.keyBindingFromNode(
                      BindingMode.BindNormal, layoutScope
                    )
                    if binding.isSome:
                      result.keyBindings.add(binding.get())
                except CatchableError as e:
                  warn "Ignoring invalid layout binding config field",
                    layout = layoutScope, field = scopedChild.name, error = e.msg
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
            elif child.name == "automation-dir" and child.args.len > 0:
              if result.janet.scriptDir.strip().len > 0:
                warn "Ignoring deprecated janet script-dir because automation-dir is set"
              result.janet.automationDir = child.args[0].kString()
              janetAutomationDirSet = true
            elif child.name == "layout-dir" and child.args.len > 0:
              result.janet.layoutDir = child.args[0].kString()
            elif child.name == "script-dir" and child.args.len > 0:
              result.janet.scriptDir = child.args[0].kString()
              if janetAutomationDirSet:
                warn "Ignoring deprecated janet script-dir because automation-dir is set"
              else:
                result.janet.automationDir = result.janet.scriptDir
            elif child.name == "fuel-limit" and child.args.len > 0:
              result.janet.fuelLimit =
                clamp32(int32(child.args[0].kInt()), 1_000, 10_000_000)
            elif child.name == "layout":
              discard
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

proc loadConfig*(path: string): Config =
  try:
    result = loadConfigNodes(loadConfigDocument(path).nodes, path)
  except:
    let e = getCurrentException()
    warn "Could not load config, using defaults", path = path, error = e.msg
    result = loadConfigNodes(@[], path)

proc loadFallbackConfig*(): Config =
  loadConfigNodes(parseKdl(FallbackConfigContent), "<builtin fallback>")

proc loadConfigStrict*(path: string): ConfigLoadResult =
  var document: ConfigDocument
  try:
    document = loadConfigDocument(path)
  except CatchableError as e:
    return ConfigLoadResult(ok: false, error: e.msg)

  let outputError = validateOutputRuleNodes(document.nodes)
  if outputError.len > 0:
    return ConfigLoadResult(ok: false, error: outputError)

  let config = loadConfigNodes(document.nodes, path)
  let regexError = config.validateWindowRuleRegexes()
  if regexError.len > 0:
    return ConfigLoadResult(ok: false, error: regexError)

  result = ConfigLoadResult(ok: true, config: config, configPaths: document.paths)
