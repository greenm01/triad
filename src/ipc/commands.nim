import std/[options, strutils]
import ../core/msg
import ../types/runtime_values

proc parseInt32Arg(s: string): Option[int32] =
  try:
    some(int32(parseInt(s)))
  except CatchableError:
    none(int32)

proc parseUInt32Arg(s: string): Option[uint32] =
  try:
    let value = parseInt(s)
    if value <= 0:
      return none(uint32)
    some(uint32(value))
  except CatchableError:
    none(uint32)

proc parseFloat32Arg(s: string): Option[float32] =
  try:
    some(float32(parseFloat(s)))
  except CatchableError:
    none(float32)

proc parseScreenshotCommand(parts: seq[string], kind: ScreenshotKind): Option[Msg] =
  var path = ""
  var pointerMode = ScreenshotPointerMode.PointerDefault
  var writeToDisk = true
  var copyToClipboard = true
  var i = 1
  while i < parts.len:
    case parts[i]
    of "--path":
      if i + 1 >= parts.len:
        return none(Msg)
      path = parts[i + 1]
      inc i, 2
    of "--show-pointer":
      if pointerMode == ScreenshotPointerMode.PointerHide:
        return none(Msg)
      pointerMode = ScreenshotPointerMode.PointerShow
      inc i
    of "--hide-pointer":
      if pointerMode == ScreenshotPointerMode.PointerShow:
        return none(Msg)
      pointerMode = ScreenshotPointerMode.PointerHide
      inc i
    of "--no-clipboard":
      if not writeToDisk:
        return none(Msg)
      copyToClipboard = false
      inc i
    of "--clipboard-only":
      if not copyToClipboard:
        return none(Msg)
      writeToDisk = false
      copyToClipboard = true
      inc i
    else:
      return none(Msg)

  if not writeToDisk and not copyToClipboard:
    return none(Msg)

  some(
    Msg(
      kind: MsgKind.CmdScreenshot,
      screenshotKind: kind,
      screenshotPath: path,
      screenshotPointerMode: pointerMode,
      screenshotWriteToDisk: writeToDisk,
      screenshotCopyToClipboard: copyToClipboard,
    )
  )

