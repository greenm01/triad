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

proc parseKeyboardLayoutCommand(parts: seq[string]): Option[Msg] =
  if parts.len > 2:
    return none(Msg)

  if parts.len == 1:
    return some(
      Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: 1,
        keyboardLayoutIndex: -1,
      )
    )

  case parts[1].normalize()
  of "next":
    some(
      Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: 1,
        keyboardLayoutIndex: -1,
      )
    )
  of "prev", "previous":
    some(
      Msg(
        kind: MsgKind.CmdSwitchKeyboardLayout,
        keyboardLayoutDelta: -1,
        keyboardLayoutIndex: -1,
      )
    )
  else:
    let index = parseInt32Arg(parts[1])
    if index.isSome and index.get() >= 0:
      some(
        Msg(
          kind: MsgKind.CmdSwitchKeyboardLayout,
          keyboardLayoutIndex: index.get(),
          keyboardLayoutDelta: 0,
        )
      )
    else:
      none(Msg)

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

proc parseLayoutIdCommand(parts: seq[string]): Option[Msg] =
  if parts.len != 1:
    return none(Msg)

  let id = parts[0].strip()
  if id.len == 0:
    return none(Msg)

  let builtin = parseCoreLayoutModeId(id)
  if builtin.isSome:
    return some(Msg(kind: MsgKind.CmdSetLayout, newLayout: builtin.get()))

  let native = parseNativeLayoutId(id)
  if native.isSome:
    return some(Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: native.get().id))

  if id.isBundledLayoutId():
    return some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId(id)))

  none(Msg)

