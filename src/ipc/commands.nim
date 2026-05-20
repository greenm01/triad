import std/[options, strutils]
import ../core/layout_descriptor_codec
import ../core/layout_selection_codec
import ../core/native_layout_codec
import ../core/msg
import ../types/runtime_values
import command_registry

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

proc parseBoolArg(s: string): Option[bool] =
  case s.normalize()
  of "true", "#true", "yes", "on", "1":
    some(true)
  of "false", "#false", "no", "off", "0":
    some(false)
  else:
    none(bool)

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

proc parseRecentScope(value: string): Option[RecentWindowScope] =
  case value.toLowerAscii()
  of "all":
    some(RecentWindowScope.All)
  of "workspace":
    some(RecentWindowScope.Workspace)
  of "output":
    some(RecentWindowScope.Output)
  else:
    none(RecentWindowScope)

proc parseSplitTreeNodeMode(s: string): Option[SplitTreeNodeMode] =
  case s.toLowerAscii()
  of "splith", "split-h":
    some(SplitTreeNodeMode.SplitH)
  of "splitv", "split-v":
    some(SplitTreeNodeMode.SplitV)
  of "stacking":
    some(SplitTreeNodeMode.Stacking)
  of "tabbed":
    some(SplitTreeNodeMode.Tabbed)
  else:
    none(SplitTreeNodeMode)

proc parseRecentFilter(value: string): Option[RecentWindowFilter] =
  case value.toLowerAscii()
  of "all":
    some(RecentWindowFilter.All)
  of "app-id", "appid":
    some(RecentWindowFilter.AppId)
  else:
    none(RecentWindowFilter)

proc parseRecentAdvanceCommand(parts: seq[string], kind: MsgKind): Option[Msg] =
  var msg = Msg(kind: kind)
  var i = 1
  while i < parts.len:
    case parts[i]
    of "--scope":
      if i + 1 >= parts.len:
        return none(Msg)
      let scope = parseRecentScope(parts[i + 1])
      if scope.isNone:
        return none(Msg)
      msg.recentScope = scope.get()
      msg.recentScopeSet = true
      inc i, 2
    of "--filter":
      if i + 1 >= parts.len:
        return none(Msg)
      let filter = parseRecentFilter(parts[i + 1])
      if filter.isNone:
        return none(Msg)
      msg.recentFilter = filter.get()
      msg.recentFilterSet = true
      inc i, 2
    else:
      return none(Msg)
  some(msg)

