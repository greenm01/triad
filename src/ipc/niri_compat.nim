import std/[json, options, strutils]
import ../core/[msg, niri_state]
import ../types/shell_snapshot
from ../types/runtime_values import Direction

type NiriIpcResult* = object
  handled*: bool
  subscribe*: bool
  requestKind*: string
  requestName*: string
  actionName*: string
  error*: string
  workspaceIndex*: uint32
  workspaceId*: uint32
  windowId*: uint32
  reply*: string
  initialEvents*: seq[string]
  messages*: seq[Msg]

proc okReply(payload: JsonNode): string =
  $(%*{"Ok": payload})

proc handledReply(): string =
  $(%*{"Ok": "Handled"})

proc errReply(message: string): string =
  $(%*{"Err": message})

proc uintFromNode(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() > 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc uintFromNodeAllowZero(node: JsonNode): Option[uint32] =
  try:
    if node.kind == JInt and node.getInt() >= 0 and node.getInt() <= int(high(uint32)):
      return some(uint32(node.getInt()))
  except CatchableError:
    discard
  none(uint32)

proc boolFromNode(node: JsonNode, fallback = false): bool =
  try:
    if node.kind == JBool:
      return node.getBool()
  except CatchableError:
    discard
  fallback

proc stringFromField(node: JsonNode, field: string): string =
  if node.kind == JObject and node.hasKey(field) and node[field].kind == JString:
    node[field].getStr()
  else:
    ""

proc stringSeqFromNode(node: JsonNode): seq[string] =
  if node.kind != JArray:
    return @[]
  for item in node:
    if item.kind != JString:
      return @[]
    result.add(item.getStr())

proc firstObjectKey(node: JsonNode): string =
  if node.kind != JObject:
    return ""
  for key, _ in node.pairs:
    return key
  ""

proc recordNiriActionDetails(ipc: var NiriIpcResult, action: JsonNode) =
  ipc.actionName = action.firstObjectKey()
  if ipc.actionName.len == 0 or action.kind != JObject:
    return

  let payload = action[ipc.actionName]
  case ipc.actionName
  of "FocusWorkspace":
    if payload.kind == JObject and payload.hasKey("reference") and
        payload["reference"].kind == JObject:
      let refNode = payload["reference"]
      if refNode.hasKey("Index"):
        let index = uintFromNode(refNode["Index"])
        if index.isSome:
          ipc.workspaceIndex = index.get()
      elif refNode.hasKey("Id"):
        let tag = uintFromNode(refNode["Id"])
        if tag.isSome:
          ipc.workspaceId = tag.get()
  of "FocusWindow", "CloseWindow", "FullscreenWindow", "MaximizeWindowToEdges",
      "ToggleWindowFloating", "MoveWindowToFloating", "MoveWindowToTiling":
    if payload.kind == JObject and payload.hasKey("id") and payload["id"].kind != JNull:
      let win = uintFromNode(payload["id"])
      if win.isSome:
        ipc.windowId = win.get()
  of "MoveWorkspaceToIndex":
    if payload.kind == JObject and payload.hasKey("index"):
      let index = uintFromNode(payload["index"])
      if index.isSome:
        ipc.workspaceIndex = index.get()
  else:
    discard

proc boolFromField(node: JsonNode, field: string, fallback = false): bool =
  if node.kind == JObject and node.hasKey(field):
    boolFromNode(node[field], fallback)
  else:
    fallback

proc boolFromEitherField(node: JsonNode, snake, kebab: string, fallback = false): bool =
  boolFromField(node, snake, boolFromField(node, kebab, fallback))

proc pointerMode(showPointer: bool): ScreenshotPointerMode =
  if showPointer:
    ScreenshotPointerMode.PointerShow
  else:
    ScreenshotPointerMode.PointerHide

proc focusedWindow(snapshot: ShellSnapshot): uint32 =
  if snapshot.activeScratchpadWindow != 0'u32:
    return snapshot.activeScratchpadWindow
  for workspace in snapshot.workspaces:
    if workspace.isActive and workspace.focusedWindow != 0:
      return workspace.focusedWindow
  for win in snapshot.windows:
    if win.isFocused:
      return win.id
  0'u32

proc windowById(snapshot: ShellSnapshot, winId: uint32): Option[ShellWindow] =
  for win in snapshot.windows:
    if win.id == winId:
      return some(win)
  none(ShellWindow)

proc workspaceById(
    snapshot: ShellSnapshot, workspaceId: uint32
): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.tagId == workspaceId:
      return some(workspace)
  none(ShellWorkspace)

proc workspaceByIndex(
    snapshot: ShellSnapshot, workspaceIndex: uint32
): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.workspaceIdx == workspaceIndex:
      return some(workspace)
  none(ShellWorkspace)

proc workspaceByName(snapshot: ShellSnapshot, name: string): Option[ShellWorkspace] =
  if name.len == 0:
    return none(ShellWorkspace)
  for workspace in snapshot.workspaces:
    if workspace.name == name:
      return some(workspace)
  none(ShellWorkspace)

proc activeWorkspace(snapshot: ShellSnapshot): Option[ShellWorkspace] =
  for workspace in snapshot.workspaces:
    if workspace.isActive:
      return some(workspace)
  none(ShellWorkspace)

proc workspaceReference(
    snapshot: ShellSnapshot, reference: JsonNode
): Option[ShellWorkspace] =
  if reference.kind != JObject:
    return none(ShellWorkspace)
  if reference.hasKey("Index"):
    let index = uintFromNode(reference["Index"])
    if index.isSome:
      return snapshot.workspaceByIndex(index.get())
  elif reference.hasKey("Id"):
    let id = uintFromNode(reference["Id"])
    if id.isSome:
      return snapshot.workspaceById(id.get())
  elif reference.hasKey("Name") and reference["Name"].kind == JString:
    return snapshot.workspaceByName(reference["Name"].getStr())
  none(ShellWorkspace)

proc requestedWindow(
    snapshot: ShellSnapshot, payload: JsonNode, field = "id"
): tuple[specified, valid: bool, id: uint32] =
  if payload.kind != JObject:
    return (false, false, 0'u32)
  if not payload.hasKey(field) or payload[field].kind == JNull:
    return (false, true, 0'u32)
  let id = uintFromNode(payload[field])
  if id.isNone or snapshot.windowById(id.get()).isNone:
    return (true, false, 0'u32)
  (true, true, id.get())

proc toggleMaximizeMessage(snapshot: ShellSnapshot, winId: uint32): Option[Msg] =
  if winId == 0'u32:
    return none(Msg)
  let win = snapshot.windowById(winId)
  if win.isNone:
    return none(Msg)
  if win.get().isMaximized:
    return
      some(Msg(kind: MsgKind.WlWindowUnmaximizeRequested, unmaximizeRequestId: winId))
  some(Msg(kind: MsgKind.WlWindowMaximizeRequested, maximizeRequestId: winId))

proc switchKeyboardLayoutMessage(payload: JsonNode): Msg =
  var layout = newJNull()
  if payload.kind == JObject and payload.hasKey("layout"):
    layout = payload["layout"]
  if layout.kind == JString:
    case layout.getStr().normalize()
    of "next":
      return Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: 1,
        keyboardLayoutIndex: -1,
      )
    of "prev", "previous":
      return Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: -1,
        keyboardLayoutIndex: -1,
      )
    else:
      discard
  elif layout.kind == JObject and layout.hasKey("Index"):
    let index = uintFromNodeAllowZero(layout["Index"])
    if index.isSome:
      return Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout, keyboardLayoutIndex: int32(index.get())
      )
  Msg(
    kind: MsgKind.CmdSwitchKeyboardLayout,
    keyboardLayoutDelta: 1,
    keyboardLayoutIndex: -1,
  )

proc actionMessages(
    action: JsonNode, snapshot: ShellSnapshot
): tuple[handled: bool, messages: seq[Msg]] =
  if action.kind != JObject:
    return (false, @[])

  if action.hasKey("FocusWorkspace"):
    let payload = action["FocusWorkspace"]
    if payload.kind == JObject and payload.hasKey("reference"):
      let refNode = payload["reference"]
      if refNode.kind == JObject:
        if refNode.hasKey("Index"):
          let index = uintFromNode(refNode["Index"])
          if index.isSome:
            return (
              true,
              @[Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: index.get())],
            )
        elif refNode.hasKey("Id"):
          let workspace = snapshot.workspaceReference(refNode)
          if workspace.isSome:
            return
              (true, @[Msg(kind: MsgKind.CmdFocusTag, focusTag: workspace.get().tagId)])
        elif refNode.hasKey("Name"):
          let workspace = snapshot.workspaceReference(refNode)
          if workspace.isSome:
            return
              (true, @[Msg(kind: MsgKind.CmdFocusTag, focusTag: workspace.get().tagId)])
  elif action.hasKey("FocusWorkspaceDown"):
    return (true, @[Msg(kind: MsgKind.CmdFocusTagRight)])
  elif action.hasKey("FocusWorkspaceUp"):
    return (true, @[Msg(kind: MsgKind.CmdFocusTagLeft)])
  elif action.hasKey("FocusMonitor"):
    let payload = action["FocusMonitor"]
    let output = stringFromField(payload, "output")
    if output.len > 0:
      return (true, @[Msg(kind: MsgKind.CmdFocusOutput, outputTarget: output)])
  elif action.hasKey("ToggleOverview"):
    return (true, @[Msg(kind: MsgKind.CmdToggleOverview)])
  elif action.hasKey("OpenOverview"):
    return (true, @[Msg(kind: MsgKind.CmdOpenOverview)])
  elif action.hasKey("CloseOverview"):
    return (true, @[Msg(kind: MsgKind.CmdCloseOverview)])
  elif action.hasKey("ToggleKeyboardShortcutsInhibit"):
    return (true, @[Msg(kind: MsgKind.CmdToggleKeyboardShortcutsInhibit)])
  elif action.hasKey("FocusColumnLeft"):
    return (true, @[Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft)])
  elif action.hasKey("FocusColumnRight"):
    return
      (true, @[Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)])
  elif action.hasKey("FocusColumnFirst"):
    return (true, @[Msg(kind: MsgKind.CmdFocusColumnFirst)])
  elif action.hasKey("FocusColumnLast"):
    return (true, @[Msg(kind: MsgKind.CmdFocusColumnLast)])
  elif action.hasKey("FocusWindowUp"):
    return (true, @[Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)])
  elif action.hasKey("FocusWindowDown"):
    return (true, @[Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)])
  elif action.hasKey("FocusWindowOrWorkspaceUp"):
    return (true, @[Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp)])
  elif action.hasKey("FocusWindowOrWorkspaceDown"):
    return (true, @[Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown)])
  elif action.hasKey("MoveColumnLeft"):
    return (true, @[Msg(kind: MsgKind.CmdMoveColumnLeft)])
  elif action.hasKey("MoveColumnRight"):
    return (true, @[Msg(kind: MsgKind.CmdMoveColumnRight)])
  elif action.hasKey("MoveColumnToFirst"):
    return (true, @[Msg(kind: MsgKind.CmdMoveColumnToFirst)])
  elif action.hasKey("MoveColumnToLast"):
    return (true, @[Msg(kind: MsgKind.CmdMoveColumnToLast)])
  elif action.hasKey("MoveWindowUp"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowUp)])
  elif action.hasKey("MoveWindowDown"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowDown)])
  elif action.hasKey("MoveWindowUpOrToWorkspaceUp"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp)])
  elif action.hasKey("MoveWindowDownOrToWorkspaceDown"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown)])
  elif action.hasKey("MoveWindowLeft"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowLeft)])
  elif action.hasKey("MoveWindowRight"):
    return (true, @[Msg(kind: MsgKind.CmdMoveWindowRight)])
  elif action.hasKey("MoveWindowToWorkspace"):
    let payload = action["MoveWindowToWorkspace"]
    if payload.kind == JObject and payload.hasKey("reference"):
      let workspace = snapshot.workspaceReference(payload["reference"])
      let target = snapshot.requestedWindow(payload, "window_id")
      if workspace.isSome and target.valid:
        let windowId =
          if target.specified:
            target.id
          else:
            snapshot.focusedWindow()
        if windowId != 0'u32 and snapshot.windowById(windowId).isSome:
          return (
            true,
            @[
              Msg(
                kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
                moveWorkspaceWindowId: windowId,
                moveWorkspaceIndex: workspace.get().workspaceIdx,
                moveWorkspaceFollowWindow: boolFromField(payload, "focus", true),
              )
            ],
          )
  elif action.hasKey("MoveWindowToMonitor"):
    let payload = action["MoveWindowToMonitor"]
    let target = snapshot.requestedWindow(payload)
    let output = stringFromField(payload, "output")
    if target.valid and output.len > 0:
      let focused = snapshot.focusedWindow()
      if not target.specified or target.id == focused:
        return (true, @[Msg(kind: MsgKind.CmdMoveToOutput, outputTarget: output)])
  elif action.hasKey("MoveWorkspaceToMonitor"):
    let payload = action["MoveWorkspaceToMonitor"]
    let output = stringFromField(payload, "output")
    let requested =
      if payload.kind == JObject and payload.hasKey("reference") and
          payload["reference"].kind != JNull:
        snapshot.workspaceReference(payload["reference"])
      else:
        snapshot.activeWorkspace()
    let active = snapshot.activeWorkspace()
    if output.len > 0 and requested.isSome and active.isSome and
        requested.get().tagId == active.get().tagId:
      return
        (true, @[Msg(kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: output)])
  elif action.hasKey("FocusWindow"):
    let payload = action["FocusWindow"]
    let target = snapshot.requestedWindow(payload)
    if target.specified and target.valid:
      return (true, @[Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: target.id)])
  elif action.hasKey("CloseWindow"):
    let payload = action["CloseWindow"]
    let target = snapshot.requestedWindow(payload)
    if not target.valid:
      return (false, @[])
    if target.specified:
      return (true, @[Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: target.id)])
    if payload.kind == JObject:
      return (true, @[Msg(kind: MsgKind.CmdCloseWindow)])
  elif action.hasKey("SwitchLayout"):
    return (true, @[switchKeyboardLayoutMessage(action["SwitchLayout"])])
  elif action.hasKey("Spawn"):
    let payload = action["Spawn"]
    if payload.kind == JObject and payload.hasKey("command"):
      let command = stringSeqFromNode(payload["command"])
      if command.len > 0:
        return (true, @[Msg(kind: MsgKind.CmdSpawn, spawnCommand: command)])
    return (false, @[])
  elif action.hasKey("SpawnSh"):
    let command = stringFromField(action["SpawnSh"], "command")
    if command.len > 0:
      return
        (true, @[Msg(kind: MsgKind.CmdSpawn, spawnCommand: @["sh", "-c", command])])
    return (false, @[])
  elif action.hasKey("SetWorkspaceName"):
    let payload = action["SetWorkspaceName"]
    if payload.kind != JObject or
        (payload.hasKey("workspace") and payload["workspace"].kind != JNull):
      return (false, @[])
    return (
      true,
      @[Msg(kind: MsgKind.CmdRenameTag, newName: stringFromField(payload, "name"))],
    )
  elif action.hasKey("UnsetWorkspaceName"):
    let payload = action["UnsetWorkspaceName"]
    if payload.kind != JObject or
        (payload.hasKey("workspace") and payload["workspace"].kind != JNull):
      return (false, @[])
    return (true, @[Msg(kind: MsgKind.CmdRenameTag, newName: "")])
  elif action.hasKey("MoveWorkspaceToIndex"):
    let payload = action["MoveWorkspaceToIndex"]
    if payload.kind == JObject and payload.hasKey("index"):
      let target = uintFromNode(payload["index"])
      let source =
        if payload.hasKey("reference") and payload["reference"].kind != JNull:
          snapshot.workspaceReference(payload["reference"])
        else:
          snapshot.activeWorkspace()
      if source.isSome and target.isSome:
        return (
          true,
          @[
            Msg(
              kind: MsgKind.CmdReorderWorkspaceIndex,
              reorderWorkspaceIndex: source.get().workspaceIdx,
              reorderTargetIndex: target.get(),
            )
          ],
        )
    return (false, @[])
  elif action.hasKey("FullscreenWindow"):
    let payload = action["FullscreenWindow"]
    let target = snapshot.requestedWindow(payload)
    if not target.valid:
      return (false, @[])
    if target.specified:
      return (
        true,
        @[Msg(kind: MsgKind.CmdToggleFullscreenById, fullscreenWindowId: target.id)],
      )
    if payload.kind == JObject:
      return (true, @[Msg(kind: MsgKind.CmdToggleFullscreen)])
  elif action.hasKey("MaximizeColumn"):
    return (true, @[Msg(kind: MsgKind.CmdMaximizeColumn)])
  elif action.hasKey("MaximizeWindowToEdges"):
    let payload = action["MaximizeWindowToEdges"]
    let target = snapshot.requestedWindow(payload)
    if not target.valid:
      return (false, @[])
    if target.specified:
      let msg = snapshot.toggleMaximizeMessage(target.id)
      if msg.isSome:
        return (true, @[msg.get()])
      return (false, @[])
    if payload.kind != JObject:
      return (false, @[])
    let focused = snapshot.focusedWindow()
    let msg = snapshot.toggleMaximizeMessage(focused)
    if msg.isSome:
      return (true, @[msg.get()])
    return (false, @[])
  elif action.hasKey("ToggleWindowFloating"):
    let payload = action["ToggleWindowFloating"]
    let target = snapshot.requestedWindow(payload)
    if not target.valid:
      return (false, @[])
    if target.specified:
      let win = snapshot.windowById(target.id)
      return (
        true,
        @[
          Msg(
            kind: MsgKind.CmdSetWindowFloatingById,
            floatingWindowId: target.id,
            windowFloating: not win.get().isFloating,
          )
        ],
      )
    if payload.kind == JObject:
      return (true, @[Msg(kind: MsgKind.CmdToggleFloating)])
  elif action.hasKey("MoveWindowToFloating") or action.hasKey("MoveWindowToTiling"):
    let floatWindow = action.hasKey("MoveWindowToFloating")
    let payload =
      if floatWindow:
        action["MoveWindowToFloating"]
      else:
        action["MoveWindowToTiling"]
    let target = snapshot.requestedWindow(payload)
    if target.valid and payload.kind == JObject:
      let windowId =
        if target.specified:
          target.id
        else:
          snapshot.focusedWindow()
      if windowId != 0'u32 and snapshot.windowById(windowId).isSome:
        return (
          true,
          @[
            Msg(
              kind: MsgKind.CmdSetWindowFloatingById,
              floatingWindowId: windowId,
              windowFloating: floatWindow,
            )
          ],
        )
  elif action.hasKey("SwitchPresetColumnWidth"):
    return
      (true, @[Msg(kind: MsgKind.CmdSwitchProportionPreset, proportionPresetDelta: 1)])
  elif action.hasKey("ShowHotkeyOverlay"):
    return (true, @[Msg(kind: MsgKind.CmdShowHotkeyOverlay)])
  elif action.hasKey("LoadConfigFile"):
    let payload = action["LoadConfigFile"]
    if payload.kind == JObject and stringFromField(payload, "path").len == 0:
      return (true, @[Msg(kind: MsgKind.CmdConfigReload)])
  elif action.hasKey("Quit"):
    let payload = action["Quit"]
    if payload.kind == JObject and
        boolFromEitherField(payload, "skip_confirmation", "skip-confirmation", false):
      return (true, @[Msg(kind: MsgKind.CmdExitSessionImmediate)])
    return (true, @[Msg(kind: MsgKind.CmdExitSession)])
  elif action.hasKey("Screenshot"):
    let payload = action["Screenshot"]
    return (
      true,
      @[
        Msg(
          kind: MsgKind.CmdScreenshot,
          screenshotKind: ScreenshotKind.ShotRegion,
          screenshotPath: stringFromField(payload, "path"),
          screenshotPointerMode: pointerMode(
            boolFromEitherField(payload, "show_pointer", "show-pointer", true)
          ),
          screenshotWriteToDisk:
            boolFromEitherField(payload, "write_to_disk", "write-to-disk", true),
          screenshotCopyToClipboard: true,
        )
      ],
    )
  elif action.hasKey("ScreenshotScreen"):
    let payload = action["ScreenshotScreen"]
    return (
      true,
      @[
        Msg(
          kind: MsgKind.CmdScreenshot,
          screenshotKind: ScreenshotKind.ShotScreen,
          screenshotPath: stringFromField(payload, "path"),
          screenshotPointerMode: pointerMode(
            boolFromEitherField(payload, "show_pointer", "show-pointer", true)
          ),
          screenshotWriteToDisk:
            boolFromEitherField(payload, "write_to_disk", "write-to-disk", true),
          screenshotCopyToClipboard: true,
        )
      ],
    )
  elif action.hasKey("ScreenshotWindow"):
    let payload = action["ScreenshotWindow"]
    return (
      true,
      @[
        Msg(
          kind: MsgKind.CmdScreenshot,
          screenshotKind: ScreenshotKind.ShotWindow,
          screenshotPath: stringFromField(payload, "path"),
          screenshotPointerMode: pointerMode(
            boolFromEitherField(payload, "show_pointer", "show-pointer", false)
          ),
          screenshotWriteToDisk:
            boolFromEitherField(payload, "write_to_disk", "write-to-disk", true),
          screenshotCopyToClipboard: true,
        )
      ],
    )
  elif action.hasKey("PowerOffMonitors"):
    return (true, @[Msg(kind: MsgKind.CmdPowerOffMonitors)])
  elif action.hasKey("PowerOnMonitors"):
    return (true, @[Msg(kind: MsgKind.CmdPowerOnMonitors)])
  (false, @[])

