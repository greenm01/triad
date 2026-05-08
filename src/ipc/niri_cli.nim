import json, options, strutils

type
  NiriCliKind* = enum
    NckInvalid,
    NckValidate,
    NckRequest

  NiriCliRequest* = object
    kind*: NiriCliKind
    jsonOutput*: bool
    socketPayload*: string
    unwrapKey*: string
    error*: string

proc intArg(arg: string): Option[int] =
  try:
    let value = parseInt(arg)
    if value > 0:
      return some(value)
  except CatchableError:
    discard
  none(int)

proc optionValue(args: seq[string]; name: string): Option[string] =
  for i in 0 ..< args.len:
    if args[i] == name and i + 1 < args.len:
      return some(args[i + 1])
  none(string)

proc requestName(command: string): Option[string] =
  case command.normalize()
  of "outputs":
    some("Outputs")
  of "workspaces":
    some("Workspaces")
  of "windows":
    some("Windows")
  of "focusedwindow", "focused-window":
    some("FocusedWindow")
  of "overviewstate", "overview-state":
    some("OverviewState")
  of "keyboardlayouts", "keyboard-layouts":
    some("KeyboardLayouts")
  else:
    none(string)

proc actionPayload(args: seq[string]): Option[JsonNode] =
  if args.len == 0:
    return none(JsonNode)

  case args[0].normalize()
  of "focusworkspace", "focus-workspace":
    if args.len < 2:
      return none(JsonNode)
    let idx = intArg(args[1])
    if idx.isSome:
      return some(%*{"Action": {"FocusWorkspace": {"reference": {"Index": idx.get()}}}})
  of "focusworkspaceup", "focus-workspace-up":
    return some(%*{"Action": {"FocusWorkspaceUp": {}}})
  of "focusworkspacedown", "focus-workspace-down":
    return some(%*{"Action": {"FocusWorkspaceDown": {}}})
  of "focuscolumnleft", "focus-column-left":
    return some(%*{"Action": {"FocusColumnLeft": {}}})
  of "focuscolumnright", "focus-column-right":
    return some(%*{"Action": {"FocusColumnRight": {}}})
  of "toggleoverview", "toggle-overview":
    return some(%*{"Action": {"ToggleOverview": {}}})
  of "focuswindow", "focus-window":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"FocusWindow": {"id": win.get()}}})
  of "closewindow", "close-window":
    let id = optionValue(args, "--id")
    if id.isSome:
      let win = intArg(id.get())
      if win.isSome:
        return some(%*{"Action": {"CloseWindow": {"id": win.get()}}})
    return some(%*{"Action": {"CloseWindow": {}}})
  of "poweroffmonitors", "power-off-monitors":
    return some(%*{"Action": {"PowerOffMonitors": {}}})
  of "poweronmonitors", "power-on-monitors":
    return some(%*{"Action": {"PowerOnMonitors": {}}})
  of "switchlayout", "switch-layout":
    let layout = if args.len >= 2 and args[1].normalize() == "next": "Next" else: "Prev"
    return some(%*{"Action": {"SwitchLayout": {"layout": layout}}})
  of "quit":
    return some(%*{"Action": {"Quit": {"skip_confirmation": args.contains("--skip-confirmation")}}})
  of "screenshot":
    return some(%*{"Action": {"Screenshot": {"path": optionValue(args, "--path").get("")}}})
  of "screenshotscreen", "screenshot-screen":
    return some(%*{"Action": {"ScreenshotScreen": {"path": optionValue(args, "--path").get("")}}})
  of "screenshotwindow", "screenshot-window":
    return some(%*{"Action": {"ScreenshotWindow": {"path": optionValue(args, "--path").get("")}}})
  else:
    discard

  none(JsonNode)

proc buildNiriCliRequest*(args: seq[string]): NiriCliRequest =
  if args.len == 0:
    return NiriCliRequest(kind: NckInvalid, error: "missing command")

  if args[0] == "validate":
    return NiriCliRequest(kind: NckValidate)

  if args[0] != "msg":
    return NiriCliRequest(kind: NckInvalid, error: "unsupported niri command: " & args[0])

  var jsonOutput = false
  var msgArgs: seq[string] = @[]
  for i in 1 ..< args.len:
    case args[i]
    of "-j", "--json":
      jsonOutput = true
    else:
      msgArgs.add(args[i])

  if msgArgs.len == 0:
    return NiriCliRequest(kind: NckInvalid, error: "missing niri msg request")

  if msgArgs[0] == "action":
    let actionArgs = if msgArgs.len > 1: msgArgs[1..^1] else: @[]
    let payload = actionPayload(actionArgs)
    if payload.isNone:
      return NiriCliRequest(kind: NckInvalid, error: "unsupported niri action")
    return NiriCliRequest(kind: NckRequest, jsonOutput: jsonOutput, socketPayload: $payload.get())

  let req = requestName(msgArgs[0])
  if req.isNone:
    return NiriCliRequest(kind: NckInvalid, error: "unsupported niri msg request: " & msgArgs[0])

  NiriCliRequest(
    kind: NckRequest,
    jsonOutput: jsonOutput,
    socketPayload: "\"" & req.get() & "\"",
    unwrapKey: req.get()
  )

proc unwrapNiriReply*(reply: string; unwrapKey: string): tuple[ok: bool, output: string] =
  try:
    let parsed = parseJson(reply)
    if parsed.kind == JObject and parsed.hasKey("Err"):
      return (false, parsed["Err"].getStr())
    if parsed.kind == JObject and parsed.hasKey("Ok"):
      let ok = parsed["Ok"]
      if unwrapKey.len > 0 and ok.kind == JObject and ok.hasKey(unwrapKey):
        return (true, $ok[unwrapKey])
      return (true, $ok)
  except CatchableError as e:
    return (false, "invalid socket reply: " & e.msg)

  (false, "invalid socket reply")