proc parseCommandParts*(parts: seq[string]): Option[Msg] =
  if parts.len == 0:
    return none(Msg)

  let commandId = resolveCommandId(parts[0])
  if commandId.isNone:
    return parseLayoutIdCommand(parts)

  case commandId.unsafeGet()
  of CommandId.FocusNext:
    some(Msg(kind: MsgKind.CmdFocusNext))
  of CommandId.FocusPrev:
    some(Msg(kind: MsgKind.CmdFocusPrev))
  of CommandId.FocusLeft:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
  of CommandId.FocusRight:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight))
  of CommandId.FocusUp:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
  of CommandId.FocusDown:
    some(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
  of CommandId.FocusLast:
    some(Msg(kind: MsgKind.CmdFocusLast))
  of CommandId.SwitchFocusBetweenFloatingAndTiling:
    some(Msg(kind: MsgKind.CmdSwitchFocusFloatingTiling))
  of CommandId.FocusTagLeft:
    some(Msg(kind: MsgKind.CmdFocusTagLeft))
  of CommandId.FocusTagRight:
    some(Msg(kind: MsgKind.CmdFocusTagRight))
  of CommandId.FocusOccupiedTagLeft:
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagLeft))
  of CommandId.FocusOccupiedTagRight:
    some(Msg(kind: MsgKind.CmdFocusOccupiedTagRight))
  of CommandId.FocusColumnFirst:
    some(Msg(kind: MsgKind.CmdFocusColumnFirst))
  of CommandId.FocusColumnLast:
    some(Msg(kind: MsgKind.CmdFocusColumnLast))
  of CommandId.FocusWindowOrWorkspaceUp:
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceUp))
  of CommandId.FocusWindowOrWorkspaceDown:
    some(Msg(kind: MsgKind.CmdFocusWindowOrWorkspaceDown))
  of CommandId.MoveToTagLeft:
    some(Msg(kind: MsgKind.CmdMoveToTagLeft))
  of CommandId.MoveToTagRight:
    some(Msg(kind: MsgKind.CmdMoveToTagRight))
  of CommandId.CloseWindow:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdCloseWindowById, closeWindowId: uint32(win.get())))
      else:
        none(Msg)
    else:
      some(Msg(kind: MsgKind.CmdCloseWindow))
  of CommandId.FocusWindow:
    if parts.len >= 2:
      let win = parseUInt32Arg(parts[1])
      if win.isSome:
        some(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: uint32(win.get())))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.MoveWindowToTag:
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
  of CommandId.MoveWindowToWorkspace:
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
  of CommandId.SetWindowFloating:
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
  of CommandId.SetWindowMaximized:
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
  of CommandId.SetLayoutForWorkspace:
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
  of CommandId.LayoutCustom:
    if parts.len >= 2 and parts[1 ..^ 1].join(" ").strip().len > 0:
      some(
        Msg(
          kind: MsgKind.CmdSetCustomLayout,
          customLayout: janetLayoutId(parts[1 ..^ 1].join(" ").strip()),
        )
      )
    else:
      none(Msg)
  of CommandId.LayoutNative:
    if parts.len >= 2 and parts[1 ..^ 1].join(" ").strip().len > 0:
      some(
        Msg(
          kind: MsgKind.CmdSetNativeLayout,
          nativeLayout: nativeLayoutId(parts[1 ..^ 1].join(" ").strip()),
        )
      )
    else:
      none(Msg)
  of CommandId.FrameSplitHorizontal:
    some(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
  of CommandId.FrameSplitVertical:
    some(Msg(kind: MsgKind.CmdFrameSplitVertical))
  of CommandId.FrameUnsplit:
    some(Msg(kind: MsgKind.CmdFrameUnsplit))
  of CommandId.FrameTabNext:
    some(Msg(kind: MsgKind.CmdFrameTabNext))
  of CommandId.FrameTabPrev:
    some(Msg(kind: MsgKind.CmdFrameTabPrev))
  of CommandId.FrameResizeLeft, CommandId.FrameResizeRight, CommandId.FrameResizeUp,
      CommandId.FrameResizeDown:
    let delta =
      if parts.len >= 2:
        parseFloat32Arg(parts[1])
      else:
        some(0.05'f32)
    if delta.isNone or delta.get() <= 0.0:
      none(Msg)
    else:
      let d = delta.get()
      case commandId.unsafeGet()
      of CommandId.FrameResizeLeft:
        some(Msg(kind: MsgKind.CmdFrameResizeLeft, frameResizeDelta: d))
      of CommandId.FrameResizeRight:
        some(Msg(kind: MsgKind.CmdFrameResizeRight, frameResizeDelta: d))
      of CommandId.FrameResizeUp:
        some(Msg(kind: MsgKind.CmdFrameResizeUp, frameResizeDelta: d))
      else:
        some(Msg(kind: MsgKind.CmdFrameResizeDown, frameResizeDelta: d))
  of CommandId.FrameSplitToggle:
    some(Msg(kind: MsgKind.CmdFrameSplitToggle))
  of CommandId.FrameFocusParent:
    some(Msg(kind: MsgKind.CmdFrameFocusParent))
  of CommandId.FrameFocusChild:
    some(Msg(kind: MsgKind.CmdFrameFocusChild))
  of CommandId.FrameBindApp:
    some(Msg(kind: MsgKind.CmdFrameBindApp))
  of CommandId.FrameUnbindApp:
    some(Msg(kind: MsgKind.CmdFrameUnbindApp))
  of CommandId.SplitTreeSplitHorizontal:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitHorizontal))
  of CommandId.SplitTreeSplitVertical:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitVertical))
  of CommandId.SplitTreeSplitToggle:
    some(Msg(kind: MsgKind.CmdSplitTreeSplitToggle))
  of CommandId.SplitTreeLayoutSplitHorizontal:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutSplitHorizontal))
  of CommandId.SplitTreeLayoutSplitVertical:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutSplitVertical))
  of CommandId.SplitTreeLayoutToggleSplit:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutToggleSplit))
  of CommandId.SplitTreeLayoutStacking:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutStacking))
  of CommandId.SplitTreeLayoutTabbed:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutTabbed))
  of CommandId.SplitTreeFocusParent:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusParent))
  of CommandId.SplitTreeFocusChild:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusChild))
  of CommandId.SplitTreeLayoutCycleAll:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutCycleAll))
  of CommandId.SplitTreeLayoutDefault:
    some(Msg(kind: MsgKind.CmdSplitTreeLayoutDefault))
  of CommandId.SplitTreeLayoutCycleList:
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
  of CommandId.SplitTreeFocusNextSibling:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusNextSibling))
  of CommandId.SplitTreeFocusPrevSibling:
    some(Msg(kind: MsgKind.CmdSplitTreeFocusPrevSibling))
  of CommandId.BspBalance:
    some(Msg(kind: MsgKind.CmdBspBalance))
  of CommandId.BspEqualize:
    some(Msg(kind: MsgKind.CmdBspEqualize))
  of CommandId.BspPreselectLeft:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirLeft))
  of CommandId.BspPreselectRight:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirRight))
  of CommandId.BspPreselectUp:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirUp))
  of CommandId.BspPreselectDown:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirDown))
  of CommandId.DwindleSplitLeft:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirLeft))
  of CommandId.DwindleSplitRight, CommandId.DwindleSplitHorizontal:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirRight))
  of CommandId.DwindleSplitUp:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirUp))
  of CommandId.DwindleSplitDown, CommandId.DwindleSplitVertical:
    some(Msg(kind: MsgKind.CmdBspPreselect, bspPreselectDirection: Direction.DirDown))
  of CommandId.BspPreselectCancel:
    some(Msg(kind: MsgKind.CmdBspPreselectCancel))
  of CommandId.BspPreselectRatio:
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome:
        return
          some(Msg(kind: MsgKind.CmdBspPreselectRatio, bspPreselectRatio: ratio.get()))
    none(Msg)
  of CommandId.ConfigReload:
    some(Msg(kind: MsgKind.CmdConfigReload))
  of CommandId.LayoutScroller:
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Scroller))
  of CommandId.LayoutVerticalScroller:
    some(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller))
  of CommandId.LayoutTile:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tile")))
  of CommandId.LayoutGrid:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("grid")))
  of CommandId.LayoutMonocle:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("monocle")))
  of CommandId.LayoutDeck:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("deck")))
  of CommandId.LayoutCenterTile:
    some(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("center-tile"))
    )
  of CommandId.LayoutRightTile:
    some(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("right-tile"))
    )
  of CommandId.LayoutVerticalTile:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-tile")
      )
    )
  of CommandId.LayoutVerticalGrid:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-grid")
      )
    )
  of CommandId.LayoutVerticalDeck:
    some(
      Msg(
        kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("vertical-deck")
      )
    )
  of CommandId.LayoutTGMix:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("tgmix")))
  of CommandId.LayoutSpiral:
    some(Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("spiral")))
  of CommandId.SwitchLayout:
    some(Msg(kind: MsgKind.CmdSwitchLayout))
  of CommandId.SwitchKeyboardLayout:
    parseKeyboardLayoutCommand(parts)
  of CommandId.ToggleOverview:
    some(Msg(kind: MsgKind.CmdToggleOverview))
  of CommandId.OpenOverview:
    some(Msg(kind: MsgKind.CmdOpenOverview))
  of CommandId.CloseOverview:
    some(Msg(kind: MsgKind.CmdCloseOverview))
  of CommandId.RecentWindowNext:
    parseRecentAdvanceCommand(parts, MsgKind.CmdRecentWindowNext)
  of CommandId.RecentWindowPrev:
    parseRecentAdvanceCommand(parts, MsgKind.CmdRecentWindowPrev)
  of CommandId.RecentWindowConfirm:
    some(Msg(kind: MsgKind.CmdRecentWindowConfirm))
  of CommandId.RecentWindowCancel:
    some(Msg(kind: MsgKind.CmdRecentWindowCancel))
  of CommandId.RecentWindowFirst:
    some(Msg(kind: MsgKind.CmdRecentWindowFirst))
  of CommandId.RecentWindowLast:
    some(Msg(kind: MsgKind.CmdRecentWindowLast))
  of CommandId.RecentWindowScope:
    if parts.len == 2:
      let scope = parseRecentScope(parts[1])
      if scope.isSome:
        some(Msg(kind: MsgKind.CmdRecentWindowScope, recentTargetScope: scope.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.RecentWindowCycleScope:
    some(Msg(kind: MsgKind.CmdRecentWindowCycleScope))
  of CommandId.RecentWindowCloseCurrent:
    some(Msg(kind: MsgKind.CmdRecentWindowCloseCurrent))
  of CommandId.ToggleFloating:
    some(Msg(kind: MsgKind.CmdToggleFloating))
  of CommandId.ToggleFullscreen:
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
  of CommandId.ExitFullscreen:
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
  of CommandId.ToggleMaximized:
    some(Msg(kind: MsgKind.CmdToggleMaximized))
  of CommandId.Minimize:
    some(Msg(kind: MsgKind.CmdMinimize))
  of CommandId.RestoreMinimized:
    some(Msg(kind: MsgKind.CmdRestoreMinimized))
  of CommandId.Screenshot:
    parseScreenshotCommand(parts, ScreenshotKind.ShotRegion)
  of CommandId.ScreenshotScreen:
    parseScreenshotCommand(parts, ScreenshotKind.ShotScreen)
  of CommandId.ScreenshotWindow:
    parseScreenshotCommand(parts, ScreenshotKind.ShotWindow)
  of CommandId.Spawn:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdSpawn, spawnCommand: parts[1 ..^ 1]))
    else:
      none(Msg)
  of CommandId.SpawnTerminal:
    some(Msg(kind: MsgKind.CmdSpawnTerminal))
  of CommandId.LockSession:
    some(Msg(kind: MsgKind.CmdLockSession))
  of CommandId.PowerOffMonitors:
    some(Msg(kind: MsgKind.CmdPowerOffMonitors))
  of CommandId.PowerOnMonitors:
    some(Msg(kind: MsgKind.CmdPowerOnMonitors))
  of CommandId.PowerOffMonitor:
    if parts.len >= 2:
      some(
        Msg(kind: MsgKind.CmdPowerOffMonitor, outputTarget: parts[1 ..^ 1].join(" "))
      )
    else:
      none(Msg)
  of CommandId.PowerOnMonitor:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdPowerOnMonitor, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.WarpPointer:
    if parts.len >= 3:
      let x = parseInt32Arg(parts[1])
      let y = parseInt32Arg(parts[2])
      if x.isSome and y.isSome:
        some(Msg(kind: MsgKind.CmdWarpPointer, warpX: x.get(), warpY: y.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.EatNextKey:
    some(Msg(kind: MsgKind.CmdEatNextKey))
  of CommandId.CancelEatNextKey:
    some(Msg(kind: MsgKind.CmdCancelEatNextKey))
  of CommandId.ToggleKeyboardShortcutsInhibit:
    some(Msg(kind: MsgKind.CmdToggleKeyboardShortcutsInhibit))
  of CommandId.StopManager:
    some(Msg(kind: MsgKind.CmdStopManager))
  of CommandId.TriadReload:
    some(Msg(kind: MsgKind.CmdTriadReload))
  of CommandId.ExitSession:
    some(Msg(kind: MsgKind.CmdExitSession))
  of CommandId.FocusShellUi:
    some(Msg(kind: MsgKind.CmdFocusShellUi))
  of CommandId.SwitchShell:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdSwitchShell, shellName: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.CycleShell:
    some(Msg(kind: MsgKind.CmdCycleShell))
  of CommandId.ShowHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdShowHotkeyOverlay))
  of CommandId.HideHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdHideHotkeyOverlay))
  of CommandId.ToggleHotkeyOverlay:
    some(Msg(kind: MsgKind.CmdToggleHotkeyOverlay))
  of CommandId.MoveToScratchpad:
    some(Msg(kind: MsgKind.CmdMoveToScratchpad))
  of CommandId.MoveToNamedScratchpad:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveToNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of CommandId.ToggleScratchpad:
    some(Msg(kind: MsgKind.CmdToggleScratchpad))
  of CommandId.ToggleNamedScratchpad:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdToggleNamedScratchpad,
          scratchpadName: parts[1 ..^ 1].join(" "),
        )
      )
    else:
      none(Msg)
  of CommandId.RestoreScratchpad:
    some(Msg(kind: MsgKind.CmdRestoreScratchpad))
  of CommandId.SelectWindow:
    some(Msg(kind: MsgKind.CmdSelectWindow))
  of CommandId.RenameTag:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdRenameTag, newName: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.GroupWindows:
    some(Msg(kind: MsgKind.CmdGroupWindows))
  of CommandId.UngroupWindow:
    some(Msg(kind: MsgKind.CmdUngroupWindow))
  of CommandId.FocusNextInGroup:
    some(Msg(kind: MsgKind.CmdFocusNextInGroup))
  of CommandId.MoveFloating:
    if parts.len >= 3:
      let dx = parseInt32Arg(parts[1])
      let dy = parseInt32Arg(parts[2])
      if dx.isSome and dy.isSome:
        some(Msg(kind: MsgKind.CmdMoveFloating, moveDX: dx.get(), moveDY: dy.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.ResizeFloating:
    if parts.len >= 3:
      let dw = parseInt32Arg(parts[1])
      let dh = parseInt32Arg(parts[2])
      if dw.isSome and dh.isSome:
        some(Msg(kind: MsgKind.CmdResizeFloating, deltaFW: dw.get(), deltaFH: dh.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.MoveToTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdMoveToTag, targetTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.MoveToWorkspace:
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.FocusOutput:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdFocusOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.MoveWorkspaceToOutput:
    if parts.len >= 2:
      some(
        Msg(
          kind: MsgKind.CmdMoveWorkspaceToOutput, outputTarget: parts[1 ..^ 1].join(" ")
        )
      )
    else:
      none(Msg)
  of CommandId.MoveToOutput:
    if parts.len >= 2:
      some(Msg(kind: MsgKind.CmdMoveToOutput, outputTarget: parts[1 ..^ 1].join(" ")))
    else:
      none(Msg)
  of CommandId.FocusWorkspace:
    if parts.len >= 2:
      let index = parseUInt32Arg(parts[1])
      if index.isSome:
        some(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: index.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.NewWorkspace:
    some(Msg(kind: MsgKind.CmdNewWorkspace))
  of CommandId.FocusTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdFocusTag, focusTag: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.SwapToTag:
    if parts.len >= 2:
      let tag = parseUInt32Arg(parts[1])
      if tag.isSome:
        some(Msg(kind: MsgKind.CmdSwapWindowToTag, targetTagSwap: tag.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.MasterCount:
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdSetMasterCount, count: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of CommandId.AdjustMasterCount:
    if parts.len >= 2:
      try:
        some(Msg(kind: MsgKind.CmdAdjustMasterCount, deltaMC: parseInt(parts[1])))
      except CatchableError:
        none(Msg)
    else:
      none(Msg)
  of CommandId.MasterRatio:
    if parts.len >= 2:
      let ratio = parseFloat32Arg(parts[1])
      if ratio.isSome:
        some(Msg(kind: MsgKind.CmdSetMasterRatio, ratio: ratio.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.AdjustMasterRatio:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustMasterRatio, deltaMR: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.ResizeWidth:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeWidth, deltaW: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.ResizeHeight:
    if parts.len >= 2:
      let delta = parseFloat32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdResizeHeight, deltaH: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.SetColumnWidth:
    if parts.len >= 2:
      let width = parseFloat32Arg(parts[1])
      if width.isSome:
        some(Msg(kind: MsgKind.CmdSetColumnWidth, targetWidth: width.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.SwitchProportionPreset:
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
  of CommandId.MaximizeColumn:
    some(Msg(kind: MsgKind.CmdMaximizeColumn))
  of CommandId.AdjustGaps:
    if parts.len >= 2:
      let delta = parseInt32Arg(parts[1])
      if delta.isSome:
        some(Msg(kind: MsgKind.CmdAdjustGaps, deltaG: delta.get()))
      else:
        none(Msg)
    else:
      none(Msg)
  of CommandId.ToggleGaps:
    some(Msg(kind: MsgKind.CmdToggleGaps))
  of CommandId.Zoom:
    some(Msg(kind: MsgKind.CmdZoom))
  of CommandId.ConsumeWindow:
    some(Msg(kind: MsgKind.CmdConsumeWindow))
  of CommandId.ExpelWindow:
    some(Msg(kind: MsgKind.CmdExpelWindow))
  of CommandId.MoveColumnLeft:
    some(Msg(kind: MsgKind.CmdMoveColumnLeft))
  of CommandId.MoveColumnRight:
    some(Msg(kind: MsgKind.CmdMoveColumnRight))
  of CommandId.MoveColumnToFirst:
    some(Msg(kind: MsgKind.CmdMoveColumnToFirst))
  of CommandId.MoveColumnToLast:
    some(Msg(kind: MsgKind.CmdMoveColumnToLast))
  of CommandId.MoveWindowLeft:
    some(Msg(kind: MsgKind.CmdMoveWindowLeft))
  of CommandId.MoveWindowRight:
    some(Msg(kind: MsgKind.CmdMoveWindowRight))
  of CommandId.MoveWindowUp:
    some(Msg(kind: MsgKind.CmdMoveWindowUp))
  of CommandId.MoveWindowDown:
    some(Msg(kind: MsgKind.CmdMoveWindowDown))
  of CommandId.MoveWindowUpOrToWorkspaceUp:
    some(Msg(kind: MsgKind.CmdMoveWindowUpOrToWorkspaceUp))
  of CommandId.MoveWindowDownOrToWorkspaceDown:
    some(Msg(kind: MsgKind.CmdMoveWindowDownOrToWorkspaceDown))
  of CommandId.SwapWindowUp:
    some(Msg(kind: MsgKind.CmdSwapWindowUp))
  of CommandId.SwapWindowDown:
    some(Msg(kind: MsgKind.CmdSwapWindowDown))

proc parseTextCommand*(line: string): Option[Msg] =
  parseCommandParts(line.strip().splitWhitespace())