proc handleNiriRequest*(line: string, snapshot: ShellSnapshot): NiriIpcResult =
  result.handled = false
  let stripped = line.strip()
  if stripped.len == 0 or (stripped[0] != '{' and stripped[0] != '"'):
    return

  var request: JsonNode
  try:
    request = parseJson(stripped)
  except CatchableError as e:
    result.handled = true
    result.requestKind = "invalid-json"
    result.error = "invalid JSON request: " & e.msg
    result.reply = errReply(result.error)
    return

  result.handled = true

  if request.kind == JString:
    result.requestKind = "query"
    result.requestName = request.getStr()
    case request.getStr()
    of "Outputs":
      result.reply = okReply(%*{"Outputs": niriOutputsJson(snapshot)})
    of "Workspaces":
      result.reply = okReply(%*{"Workspaces": niriWorkspacesJson(snapshot)})
    of "Windows":
      result.reply = okReply(%*{"Windows": niriWindowsJson(snapshot)})
    of "FocusedWindow":
      let focused = snapshot.focusedWindow()
      for win in snapshot.windows:
        if win.id == focused:
          result.reply = okReply(%*{"FocusedWindow": niriWindowJson(snapshot, win)})
          return
      result.reply = okReply(%*{"FocusedWindow": newJNull()})
    of "OverviewState":
      result.reply = okReply(%*{"OverviewState": niriOverviewJson(snapshot)})
    of "KeyboardLayouts":
      result.reply = okReply(%*{"KeyboardLayouts": niriKeyboardLayoutsJson(snapshot)})
    of "Casts":
      result.reply = okReply(%*{"Casts": niriCastsJson()})
    of "EventStream":
      result.requestKind = "event-stream"
      result.subscribe = true
      result.reply = handledReply()
      result.initialEvents = initialNiriEvents(snapshot)
    else:
      result.requestKind = "unsupported"
      result.error = "unsupported niri request: " & request.getStr()
      result.reply = errReply(result.error)
    return

  if request.kind == JObject and request.hasKey("Action"):
    result.requestKind = "action"
    result.recordNiriActionDetails(request["Action"])
    let action = actionMessages(request["Action"], snapshot)
    result.messages = action.messages
    if action.handled:
      result.reply = handledReply()
    else:
      result.error =
        if result.actionName.len > 0:
          "unsupported or invalid niri action: " & result.actionName
        else:
          "unsupported or invalid niri action"
      result.reply = errReply(result.error)
    return

  result.requestKind = "unsupported"
  result.error = "unsupported niri request"
  result.reply = errReply(result.error)