proc parseTextCommand*(line: string): Option[Msg] =
  let parts = line.strip().splitWhitespace()
  if parts.len == 0:
    return none(Msg)

  case parts[0]
  of "focus-next":
    some(Msg(kind: MsgKind.CmdFocusNext))
  of "focus-prev":
    some(Msg(kind: MsgKind.CmdFocusPrev))
  of "focus-left":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
  of "focus-right":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
  of "focus-up":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
  of "focus-down":
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
  of "focus-last":
    some(Msg(kind: MsgKind.CmdFocusLast))
  of "focus-tag-left":
    some(Msg(kind: MsgKind.CmdFocusTagLeft))
  of "focus-tag-right":
    some(Msg(kind: MsgKind.CmdFocusTagRight))
  of "focus-occupied-tag-left":
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagLeft))
  of "focus-occupied-tag-right":
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagRight))
  of "focus-column-first":
    some(Msg(kind: MsgKind.CmdFocusColumnFirst))
  of "focus-column-last":
    some(Msg(kind: MsgKind.CmdFocusColumnLast))
  of "focus-window-or-workspace-up":
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
  of "focus-window-or-workspace-down":
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
  of "move-to-tag-left":
    some(Msg(kind: MsgKind.CmdMoveToTagLeft))
  of "move-to-tag-right":
    some(Msg(kind: MsgKind.CmdMoveToTagRight))
  of "close-window":
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: WindowId(win.get())))
      else:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdCloseWindow))
  of "focus-window":
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: WindowId(win.get())))
      else:
        none(Msg)
    else:
      none(Msg)
  of "config-reload":
    some(Msg(kind: MsgKind.CmdConfigReload))
  of "layout-scroller":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
  of "layout-vertical-scroller":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller))
  of "layout-tile":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.MasterStack))
  of "layout-grid":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
  of "layout-monocle":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Monocle))
  of "layout-deck":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck))
  of "layout-center-tile":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.CenterTile))
  of "layout-right-tile":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.RightTile))
  of "layout-vertical-tile":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalTile))
  of "layout-vertical-grid":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalGrid))
  of "layout-vertical-deck":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalDeck))
  of "layout-tgmix":
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.TGMix))
  of "switch-layout":
    some(Msg(kind: MsgKind.CmdSwitchLayout))
  of "toggle-overview":
    some(Msg(kind: MsgKind.CmdToggleOverview))
  of "open-overview":
    some(Msg(kind: MsgKind.CmdOpenOverview))
  of "close-overview":
    some(Msg(kind: MsgKind.CmdCloseOverview))
  of "toggle-floating":
    some(Msg(kind: MsgKind.CmdToggleFloating))
  of "fullscreen-window", "toggle-fullscreen":
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(
          Msg(
            kind: MsgKind.CmdToggleFullscreenById,
            fullscreenWindowId: WindowId(win.get()),
          )
        )
      else:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdToggleFullscreen))
  of "exit-fullscreen":
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(
          Msg(
            kind: MsgKind.CmdExitFullscreenById, fullscreenWindowId: WindowId(win.get())
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of "maximize-window-to-edges", "toggle-maximized", "toggle-maximize":
    some(Msg(kind: MsgKind.CmdToggleMaximized))
  of "minimize", "minimize-window":
    some(Msg(kind: MsgKind.CmdMinimize))
  of "screenshot":
    parseScreenshotCommand(parts, ScreenshotKind.ShotRegion)
  of "screenshot-screen":
    parseScreenshotCommand(parts, ScreenshotKind.ShotScreen)
  of "screenshot-window":
    parseScreenshotCommand(parts, ScreenshotKind.ShotWindow)
  of "spawn":
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdSpawn, spawnCommand: parts[1 ..^ 1]))
    else:
      none(Msg)
  of "spawn-terminal":
    some(Msg(kind: MsgKind.CmdSpawnTerminal))
  of "lock-session":
    some(Msg(kind: MsgKind.CmdLockSession))
  of "warp-pointer":
    if parts.len >= 3:
      let x = parseInt32Arg(parts[1])
      let y = parseInt32Arg(parts[2])
      if x.isSome and y.isSome:
        some(Msg(kind: MsgKind.CmdWarpPointer, warpX: x.get(), warpY: y.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "eat-next-key":
    some(Msg(kind: MsgKind.CmdEatNextKey))
  of "cancel-eat-next-key":
    some(Msg(kind: MsgKind.CmdCancelEatNextKey))
  of "toggle-keyboard-shortcuts-inhibit", "keyboard-shortcuts-inhibit":
    some(Msg(kind: MsgKind.CmdToggleKeyboardShortcutsInhibit))
  of "stop-manager":
    some(Msg(kind: MsgKind.CmdStopManager))
  of "triad-reload":
    some(Msg(kind: MsgKind.CmdTriadReload))
  of "exit-session":
    some(Msg(kind: MsgKind.CmdExitSession))
  of "focus-shell-ui":
    some(Msg(kind: MsgKind.CmdFocusShellUi))
  of "show-hotkey-overlay":
    some(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
  of "hide-hotkey-overlay":
    some(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
  of "toggle-hotkey-overlay":
    some(Msg(kind: MsgKind.CmdToggleHotkeyOverlay))
  of "move-to-scratchpad":
    some(Msg(kind: MsgKind.CmdMoveToScratchpad))
  of "move-to-named-scratchpad":
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveToNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of "toggle-scratchpad":
    some(Msg(kind: MsgKind.CmdToggleScratchpad))
  of "toggle-named-scratchpad":
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdToggleNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of "restore-scratchpad":
    some(Msg(kind: MsgKind.CmdRestoreScratchpad))
  of "select-window":
    some(Msg(kind: MsgKind.CmdSelectWindow))
  of "rename-tag":
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdRenameTag, newName: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of "group-windows":
    some(Msg(kind: MsgKind.CmdGroupWindows))
  of "ungroup-window":
    some(Msg(kind: MsgKind.CmdUngroupWindow))
  of "focus-next-in-group":
    some(Msg(kind: MsgKind.CmdFocusNextInGroup))
  of "move-floating":
    if parts.len >= 3:
      let dx = parseInt32Arg(parts[1])
      let dy = parseInt32Arg(parts[2])
      if dx.isSome and dy.isSome:
        some(Msg(kind: MsgKind.CmdMoveFloating, moveDX: dx.get(), moveDY: dy.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "resize-floating":
    if parts.len >= 3:
      let dw = parseInt32Arg(parts[1])
      let dh = parseInt32Arg(parts[2])
      if dw.isSome and dh.isSome:
        some(Msg(kind: MsgKind.CmdResizeFloating, deltaFW: dw.get(), deltaFH: dh.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "move-to-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdMoveToTag, targetTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "move-to-workspace":
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "focus-output":
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of "move-workspace-to-output":
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: parts[1 ..^ 1].join(" ")
        )
      )
    else:
      none(Msg)
  of "move-to-output":
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdMoveToOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of "focus-workspace":
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "focus-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdFocusTag, focusTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "swap-to-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdSwapWindowToTag, targetTagSwap: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "master-count":
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdSetMasterCount, count: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of "adjust-master-count":
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdAdjustMasterCount, deltaMC: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of "master-ratio":
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome:
        some(Msg(kind: MsgKind.CmdSetMasterRatio, ratio: ratio.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "adjust-master-ratio":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustMasterRatio, deltaMR: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "resize-width":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeWidth, deltaW: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "resize-height":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeHeight, deltaH: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "set-column-width":
    if parts.len >= 2:
      let width = parseFloat32Arg(parts[1])
      if width.isSome:
        some(Msg(kind: MsgKind.CmdSetColumnWidth, targetWidth: width.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "maximize-column":
    some(Msg(kind: MsgKind.CmdMaximizeColumn))
  of "adjust-gaps":
    if parts.len >= 2:
      let delta = parseInt32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustGaps, deltaG: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of "toggle-gaps":
    some(Msg(kind: MsgKind.CmdToggleGaps))
  of "zoom":
    some(Msg(kind: MsgKind.CmdZoom))
  of "consume-window":
    some(Msg(kind: MsgKind.CmdConsumeWindow))
  of "expel-window":
    some(Msg(kind: MsgKind.CmdExpelWindow))
  of "move-column-left":
    some(Msg(kind: MsgKind.CmdMoveColumnLeft))
  of "move-column-right":
    some(Msg(kind: MsgKind.CmdMoveColumnRight))
  of "move-column-to-first":
    some(Msg(kind: MsgKind.CmdMoveColumnToFirst))
  of "move-column-to-last":
    some(Msg(kind: MsgKind.CmdMoveColumnToLast))
  of "move-window-left":
    some(Msg(kind: MsgKind.CmdMoveWindowLeft))
  of "move-window-right":
    some(Msg(kind: MsgKind.CmdMoveWindowRight))
  of "move-window-up":
    some(Msg(kind: MsgKind.CmdMoveWindowUp))
  of "move-window-down":
    some(Msg(kind: MsgKind.CmdMoveWindowDown))
  of "move-window-up-or-to-workspace-up":
    some(Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp))
  of "move-window-down-or-to-workspace-down":
    some(Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown))
  of "swap-window-up":
    some(Msg(kind: MsgKind.CmdSwapWindowUp))
  of "swap-window-down":
    some(Msg(kind: MsgKind.CmdSwapWindowDown))
  else:
    none(Msg)