proc parseCommandParts*(parts: seq[string]): Option[Msg] =
  if parts.len == 0:
    return none(Msg)

  let spec = resolveCommandSpec(parts[0])
  if spec.isNone:
    return none(Msg)

  case spec.get().id
  of CommandId.CidFocusNext:
    some(Msg(kind: MsgKind.CmdFocusNext))
  of CommandId.CidFocusPrev:
    some(Msg(kind: MsgKind.CmdFocusPrev))
  of CommandId.CidFocusLeft:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
  of CommandId.CidFocusRight:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
  of CommandId.CidFocusUp:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
  of CommandId.CidFocusDown:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
  of CommandId.CidFocusLast:
    some(Msg(kind: MsgKind.CmdFocusLast))
  of CommandId.CidFocusTagLeft:
    some(Msg(kind: MsgKind.CmdFocusTagLeft))
  of CommandId.CidFocusTagRight:
    some(Msg(kind: MsgKind.CmdFocusTagRight))
  of CommandId.CidFocusOccupiedTagLeft:
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagLeft))
  of CommandId.CidFocusOccupiedTagRight:
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagRight))
  of CommandId.CidFocusColumnFirst:
    some(Msg(kind: MsgKind.CmdFocusColumnFirst))
  of CommandId.CidFocusColumnLast:
    some(Msg(kind: MsgKind.CmdFocusColumnLast))
  of CommandId.CidFocusWindowOrWorkspaceUp:
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
  of CommandId.CidFocusWindowOrWorkspaceDown:
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
  of CommandId.CidMoveToTagLeft:
    some(Msg(kind: MsgKind.CmdMoveToTagLeft))
  of CommandId.CidMoveToTagRight:
    some(Msg(kind: MsgKind.CmdMoveToTagRight))
  of CommandId.CidCloseWindow:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: uint32(win.get())))
      else:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdCloseWindow))
  of CommandId.CidFocusWindow:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: uint32(win.get())))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMoveWindowToTag:
    if parts.len in 3 .. 4:
      let win = parseUInt32Arg(parts[1])
      let tag = parseUInt32Arg(parts[2])
      let follow =
        if parts.len == 4:
          parseBoolArg(parts[3])
        else:
          some(false)
      if win.isSome and tag.isSome and follow.isSome:
        some(
          Msg(
            kind: MsgKind.CmdMoveWindowToTag,
            moveWindowId: win.get(),
            moveTargetTag: tag.get(),
            moveFollowWindow: follow.get(),
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMoveWindowToWorkspace:
    if parts.len in 3 .. 4:
      let win = parseUInt32Arg(parts[1])
      let index = parseUInt32Arg(parts[2])
      let follow =
        if parts.len == 4:
          parseBoolArg(parts[3])
        else:
          some(false)
      if win.isSome and index.isSome and follow.isSome:
        some(
          Msg(
            kind: MsgKind.CmdMoveWindowToWorkspaceIndex,
            moveWorkspaceWindowId: win.get(),
            moveWorkspaceIndex: index.get(),
            moveWorkspaceFollowWindow: follow.get(),
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSetWindowFloating:
    if parts.len == 3:
      let win = parseUInt32Arg(parts[1])
      let floating = parseBoolArg(parts[2])
      if win.isSome and floating.isSome:
        some(
          Msg(
            kind: MsgKind.CmdSetWindowFloatingById,
            floatingWindowId: win.get(),
            windowFloating: floating.get(),
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSetWindowMaximized:
    if parts.len == 3:
      let win = parseUInt32Arg(parts[1])
      let maximized = parseBoolArg(parts[2])
      if win.isSome and maximized.isSome:
        some(
          Msg(
            kind: MsgKind.CmdSetWindowMaximizedById,
            maximizedWindowId: win.get(),
            windowMaximized: maximized.get(),
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSetLayoutForWorkspace:
    if parts.len == 3:
      let tag = parseUInt32Arg(parts[1])
      let layout = parseCoreLayoutModeId(parts[2])
      if tag.isSome and layout.isSome:
        some(
          Msg(
            kind: MsgKind.CmdSetLayout,
            layoutTargetTag: tag.get(),
            newLayout: layout.get(),
          )
        )
      elif tag.isSome and parseNativeLayoutId(parts[2]).isSome:
        some(
          Msg(
            kind: MsgKind.CmdSetNativeLayout,
            nativeLayoutTargetTag: tag.get(),
            nativeLayout: nativeLayoutId(parts[2].strip()),
          )
        )
      elif tag.isSome and parts[2].strip().len > 0:
        some(
          Msg(
            kind: MsgKind.CmdSetCustomLayout,
            customLayoutTargetTag: tag.get(),
            customLayout: janetLayoutId(parts[2].strip()),
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidLayoutCustom:
    if parts.len >= 2 and parts[1 ..^ 1].join(" ").strip().len > 0:
      some(
        Msg(
          kind: MsgKind.CmdSetCustomLayout,
          customLayout: janetLayoutId(parts[1 ..^ 1].join(" ").strip()),
        )
      )
    else:
      none(Msg)
  of CommandId.CidLayoutNative:
    if parts.len >= 2 and parts[1 ..^ 1].join(" ").strip().len > 0:
      some(
        Msg(
          kind: MsgKind.CmdSetNativeLayout,
          nativeLayout: nativeLayoutId(parts[1 ..^ 1].join(" ").strip()),
        )
      )
    else:
      none(Msg)
  of CommandId.CidFrameSplitHorizontal:
    some(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
  of CommandId.CidFrameSplitVertical:
    some(Msg(kind: MsgKind.CmdFrameSplitVertical))
  of CommandId.CidFrameUnsplit:
    some(Msg(kind: MsgKind.CmdFrameUnsplit))
  of CommandId.CidFrameTabNext:
    some(Msg(kind: MsgKind.CmdFrameTabNext))
  of CommandId.CidFrameTabPrev:
    some(Msg(kind: MsgKind.CmdFrameTabPrev))
  of CommandId.CidFrameResizeLeft, CommandId.CidFrameResizeRight,
      CommandId.CidFrameResizeUp, CommandId.CidFrameResizeDown:
    let delta =
      if parts.len >= 2:
        parseFloat32Arg(parts[1])
      else:
        some(0.05'f32)
    if delta.isNone or delta.get() <= 0.0:
      none(Msg)
    else:
      let d = delta.get()
      case spec.get().id
      of CommandId.CidFrameResizeLeft:
        some(Msg(kind: MsgKind.CmdFrameResizeLeft, frameResizeDelta: d))
      of CommandId.CidFrameResizeRight:
        some(Msg(kind: MsgKind.CmdFrameResizeRight, frameResizeDelta: d))
      of CommandId.CidFrameResizeUp:
        some(Msg(kind: MsgKind.CmdFrameResizeUp, frameResizeDelta: d))
      else:
        some(Msg(kind: MsgKind.CmdFrameResizeDown, frameResizeDelta: d))
  of CommandId.CidFrameSplitToggle:
    some(Msg(kind: MsgKind.CmdFrameSplitToggle))
  of CommandId.CidSplitTreeSplitHorizontal:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitHorizontal))
  of CommandId.CidSplitTreeSplitVertical:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitVertical))
  of CommandId.CidSplitTreeSplitToggle:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitToggle))
  of CommandId.CidSplitTreeLayoutSplitHorizontal:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutSplitHorizontal))
  of CommandId.CidSplitTreeLayoutSplitVertical:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutSplitVertical))
  of CommandId.CidSplitTreeLayoutToggleSplit:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutToggleSplit))
  of CommandId.CidSplitTreeLayoutStacking:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutStacking))
  of CommandId.CidSplitTreeLayoutTabbed:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutTabbed))
  of CommandId.CidSplitTreeFocusParent:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusParent))
  of CommandId.CidSplitTreeFocusChild:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusChild))
  of CommandId.CidSplitTreeLayoutCycleAll:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutCycleAll))
  of CommandId.CidSplitTreeLayoutDefault:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutDefault))
  of CommandId.CidSplitTreeLayoutCycleList:
    if parts.len < 2:
      none(Msg)
    else:
      var modes: seq[SplitTreeNodeMode]
      for i in 1 ..< parts.len:
        let m = parseSplitTreeNodeMode(parts[i])
        if m.isNone:
          return none(Msg)
        modes.add(m.get())
      some(Msg(kind: MsgKind.CmdSplitTreeLayoutCycleList, cycleModes: modes))
  of CommandId.CidSplitTreeFocusNextSibling:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusNextSibling))
  of CommandId.CidSplitTreeFocusPrevSibling:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusPrevSibling))
  of CommandId.CidBspBalance:
    some(Msg(kind: MsgKind.CmdBspBalance))
  of CommandId.CidBspEqualize:
    some(Msg(kind: MsgKind.CmdBspEqualize))
  of CommandId.CidBspPreselectLeft:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirLeft))
  of CommandId.CidBspPreselectRight:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirRight))
  of CommandId.CidBspPreselectUp:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirUp))
  of CommandId.CidBspPreselectDown:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirDown))
  of CommandId.CidDwindleSplitLeft:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirLeft))
  of CommandId.CidDwindleSplitRight, CommandId.CidDwindleSplitHorizontal:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirRight))
  of CommandId.CidDwindleSplitUp:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirUp))
  of CommandId.CidDwindleSplitDown, CommandId.CidDwindleSplitVertical:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirDown))
  of CommandId.CidBspPreselectCancel:
    some(Msg(kind: MsgKind.CmdBspPreselectCancel))
  of CommandId.CidBspPreselectRatio:
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome:
        return
          some(Msg(kind: MsgKind.CmdBspPreselectRatio, bspPreselectRatio: ratio.get()))
    none(Msg)
  of CommandId.CidConfigReload:
    some(Msg(kind: MsgKind.CmdConfigReload))
  of CommandId.CidLayoutScroller:
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
  of CommandId.CidLayoutVerticalScroller:
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller))
  of CommandId.CidLayoutTile:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tile")))
  of CommandId.CidLayoutGrid:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid")))
  of CommandId.CidLayoutMonocle:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("monocle")))
  of CommandId.CidLayoutDeck:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("deck")))
  of CommandId.CidLayoutCenterTile:
    some(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("center-tile"))
    )
  of CommandId.CidLayoutRightTile:
    some(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("right-tile"))
    )
  of CommandId.CidLayoutVerticalTile:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-tile")
      )
    )
  of CommandId.CidLayoutVerticalGrid:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-grid")
      )
    )
  of CommandId.CidLayoutVerticalDeck:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-deck")
      )
    )
  of CommandId.CidLayoutTGMix:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tgmix")))
  of CommandId.CidLayoutSpiral:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("spiral")))
  of CommandId.CidSwitchLayout:
    some(Msg(kind: MsgKind.CmdSwitchLayout))
  of CommandId.CidToggleOverview:
    some(Msg(kind: MsgKind.CmdToggleOverview))
  of CommandId.CidOpenOverview:
    some(Msg(kind: MsgKind.CmdOpenOverview))
  of CommandId.CidCloseOverview:
    some(Msg(kind: MsgKind.CmdCloseOverview))
  of CommandId.CidRecentWindowNext:
    parseRecentAdvanceCommand(parts, MsgKind.CmdRecentWindowNext)
  of CommandId.CidRecentWindowPrev:
    parseRecentAdvanceCommand(parts, MsgKind.CmdRecentWindowPrev)
  of CommandId.CidRecentWindowConfirm:
    some(Msg(kind: MsgKind.CmdRecentWindowConfirm))
  of CommandId.CidRecentWindowCancel:
    some(Msg(kind: MsgKind.CmdRecentWindowCancel))
  of CommandId.CidRecentWindowFirst:
    some(Msg(kind: MsgKind.CmdRecentWindowFirst))
  of CommandId.CidRecentWindowLast:
    some(Msg(kind: MsgKind.CmdRecentWindowLast))
  of CommandId.CidRecentWindowScope:
    if parts.len == 2:
      let scope = parseRecentScope(parts[1])
      if scope.isSome:
        some(Msg(kind: MsgKind.CmdRecentWindowScope, recentTargetScope: scope.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidRecentWindowCycleScope:
    some(Msg(kind: MsgKind.CmdRecentWindowCycleScope))
  of CommandId.CidRecentWindowCloseCurrent:
    some(Msg(kind: MsgKind.CmdRecentWindowCloseCurrent))
  of CommandId.CidToggleFloating:
    some(Msg(kind: MsgKind.CmdToggleFloating))
  of CommandId.CidToggleFullscreen:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(
          Msg(
            kind: MsgKind.CmdToggleFullscreenById, fullscreenWindowId: uint32(win.get())
          )
        )
      else:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdToggleFullscreen))
  of CommandId.CidExitFullscreen:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(
          Msg(
            kind: MsgKind.CmdExitFullscreenById, fullscreenWindowId: uint32(win.get())
          )
        )
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidToggleMaximized:
    some(Msg(kind: MsgKind.CmdToggleMaximized))
  of CommandId.CidMinimize:
    some(Msg(kind: MsgKind.CmdMinimize))
  of CommandId.CidScreenshot:
    parseScreenshotCommand(parts, ScreenshotKind.ShotRegion)
  of CommandId.CidScreenshotScreen:
    parseScreenshotCommand(parts, ScreenshotKind.ShotScreen)
  of CommandId.CidScreenshotWindow:
    parseScreenshotCommand(parts, ScreenshotKind.ShotWindow)
  of CommandId.CidSpawn:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdSpawn, spawnCommand: parts[1 ..^ 1]))
    else:
      none(Msg)
  of CommandId.CidSpawnTerminal:
    some(Msg(kind: MsgKind.CmdSpawnTerminal))
  of CommandId.CidLockSession:
    some(Msg(kind: MsgKind.CmdLockSession))
  of CommandId.CidWarpPointer:
    if parts.len >= 3:
      let x = parseInt32Arg(parts[1])
      let y = parseInt32Arg(parts[2])
      if x.isSome and y.isSome:
        some(Msg(kind: MsgKind.CmdWarpPointer, warpX: x.get(), warpY: y.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidEatNextKey:
    some(Msg(kind: MsgKind.CmdEatNextKey))
  of CommandId.CidCancelEatNextKey:
    some(Msg(kind: MsgKind.CmdCancelEatNextKey))
  of CommandId.CidToggleKeyboardShortcutsInhibit:
    some(Msg(kind: MsgKind.CmdToggleKeyboardShortcutsInhibit))
  of CommandId.CidStopManager:
    some(Msg(kind: MsgKind.CmdStopManager))
  of CommandId.CidTriadReload:
    some(Msg(kind: MsgKind.CmdTriadReload))
  of CommandId.CidExitSession:
    some(Msg(kind: MsgKind.CmdExitSession))
  of CommandId.CidFocusShellUi:
    some(Msg(kind: MsgKind.CmdFocusShellUi))
  of CommandId.CidSwitchShell:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdSwitchShell, shellName: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.CidCycleShell:
    some(Msg(kind: MsgKind.CmdCycleShell))
  of CommandId.CidShowHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
  of CommandId.CidHideHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
  of CommandId.CidToggleHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdToggleHotkeyOverlay))
  of CommandId.CidMoveToScratchpad:
    some(Msg(kind: MsgKind.CmdMoveToScratchpad))
  of CommandId.CidMoveToNamedScratchpad:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveToNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of CommandId.CidToggleScratchpad:
    some(Msg(kind: MsgKind.CmdToggleScratchpad))
  of CommandId.CidToggleNamedScratchpad:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdToggleNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of CommandId.CidRestoreScratchpad:
    some(Msg(kind: MsgKind.CmdRestoreScratchpad))
  of CommandId.CidSelectWindow:
    some(Msg(kind: MsgKind.CmdSelectWindow))
  of CommandId.CidRenameTag:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdRenameTag, newName: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.CidGroupWindows:
    some(Msg(kind: MsgKind.CmdGroupWindows))
  of CommandId.CidUngroupWindow:
    some(Msg(kind: MsgKind.CmdUngroupWindow))
  of CommandId.CidFocusNextInGroup:
    some(Msg(kind: MsgKind.CmdFocusNextInGroup))
  of CommandId.CidMoveFloating:
    if parts.len >= 3:
      let dx = parseInt32Arg(parts[1])
      let dy = parseInt32Arg(parts[2])
      if dx.isSome and dy.isSome:
        some(Msg(kind: MsgKind.CmdMoveFloating, moveDX: dx.get(), moveDY: dy.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidResizeFloating:
    if parts.len >= 3:
      let dw = parseInt32Arg(parts[1])
      let dh = parseInt32Arg(parts[2])
      if dw.isSome and dh.isSome:
        some(Msg(kind: MsgKind.CmdResizeFloating, deltaFW: dw.get(), deltaFH: dh.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMoveToTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdMoveToTag, targetTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMoveToWorkspace:
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidFocusOutput:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.CidMoveWorkspaceToOutput:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: parts[1 ..^ 1].join(" ")
        )
      )
    else:
      none(Msg)
  of CommandId.CidMoveToOutput:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdMoveToOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.CidFocusWorkspace:
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidFocusTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdFocusTag, focusTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSwapToTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdSwapWindowToTag, targetTagSwap: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMasterCount:
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdSetMasterCount, count: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidAdjustMasterCount:
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdAdjustMasterCount, deltaMC: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidMasterRatio:
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome:
        some(Msg(kind: MsgKind.CmdSetMasterRatio, ratio: ratio.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidAdjustMasterRatio:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustMasterRatio, deltaMR: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidResizeWidth:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeWidth, deltaW: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidResizeHeight:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeHeight, deltaH: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSetColumnWidth:
    if parts.len >= 2:
      let width = parseFloat32Arg(parts[1])
      if width.isSome:
        some(Msg(kind: MsgKind.CmdSetColumnWidth, targetWidth: width.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidSwitchProportionPreset:
    if parts.len >= 2:
      try:
        some(
          Msg(
            kind: MsgKind.CmdSwitchProportionPreset,
            proportionPresetDelta: parseInt(parts[1]),
          )
        )
      except CatchableError:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdSwitchProportionPreset, proportionPresetDelta: 1))
  of CommandId.CidMaximizeColumn:
    some(Msg(kind: MsgKind.CmdMaximizeColumn))
  of CommandId.CidAdjustGaps:
    if parts.len >= 2:
      let delta = parseInt32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustGaps, deltaG: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.CidToggleGaps:
    some(Msg(kind: MsgKind.CmdToggleGaps))
  of CommandId.CidZoom:
    some(Msg(kind: MsgKind.CmdZoom))
  of CommandId.CidConsumeWindow:
    some(Msg(kind: MsgKind.CmdConsumeWindow))
  of CommandId.CidExpelWindow:
    some(Msg(kind: MsgKind.CmdExpelWindow))
  of CommandId.CidMoveColumnLeft:
    some(Msg(kind: MsgKind.CmdMoveColumnLeft))
  of CommandId.CidMoveColumnRight:
    some(Msg(kind: MsgKind.CmdMoveColumnRight))
  of CommandId.CidMoveColumnToFirst:
    some(Msg(kind: MsgKind.CmdMoveColumnToFirst))
  of CommandId.CidMoveColumnToLast:
    some(Msg(kind: MsgKind.CmdMoveColumnToLast))
  of CommandId.CidMoveWindowLeft:
    some(Msg(kind: MsgKind.CmdMoveWindowLeft))
  of CommandId.CidMoveWindowRight:
    some(Msg(kind: MsgKind.CmdMoveWindowRight))
  of CommandId.CidMoveWindowUp:
    some(Msg(kind: MsgKind.CmdMoveWindowUp))
  of CommandId.CidMoveWindowDown:
    some(Msg(kind: MsgKind.CmdMoveWindowDown))
  of CommandId.CidMoveWindowUpOrToWorkspaceUp:
    some(Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp))
  of CommandId.CidMoveWindowDownOrToWorkspaceDown:
    some(Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown))
  of CommandId.CidSwapWindowUp:
    some(Msg(kind: MsgKind.CmdSwapWindowUp))
  of CommandId.CidSwapWindowDown:
    some(Msg(kind: MsgKind.CmdSwapWindowDown))

proc parseTextCommand*(line: string): Option[Msg] =
  parseCommandParts(line.strip().splitWhitespace())
