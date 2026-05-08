import options, strutils
import ../core/model
import ../core/msg

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

proc parseLegacyCommand*(line: string): Option[Msg] =
  let parts = line.strip().splitWhitespace()
  if parts.len == 0:
    return none(Msg)

  case parts[0]
  of "focus-next": some(Msg(kind: CmdFocusNext))
  of "focus-prev": some(Msg(kind: CmdFocusPrev))
  of "close-window": some(Msg(kind: CmdCloseWindow))
  of "reload-config": some(Msg(kind: CmdReloadConfig))
  of "layout-scroller": some(Msg(kind: CmdSetLayout, newLayout: Scroller))
  of "layout-vertical-scroller": some(Msg(kind: CmdSetLayout, newLayout: VerticalScroller))
  of "layout-tile": some(Msg(kind: CmdSetLayout, newLayout: MasterStack))
  of "layout-grid": some(Msg(kind: CmdSetLayout, newLayout: Grid))
  of "layout-monocle": some(Msg(kind: CmdSetLayout, newLayout: Monocle))
  of "toggle-overview": some(Msg(kind: CmdToggleOverview))
  of "toggle-floating": some(Msg(kind: CmdToggleFloating))
  of "toggle-fullscreen": some(Msg(kind: CmdToggleFullscreen))
  of "toggle-maximized", "toggle-maximize": some(Msg(kind: CmdToggleMaximized))
  of "minimize", "minimize-window": some(Msg(kind: CmdMinimize))
  of "spawn-terminal": some(Msg(kind: CmdSpawnTerminal))
  of "move-to-scratchpad": some(Msg(kind: CmdMoveToScratchpad))
  of "toggle-scratchpad": some(Msg(kind: CmdToggleScratchpad))
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
  of "focus-workspace", "focus-tag":
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
  of "move-window-left": some(Msg(kind: CmdMoveWindowLeft))
  of "move-window-right": some(Msg(kind: CmdMoveWindowRight))
  of "move-window-up": some(Msg(kind: CmdMoveWindowUp))
  of "move-window-down": some(Msg(kind: CmdMoveWindowDown))
  of "swap-window-up": some(Msg(kind: CmdSwapWindowUp))
  of "swap-window-down": some(Msg(kind: CmdSwapWindowDown))
  else: none(Msg)
