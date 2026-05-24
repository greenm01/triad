import std/[json, options, strutils]
import binding_dispatch
import command_registry

type SpecialMsgCommand* = object
  name*: string
  usage*: string
  description*: string

const SpecialMsgCommands* = [
  SpecialMsgCommand(
    name: "help",
    usage: "triad msg help [command]",
    description: "Print msg help, or detailed help for one command.",
  ),
  SpecialMsgCommand(
    name: "commands",
    usage: "triad msg commands [--json]",
    description: "List supported text commands and special msg requests.",
  ),
  SpecialMsgCommand(
    name: "validate",
    usage: "triad msg validate <command...>",
    description: "Parse a msg command or request locally without dispatching it.",
  ),
  SpecialMsgCommand(
    name: "request",
    usage: "triad msg request <json>",
    description: "Send one raw line-delimited IPC request and print the reply.",
  ),
  SpecialMsgCommand(
    name: "dispatch-binding",
    usage: "triad msg dispatch-binding key|pointer|axis|gesture <chord> [ticks|fingers]",
    description: "Dispatch a configured Triad binding without injecting raw input.",
  ),
  SpecialMsgCommand(
    name: "state",
    usage: "triad msg state",
    description: "Print native Triad shell state JSON.",
  ),
  SpecialMsgCommand(
    name: "capabilities",
    usage: "triad msg capabilities",
    description: "Print native Triad IPC feature capabilities JSON.",
  ),
  SpecialMsgCommand(
    name: "workspaces",
    usage: "triad msg workspaces",
    description: "Print native Triad workspace state JSON.",
  ),
  SpecialMsgCommand(
    name: "outputs",
    usage: "triad msg outputs",
    description: "Print native Triad output state JSON.",
  ),
  SpecialMsgCommand(
    name: "windows",
    usage: "triad msg windows",
    description: "Print native Triad window state JSON.",
  ),
  SpecialMsgCommand(
    name: "focused-window",
    usage: "triad msg focused-window",
    description: "Print native Triad focused window JSON.",
  ),
  SpecialMsgCommand(
    name: "overview-state",
    usage: "triad msg overview-state",
    description: "Print native Triad overview state JSON.",
  ),
  SpecialMsgCommand(
    name: "keyboard-layouts",
    usage: "triad msg keyboard-layouts",
    description: "Print native Triad keyboard layout state JSON.",
  ),
  SpecialMsgCommand(
    name: "layout-state",
    usage: "triad msg layout-state",
    description: "Print native Triad layout state JSON.",
  ),
  SpecialMsgCommand(
    name: "switch-layout",
    usage: "triad msg switch-layout",
    description:
      "Advance the active tag through the configured layout cycle and print ack.",
  ),
  SpecialMsgCommand(
    name: "event-stream",
    usage: "triad msg event-stream [--native [layout,state,window]]",
    description:
      "Subscribe to Niri-compatible events, or native Triad events with --native.",
  ),
  SpecialMsgCommand(
    name: "dev-mode",
    usage: "triad msg dev-mode [on|off|toggle|status]",
    description: "Show or change live daemon diagnostics mode.",
  ),
  SpecialMsgCommand(
    name: "perf-status",
    usage: "triad msg perf-status",
    description: "Print live daemon performance counters JSON.",
  ),
  SpecialMsgCommand(
    name: "mem-status",
    usage: "triad msg mem-status",
    description: "Print live daemon memory diagnostics JSON.",
  ),
  SpecialMsgCommand(
    name: "dump-live-restore-state",
    usage: "triad msg dump-live-restore-state",
    description: "Print the live-restore handoff snapshot JSON.",
  ),
]

