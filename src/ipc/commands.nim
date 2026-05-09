import options, strutils
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
    if value <= 0: return none(uint32)
    some(uint32(value))
  except CatchableError:
    none(uint32)

proc parseFloat32Arg(s: string): Option[float32] =
  try:
    some(float32(parseFloat(s)))
  except CatchableError:
    none(float32)

proc parseTextCommand*(line: string): Option[Msg] =
  let parts = line.strip().splitWhitespace()
  if parts.len == 0:
    return none(Msg)

  case parts[0]
  of "focus-next": some(Msg(kind: CmdFocusNext))
  of "focus-prev": some(Msg(kind: CmdFocusPrev))
  of "focus-left": some(Msg(kind: CmdFocusDirection, direction: DirLeft))
  of "focus-right": some(Msg(kind: CmdFocusDirection, direction: DirRight))
  of "focus-up": some(Msg(kind: CmdFocusDirection, direction: DirUp))
  of "focus-down": some(Msg(kind: CmdFocusDirection, direction: DirDown))
  of "focus-last": some(Msg(kind: CmdFocusLast))
  of "focus-tag-left": some(Msg(kind: CmdFocusTagLeft))
  of "focus-tag-right": some(Msg(kind: CmdFocusTagRight))
  of "focus-occupied-tag-left": some(Msg(kind: CmdFocusOccupiedTagLeft))
  of "focus-occupied-tag-right": some(Msg(kind: CmdFocusOccupiedTagRight))
  of "focus-column-first": some(Msg(kind: CmdFocusColumnFirst))
  of "focus-column-last": some(Msg(kind: CmdFocusColumnLast))
  of "focus-window-or-workspace-up": some(Msg(kind: CmdFocusWindowOrWorkspaceUp))
  of "focus-window-or-workspace-down": some(Msg(kind: CmdFocusWindowOrWorkspaceDown))
  of "move-to-tag-left": some(Msg(kind: CmdMoveToTagLeft))
  of "move-to-tag-right": some(Msg(kind: CmdMoveToTagRight))
  of "close-window": some(Msg(kind: CmdCloseWindow))
  of "config-reload": some(Msg(kind: CmdConfigReload))
  of "layout-scroller": some(Msg(kind: CmdSetLayout, newLayout: Scroller))
  of "layout-vertical-scroller": some(Msg(kind: CmdSetLayout, newLayout: VerticalScroller))
  of "layout-tile": some(Msg(kind: CmdSetLayout, newLayout: MasterStack))
  of "layout-grid": some(Msg(kind: CmdSetLayout, newLayout: Grid))
  of "layout-monocle": some(Msg(kind: CmdSetLayout, newLayout: Monocle))
  of "layout-deck": some(Msg(kind: CmdSetLayout, newLayout: Deck))
  of "layout-center-tile": some(Msg(kind: CmdSetLayout, newLayout: CenterTile))
  of "layout-right-tile": some(Msg(kind: CmdSetLayout, newLayout: RightTile))
  of "layout-vertical-tile": some(Msg(kind: CmdSetLayout, newLayout: VerticalTile))
  of "layout-vertical-grid": some(Msg(kind: CmdSetLayout, newLayout: VerticalGrid))
  of "layout-vertical-deck": some(Msg(kind: CmdSetLayout, newLayout: VerticalDeck))
  of "switch-layout": some(Msg(kind: CmdSwitchLayout))
  of "toggle-overview": some(Msg(kind: CmdToggleOverview))
  of "open-overview": some(Msg(kind: CmdOpenOverview))
  of "close-overview": some(Msg(kind: CmdCloseOverview))
  of "toggle-floating": some(Msg(kind: CmdToggleFloating))
  of "toggle-fullscreen": some(Msg(kind: CmdToggleFullscreen))
  of "toggle-maximized", "toggle-maximize": some(Msg(kind: CmdToggleMaximized))
  of "minimize", "minimize-window": some(Msg(kind: CmdMinimize))
  of "spawn":
    if parts.len >= 2: some(Msg(kind: CmdSpawn, spawnCommand: parts[1..^1])) else: none(Msg)
  of "spawn-terminal": some(Msg(kind: CmdSpawnTerminal))
  of "lock-session": some(Msg(kind: CmdLockSession))
  of "warp-pointer":
    if parts.len >= 3:
      let x = parseInt32Arg(parts[1])
      let y = parseInt32Arg(parts[2])
      if x.isSome and y.isSome: some(Msg(kind: CmdWarpPointer, warpX: x.get(), warpY: y.get())) else: none(Msg)
    else: none(Msg)
  of "eat-next-key": some(Msg(kind: CmdEatNextKey))
  of "cancel-eat-next-key": some(Msg(kind: CmdCancelEatNextKey))
  of "toggle-keyboard-shortcuts-inhibit", "keyboard-shortcuts-inhibit": some(Msg(kind: CmdToggleKeyboardShortcutsInhibit))
  of "stop-manager": some(Msg(kind: CmdStopManager))
  of "triad-reload": some(Msg(kind: CmdTriadReload))
  of "exit-session": some(Msg(kind: CmdExitSession))
  of "focus-shell-ui": some(Msg(kind: CmdFocusShellUi))
  of "move-to-scratchpad": some(Msg(kind: CmdMoveToScratchpad))
  of "move-to-named-scratchpad":
    if parts.len >= 2: some(Msg(kind: CmdMoveToNamedScratchpad, scratchpadName: parts[1..^1].join(" "))) else: none(Msg)
  of "toggle-scratchpad": some(Msg(kind: CmdToggleScratchpad))
  of "toggle-named-scratchpad":
    if parts.len >= 2: some(Msg(kind: CmdToggleNamedScratchpad, scratchpadName: parts[1..^1].join(" "))) else: none(Msg)
  of "restore-scratchpad": some(Msg(kind: CmdRestoreScratchpad))
  of "select-window": some(Msg(kind: CmdSelectWindow))
  of "rename-tag":
    if parts.len >= 2: some(Msg(kind: CmdRenameTag, newName: parts[1..^1].join(" "))) else: none(Msg)
  of "group-windows": some(Msg(kind: CmdGroupWindows))
  of "ungroup-window": some(Msg(kind: CmdUngroupWindow))
  of "focus-next-in-group": some(Msg(kind: CmdFocusNextInGroup))
  of "move-floating":
    if parts.len >= 3:
      let dx = parseInt32Arg(parts[1])
      let dy = parseInt32Arg(parts[2])
      if dx.isSome and dy.isSome: some(Msg(kind: CmdMoveFloating, moveDX: dx.get(), moveDY: dy.get())) else: none(Msg)
    else: none(Msg)
  of "resize-floating":
    if parts.len >= 3:
      let dw = parseInt32Arg(parts[1])
      let dh = parseInt32Arg(parts[2])
      if dw.isSome and dh.isSome: some(Msg(kind: CmdResizeFloating, deltaFW: dw.get(), deltaFH: dh.get())) else: none(Msg)
    else: none(Msg)
  of "move-to-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome: some(Msg(kind: CmdMoveToTag, targetTag: tag.get())) else: none(Msg)
    else: none(Msg)
  of "move-to-workspace":
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome: some(Msg(kind: CmdMoveToWorkspaceIndex, workspaceIndex: index.get())) else: none(Msg)
    else: none(Msg)
  of "focus-workspace":
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome: some(Msg(kind: CmdFocusWorkspaceIndex, workspaceIndex: index.get())) else: none(Msg)
    else: none(Msg)
  of "focus-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome: some(Msg(kind: CmdFocusTag, focusTag: tag.get())) else: none(Msg)
    else: none(Msg)
  of "swap-to-tag":
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome: some(Msg(kind: CmdSwapWindowToTag, targetTagSwap: tag.get())) else: none(Msg)
    else: none(Msg)
  of "master-count":
    if parts.len >= 2:
      try: some(Msg(kind: CmdSetMasterCount, count: parseInt(parts[1]))) except CatchableError: none(Msg)
    else: none(Msg)
  of "adjust-master-count":
    if parts.len >= 2:
      try: some(Msg(kind: CmdAdjustMasterCount, deltaMC: parseInt(parts[1]))) except CatchableError: none(Msg)
    else: none(Msg)
  of "master-ratio":
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome: some(Msg(kind: CmdSetMasterRatio, ratio: ratio.get())) else: none(Msg)
    else: none(Msg)
  of "adjust-master-ratio":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome: some(Msg(kind: CmdAdjustMasterRatio, deltaMR: delta.get())) else: none(Msg)
    else: none(Msg)
  of "resize-width":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome: some(Msg(kind: CmdResizeWidth, deltaW: delta.get())) else: none(Msg)
    else: none(Msg)
  of "resize-height":
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome: some(Msg(kind: CmdResizeHeight, deltaH: delta.get())) else: none(Msg)
    else: none(Msg)
  of "set-column-width":
    if parts.len >= 2:
      let width = parseFloat32Arg(parts[1])
      if width.isSome: some(Msg(kind: CmdSetColumnWidth, targetWidth: width.get())) else: none(Msg)
    else: none(Msg)
  of "adjust-gaps":
    if parts.len >= 2:
      let delta = parseInt32Arg(parts[1])
      if delta.isSome: some(Msg(kind: CmdAdjustGaps, deltaG: delta.get())) else: none(Msg)
    else: none(Msg)
  of "toggle-gaps": some(Msg(kind: CmdToggleGaps))
  of "zoom": some(Msg(kind: CmdZoom))
  of "consume-window": some(Msg(kind: CmdConsumeWindow))
  of "expel-window": some(Msg(kind: CmdExpelWindow))
  of "move-column-left": some(Msg(kind: CmdMoveColumnLeft))
  of "move-column-right": some(Msg(kind: CmdMoveColumnRight))
  of "move-column-to-first": some(Msg(kind: CmdMoveColumnToFirst))
  of "move-column-to-last": some(Msg(kind: CmdMoveColumnToLast))
  of "move-window-left": some(Msg(kind: CmdMoveWindowLeft))
  of "move-window-right": some(Msg(kind: CmdMoveWindowRight))
  of "move-window-up": some(Msg(kind: CmdMoveWindowUp))
  of "move-window-down": some(Msg(kind: CmdMoveWindowDown))
  of "move-window-up-or-to-workspace-up": some(Msg(kind: CmdMoveWindowUpOrToWorkspaceUp))
  of "move-window-down-or-to-workspace-down": some(Msg(kind: CmdMoveWindowDownOrToWorkspaceDown))
  of "swap-window-up": some(Msg(kind: CmdSwapWindowUp))
  of "swap-window-down": some(Msg(kind: CmdSwapWindowDown))
  else: none(Msg)