proc argShapeId*(shape: CommandArgShape): string =
  case shape
  of CommandArgShape.NoArgs: "none"
  of CommandArgShape.OptionalWindowId: "optional-window-id"
  of CommandArgShape.RequiredWindowId: "required-window-id"
  of CommandArgShape.WindowTagFollow: "window-tag-follow"
  of CommandArgShape.WindowWorkspaceFollow: "window-workspace-follow"
  of CommandArgShape.WindowBool: "window-bool"
  of CommandArgShape.TagLayout: "tag-layout"
  of CommandArgShape.RequiredTag: "required-tag"
  of CommandArgShape.RequiredWorkspaceIdx: "required-workspace-idx"
  of CommandArgShape.RequiredName: "required-name"
  of CommandArgShape.RequiredOutput: "required-output"
  of CommandArgShape.RequiredFloatDelta: "required-float-delta"
  of CommandArgShape.RequiredFloatValue: "required-float-value"
  of CommandArgShape.RequiredIntCount: "required-int-count"
  of CommandArgShape.RequiredIntDelta: "required-int-delta"
  of CommandArgShape.OptionalIntDelta: "optional-int-delta"
  of CommandArgShape.MoveDelta: "move-delta"
  of CommandArgShape.ResizeDelta: "resize-delta"
  of CommandArgShape.RecentAdvance: "recent-advance"
  of CommandArgShape.RecentScope: "recent-scope"
  of CommandArgShape.SpawnArgv: "spawn-argv"
  of CommandArgShape.WarpPointer: "warp-pointer"
  of CommandArgShape.Screenshot: "screenshot"
  of CommandArgShape.SplitTreeModeList: "split-tree-mode-list"
  of CommandArgShape.OptionalFloatDelta: "optional-float-delta"
  of CommandArgShape.KeyboardLayoutTarget: "keyboard-layout-target"

proc argShapeUsage*(shape: CommandArgShape): string =
  case shape
  of CommandArgShape.NoArgs:
    ""
  of CommandArgShape.OptionalWindowId:
    "[window-id]"
  of CommandArgShape.RequiredWindowId:
    "<window-id>"
  of CommandArgShape.WindowTagFollow:
    "<window-id> <tag> [follow]"
  of CommandArgShape.WindowWorkspaceFollow:
    "<window-id> <workspace-idx> [follow]"
  of CommandArgShape.WindowBool:
    "<window-id> true|false"
  of CommandArgShape.TagLayout:
    "<tag> <layout>"
  of CommandArgShape.RequiredTag:
    "<tag>"
  of CommandArgShape.RequiredWorkspaceIdx:
    "<workspace-idx>"
  of CommandArgShape.RequiredName:
    "<name>"
  of CommandArgShape.RequiredOutput:
    "<output>"
  of CommandArgShape.RequiredFloatDelta:
    "<delta>"
  of CommandArgShape.RequiredFloatValue:
    "<value>"
  of CommandArgShape.RequiredIntCount:
    "<count>"
  of CommandArgShape.RequiredIntDelta:
    "<delta>"
  of CommandArgShape.OptionalIntDelta:
    "[delta]"
  of CommandArgShape.MoveDelta:
    "<dx> <dy>"
  of CommandArgShape.ResizeDelta:
    "<dw> <dh>"
  of CommandArgShape.RecentAdvance:
    "[--scope all|workspace|output] [--filter all|app-id]"
  of CommandArgShape.RecentScope:
    "all|workspace|output"
  of CommandArgShape.SpawnArgv:
    "<argv...>"
  of CommandArgShape.WarpPointer:
    "<x> <y>"
  of CommandArgShape.Screenshot:
    "[--path <path>] [--show-pointer|--hide-pointer] [--no-clipboard|--clipboard-only]"
  of CommandArgShape.SplitTreeModeList:
    "<split-h|split-v|stacking|tabbed>..."
  of CommandArgShape.OptionalFloatDelta:
    "[delta]"
  of CommandArgShape.KeyboardLayoutTarget:
    "[next|prev|index]"

proc aliasesSeq*(spec: CommandSpec): seq[string] =
  if spec.aliases.len == 0:
    return @[]
  spec.aliases.split('|')

proc commandUsage*(spec: CommandSpec): string =
  let args = spec.argShape.argShapeUsage()
  if args.len == 0:
    spec.name
  else:
    spec.name & " " & args

proc specialCommand*(name: string): Option[SpecialMsgCommand] =
  for command in SpecialMsgCommands:
    if command.name == name:
      return some(command)
  none(SpecialMsgCommand)

proc commandSpecJson*(spec: CommandSpec): JsonNode =
  result =
    %*{
      "name": spec.name,
      "usage": spec.commandUsage(),
      "arg_shape": spec.argShape.argShapeId(),
    }
  let aliases = newJArray()
  for alias in spec.aliasesSeq():
    aliases.add(%alias)
  result["aliases"] = aliases

proc commandCatalogJson*(): JsonNode =
  result = %*{"version": 1}
  let commands = newJArray()
  for spec in CommandSpecs:
    commands.add(spec.commandSpecJson())
  result["commands"] = commands
  let special = newJArray()
  for command in SpecialMsgCommands:
    special.add(
      %*{
        "name": command.name, "usage": command.usage, "description": command.description
      }
    )
  result["special_requests"] = special

proc renderCommandList*(): string =
  result = "Triad msg commands:\n"
  for spec in CommandSpecs:
    result.add("  ")
    result.add(spec.commandUsage())
    let aliases = spec.aliasesSeq()
    if aliases.len > 0:
      result.add("  (aliases: " & aliases.join(", ") & ")")
    result.add("\n")
  result.add("\nSpecial requests:\n")
  for command in SpecialMsgCommands:
    result.add("  ")
    result.add(command.usage)
    result.add("\n")

proc renderMsgHelp*(name = ""): string =
  if name.len > 0:
    let spec = resolveCommandSpec(name)
    if spec.isSome:
      result = "Usage: triad msg " & spec.get().commandUsage() & "\n"
      let aliases = spec.get().aliasesSeq()
      if aliases.len > 0:
        result.add("Aliases: " & aliases.join(", ") & "\n")
      result.add("Argument shape: " & spec.get().argShape.argShapeId() & "\n")
      return
    let special = specialCommand(name)
    if special.isSome:
      result = "Usage: " & special.get().usage & "\n"
      result.add(special.get().description & "\n")
      return
    return "Unknown triad msg command: " & name & "\n"

  result =
    """
Usage:
  triad msg <command> [arguments]
  triad msg help [command]
  triad msg commands [--json]
  triad msg validate <command...>
  triad msg request <json>
  triad msg dispatch-binding key|pointer|axis|gesture <chord> [ticks|fingers]

Useful request commands:
  triad msg state
  triad msg capabilities
  triad msg layout-state
  triad msg perf-status
  triad msg mem-status
  triad msg dev-mode [on|off|toggle|status]
  triad msg event-stream [--native [layout,state,window]]

"""
  result.add(renderCommandList())

proc renderTriadHelp*(): string =
  """
Usage:
  triad [--config <path>] [--dev-mode]
  triad session
  triad supervise
  triad logs [--json]
  triad validate-config [--config <path>]
  triad msg <command> [arguments]

Commands:
  session            Start a managed River/Triad login session.
  supervise          Supervise the live Triad daemon inside River.
  logs               Print the current session and daemon log paths.
  validate-config    Validate config without starting the daemon.
  msg                Send commands or requests to the running daemon.

Try:
  triad logs
  triad msg --help
  triad msg commands
  triad msg help focus-workspace
"""

proc triadRequestPayload*(request: string): string =
  $(%*{"triad": {"version": 1, "request": request}})

proc triadMsgRequestPayload*(cmd: string): Option[string] =
  let dispatch = parseBindingDispatchText(cmd)
  if dispatch.isSome:
    return some(bindingDispatchPayload(dispatch.get()))
  case cmd
  of "state":
    some(triadRequestPayload("state"))
  of "capabilities":
    some(triadRequestPayload("capabilities"))
  of "workspaces":
    some(triadRequestPayload("workspaces"))
  of "outputs":
    some(triadRequestPayload("outputs"))
  of "windows":
    some(triadRequestPayload("windows"))
  of "focused-window":
    some(triadRequestPayload("focused-window"))
  of "overview-state":
    some(triadRequestPayload("overview-state"))
  of "keyboard-layouts":
    some(triadRequestPayload("keyboard-layouts"))
  of "layout-state":
    some(triadRequestPayload("layout-state"))
  of "switch-layout":
    some(triadRequestPayload("switch-layout"))
  else:
    none(string)

proc nativeEventStreamPayload*(events: seq[string]): string =
  let eventList =
    if events.len == 0:
      @["layout", "state"]
    else:
      events
  $(%*{"triad": {"version": 1, "request": "event-stream", "events": eventList}})
