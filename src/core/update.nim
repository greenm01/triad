import model, msg, model_utils, niri_state, tables, strutils, algorithm, json

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
    EffFocusShellSurface,
    EffCloseWindow,
    EffManageDirty,
    EffBroadcastJson,
    EffOpStartPointer,
    EffOpEnd,
    EffSetFullscreen,
    EffSetMaximized,
    EffInformResizeStart,
    EffInformResizeEnd,
    EffSpawnScreenLock,
    EffSpawnWindowMenu,
    EffSpawn,
    EffPointerWarp,
    EffEnsureNextKeyEaten,
    EffCancelEnsureNextKeyEaten,
    EffStopManager,
    EffExitSession,
    EffFocusShellUi,
    EffScreenshot,
    EffLog

  Effect* = object
    case kind*: EffectKind
    of EffLog:
      msg*: string
    of EffSetPosition:
      windowId*: WindowId
      x*, y*, w*, h*: int32
    of EffFocusWindow:
      focusId*: WindowId
    of EffFocusShellSurface:
      focusShellSurfaceId*: uint32
    of EffCloseWindow:
      closeId*: WindowId
    of EffBroadcastJson:
      jsonPayload*: string
    of EffOpStartPointer:
      opSeat*: pointer
    of EffOpEnd:
      endSeat*: pointer
    of EffSetFullscreen:
      fsWinId*: WindowId
      isFullscreen*: bool
      fsOutputId*: uint32
    of EffSetMaximized:
      maxWinId*: WindowId
      isMaximized*: bool
    of EffInformResizeStart, EffInformResizeEnd:
      resizeLifecycleWinId*: WindowId
    of EffSpawnScreenLock:
      screenLockCommand*: seq[string]
    of EffSpawnWindowMenu:
      windowMenuCommand*: seq[string]
      windowMenuId*: WindowId
      windowMenuX*: int32
      windowMenuY*: int32
    of EffSpawn:
      spawnCommand*: seq[string]
    of EffPointerWarp:
      warpX*, warpY*: int32
    of EffScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotShowPointer*: bool
    else:
      discard

# --- JSON IPC Event Helpers ---

proc broadcastWorkspaceActivated(tagId: uint32, name: string): Effect =
  let payload = %*{
    "WorkspaceActivated": {
      "id": tagId,
      "focused": true
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc broadcastWindowFocusChanged(winId: WindowId): Effect =
  let payload = %*{
    "WindowFocusChanged": {
      "id": winId
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc broadcastWindowOpened(model: Model; win: WindowData): Effect =
  let payload = %*{
    "WindowOpenedOrChanged": {
      "window": model.niriWindowJson(win)
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc broadcastWindowsChanged(model: Model): Effect =
  let payload = %*{
    "WindowsChanged": {
      "windows": model.niriWindowsJson()
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc broadcastWindowClosed(winId: WindowId): Effect =
  let payload = %*{
    "WindowClosed": {
      "id": winId
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc broadcastOverview(open: bool): Effect =
  let payload = %*{
    "OverviewOpenedOrClosed": {
      "is_open": open
    }
  }
  return Effect(kind: EffBroadcastJson, jsonPayload: $payload)

proc shouldBroadcastWindowsChanged(kind: MsgKind): bool =
  case kind
  of WlWindowCreated,
      WlWindowDestroyed,
      WlFocusChanged,
      WlWindowFullscreenRequested,
      WlWindowExitFullscreenRequested,
      WlWindowMaximizeRequested,
      WlWindowUnmaximizeRequested,
      WlWindowMinimizeRequested,
      WlWindowDimensions,
      WlWindowAppId,
      WlWindowTitle,
      WlWindowDimensionsHint,
      CmdFocusNext,
      CmdFocusPrev,
      CmdFocusDirection,
      CmdFocusLast,
      CmdFocusTagLeft,
      CmdFocusTagRight,
      CmdFocusOccupiedTagLeft,
      CmdFocusOccupiedTagRight,
      CmdFocusColumnFirst,
      CmdFocusColumnLast,
      CmdFocusWindowOrWorkspaceUp,
      CmdFocusWindowOrWorkspaceDown,
      CmdMoveToTagLeft,
      CmdMoveToTagRight,
      CmdMoveWindow,
      CmdMoveWindowLeft,
      CmdMoveWindowRight,
      CmdMoveWindowUp,
      CmdMoveWindowDown,
      CmdMoveWindowUpOrToWorkspaceUp,
      CmdMoveWindowDownOrToWorkspaceDown,
      CmdMoveColumnLeft,
      CmdMoveColumnRight,
      CmdMoveColumnToFirst,
      CmdMoveColumnToLast,
      CmdSwapWindowUp,
      CmdSwapWindowDown,
      CmdConsumeWindow,
      CmdExpelWindow,
      CmdMoveToTag,
      CmdSwapWindowToTag,
      CmdMoveToScratchpad,
      CmdMoveToNamedScratchpad,
      CmdToggleScratchpad,
      CmdToggleNamedScratchpad,
      CmdRestoreScratchpad,
      CmdToggleFloating,
      CmdToggleFullscreen,
      CmdToggleMaximized,
      CmdMinimize,
      CmdSelectWindow,
      CmdFocusTag,
      CmdFocusWindowById:
    true
  else:
    false

proc keepIf[T](s: var seq[T], pred: proc(x: T): bool) =
  var i = 0
  while i < s.len:
    if pred(s[i]): inc i
    else: s.delete(i)

proc syncPrimaryOutput(model: var Model) =
  if model.outputs.len == 0:
    model.primaryOutput = 0
    return

  if model.primaryOutput == 0 or not model.outputs.hasKey(model.primaryOutput):
    var ids: seq[uint32] = @[]
    for id in model.outputs.keys:
      ids.add(id)
    ids.sort()
    model.primaryOutput = ids[0]

  let output = model.outputs[model.primaryOutput]
  if output.w > 0 and output.h > 0:
    model.screenWidth = output.w
    model.screenHeight = output.h

proc syncPrimaryOutputTag(model: var Model) =
  if model.primaryOutput != 0 and model.activeTag != 0:
    model.outputTags[model.primaryOutput] = model.activeTag

proc chooseFullscreenOutput(model: Model; requested: uint32): uint32 =
  if requested != 0 and model.outputs.hasKey(requested):
    return requested
  if model.primaryOutput != 0 and model.outputs.hasKey(model.primaryOutput):
    return model.primaryOutput
  if requested != 0:
    return requested
  0

proc isFocusChangingCommand(kind: MsgKind): bool =
  kind in {
    WlFocusChanged,
    CmdFocusNext,
    CmdFocusPrev,
    CmdFocusDirection,
    CmdFocusLast,
    CmdFocusTagLeft,
    CmdFocusTagRight,
    CmdFocusOccupiedTagLeft,
    CmdFocusOccupiedTagRight,
    CmdFocusColumnFirst,
    CmdFocusColumnLast,
    CmdFocusWindowOrWorkspaceUp,
    CmdFocusWindowOrWorkspaceDown,
    CmdFocusTag,
    CmdFocusWindowById,
    CmdSelectWindow,
    CmdToggleScratchpad,
    CmdToggleNamedScratchpad,
    CmdRestoreScratchpad,
    WlShellSurfaceInteraction
  }

proc recordFocus(model: var Model; winId: WindowId) =
  if winId == 0 or not model.windows.hasKey(winId):
    return
  model.focusHistory.keepIf(proc(x: WindowId): bool = x != winId)
  model.focusHistory.add(winId)
  while model.focusHistory.len > 32:
    model.focusHistory.delete(0)

proc activeVisibleWindows(model: Model; tag: TagState): seq[WindowId] =
  for col in tag.columns:
    for win in col.windows:
      if not model.windows.hasKey(win) or not model.windows[win].isMinimized:
        result.add(win)

proc findTagForWindow(model: Model; winId: WindowId): uint32 =
  for tagId, tag in model.tags.pairs:
    if tag.containsWindow(winId):
      return tagId
  0

proc focusWindow(model: var Model; winId: WindowId; effects: var seq[Effect]) =
  let tagId = model.findTagForWindow(winId)
  if tagId == 0 or not model.windows.hasKey(winId):
    return
  var win = model.windows[winId]
  if win.isMinimized:
    win.isMinimized = false
    model.windows[winId] = win
  model.activeTag = tagId
  model.syncPrimaryOutputTag()
  var tag = model.tags[tagId]
  tag.focusedWindow = winId
  model.tags[tagId] = tag
  model.recordFocus(winId)
  effects.add(broadcastWorkspaceActivated(tagId, tag.name))
  effects.add(broadcastWindowFocusChanged(winId))
  effects.add(Effect(kind: EffFocusWindow, focusId: winId))
  effects.add(Effect(kind: EffManageDirty))

proc focusTag(model: var Model; tagId: uint32; effects: var seq[Effect]) =
  if tagId == 0 or not model.tags.hasKey(tagId):
    return
  model.activeTag = tagId
  model.syncPrimaryOutputTag()
  var tag = model.tags[tagId]
  tag.recomputeVisibleFocus(model)
  model.tags[tagId] = tag
  effects.add(broadcastWorkspaceActivated(tagId, tag.name))
  if tag.focusedWindow != 0:
    model.recordFocus(tag.focusedWindow)
    effects.add(broadcastWindowFocusChanged(tag.focusedWindow))
    effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))
  effects.add(Effect(kind: EffManageDirty))

proc nearestTag(model: Model; direction: int; occupiedOnly: bool): uint32

proc isFocusableWindow(model: Model; winId: WindowId): bool =
  model.windows.hasKey(winId) and not model.windows[winId].isMinimized

proc visibleWindowNear(model: Model; col: Column; preferredIdx: int): WindowId =
  if col.windows.len == 0:
    return 0

  let idx = clamp(preferredIdx, 0, col.windows.len - 1)
  if model.isFocusableWindow(col.windows[idx]):
    return col.windows[idx]

  for distance in 1 ..< col.windows.len:
    let before = idx - distance
    if before >= 0 and model.isFocusableWindow(col.windows[before]):
      return col.windows[before]
    let after = idx + distance
    if after < col.windows.len and model.isFocusableWindow(col.windows[after]):
      return col.windows[after]

  0

proc focusColumnByStep(model: var Model; step: int; effects: var seq[Effect]) =
  if step == 0 or not model.tags.hasKey(model.activeTag):
    return

  let tag = model.tags[model.activeTag]
  let focused = tag.focusedWindow
  let pos = tag.findWindow(focused)
  if not pos.found:
    return

  var colIdx = pos.colIdx + step
  while colIdx >= 0 and colIdx < tag.columns.len:
    let target = model.visibleWindowNear(tag.columns[colIdx], pos.winIdx)
    if target != 0:
      model.focusWindow(target, effects)
      return
    colIdx += step

proc focusColumnAtEdge(model: var Model; first: bool; effects: var seq[Effect]) =
  if not model.tags.hasKey(model.activeTag):
    return

  let tag = model.tags[model.activeTag]
  let focused = tag.focusedWindow
  let pos = tag.findWindow(focused)
  let preferredIdx = if pos.found: pos.winIdx else: 0

  if first:
    for col in tag.columns:
      let target = model.visibleWindowNear(col, preferredIdx)
      if target != 0:
        model.focusWindow(target, effects)
        return
  else:
    for i in countdown(tag.columns.len - 1, 0):
      let target = model.visibleWindowNear(tag.columns[i], preferredIdx)
      if target != 0:
        model.focusWindow(target, effects)
        return

proc focusWindowOrTag(model: var Model; direction: int; effects: var seq[Effect]) =
  if direction == 0:
    return
  if not model.tags.hasKey(model.activeTag):
    let targetTag = model.nearestTag(direction, false)
    if targetTag != 0:
      model.focusTag(targetTag, effects)
    return

  let tag = model.tags[model.activeTag]
  let focused = tag.focusedWindow
  let pos = tag.findWindow(focused)
  if pos.found:
    var winIdx = pos.winIdx + direction
    while winIdx >= 0 and winIdx < tag.columns[pos.colIdx].windows.len:
      let target = tag.columns[pos.colIdx].windows[winIdx]
      if model.isFocusableWindow(target):
        model.focusWindow(target, effects)
        return
      winIdx += direction

  let targetTag = model.nearestTag(direction, false)
  if targetTag != 0:
    model.focusTag(targetTag, effects)

proc moveFocusedWindowToTag(model: var Model; targetTagId: uint32; effects: var seq[Effect]) =
  if targetTagId == 0 or not model.tags.hasKey(model.activeTag):
    return

  let focused = model.tags[model.activeTag].focusedWindow
  if focused == 0 or not model.windows.hasKey(focused):
    return

  discard model.removeWindowFromAllTags(focused)
  discard model.removeWindowFromScratchpad(focused)
  var targetTag = model.ensureTag(targetTagId)
  targetTag.columns.add(Column(windows: @[focused], widthProportion: DefaultColumnWidth))
  targetTag.focusedWindow = focused
  model.tags[targetTagId] = targetTag
  model.focusWindow(focused, effects)

proc sortedTagIds(model: Model): seq[uint32] =
  for tagId in model.tags.keys:
    result.add(tagId)
  result.sort()

proc nearestTag(model: Model; direction: int; occupiedOnly: bool): uint32 =
  let ids = model.sortedTagIds()
  if ids.len == 0:
    return 0
  let current = model.activeTag
  if direction < 0:
    for i in countdown(ids.len - 1, 0):
      let tagId = ids[i]
      if tagId < current and (not occupiedOnly or model.activeVisibleWindows(model.tags[tagId]).len > 0):
        return tagId
  else:
    for tagId in ids:
      if tagId > current and (not occupiedOnly or model.activeVisibleWindows(model.tags[tagId]).len > 0):
        return tagId
  0

proc overviewWindows(model: Model): tuple[windows: seq[WindowId], tagIds: seq[uint32]] =
  for id in model.tags.keys:
    result.tagIds.add(id)
  result.tagIds.sort()
  for id in result.tagIds:
    let tag = model.tags[id]
    for col in tag.columns:
      for win in col.windows:
        if not model.windows.hasKey(win) or not model.windows[win].isMinimized:
          result.windows.add(win)

proc focusOverviewByStep(model: var Model; step: int; effects: var seq[Effect]) =
  let overview = model.overviewWindows()
  if overview.windows.len == 0:
    return

  let activeTagId = model.activeTag
  let currentFocus = if model.tags.hasKey(activeTagId): model.tags[activeTagId].focusedWindow else: 0'u32
  var idx = overview.windows.find(currentFocus)
  if idx == -1:
    idx = 0
  else:
    idx = (idx + step + overview.windows.len) mod overview.windows.len
  let nextFocus = overview.windows[idx]

  model.focusWindow(nextFocus, effects)

proc focusOverviewSelection(model: Model; effects: var seq[Effect]) =
  let tagId = model.activeTagOrFallback()
  if tagId != 0 and model.tags.hasKey(tagId):
    let focused = model.tags[tagId].focusedWindow
    if focused != 0 and model.windows.hasKey(focused):
      effects.add(Effect(kind: EffFocusWindow, focusId: focused))

proc focusByDirection(model: var Model; direction: Direction; effects: var seq[Effect]) =
  if model.overviewActive:
    case direction
    of DirLeft:
      model.focusColumnByStep(-1, effects)
    of DirRight:
      model.focusColumnByStep(1, effects)
    of DirUp:
      model.focusWindowOrTag(-1, effects)
    of DirDown:
      model.focusWindowOrTag(1, effects)
    return

  if not model.tags.hasKey(model.activeTag):
    return
  var tag = model.tags[model.activeTag]
  let focused = tag.focusedWindow
  var colIdx = -1
  var winIdx = -1
  for i in 0 ..< tag.columns.len:
    let j = tag.columns[i].windows.find(focused)
    if j != -1:
      colIdx = i
      winIdx = j
      break
  if colIdx == -1:
    return

  var target: WindowId = 0
  case direction
  of DirLeft:
    var i = colIdx - 1
    while i >= 0 and target == 0:
      if tag.columns[i].windows.len > 0:
        target = tag.columns[i].windows[min(winIdx, tag.columns[i].windows.len - 1)]
      dec i
  of DirRight:
    var i = colIdx + 1
    while i < tag.columns.len and target == 0:
      if tag.columns[i].windows.len > 0:
        target = tag.columns[i].windows[min(winIdx, tag.columns[i].windows.len - 1)]
      inc i
  of DirUp:
    if winIdx > 0:
      target = tag.columns[colIdx].windows[winIdx - 1]
  of DirDown:
    if winIdx >= 0 and winIdx < tag.columns[colIdx].windows.len - 1:
      target = tag.columns[colIdx].windows[winIdx + 1]

  if target != 0 and (not model.windows.hasKey(target) or not model.windows[target].isMinimized):
    tag.focusedWindow = target
    model.tags[model.activeTag] = tag
    model.recordFocus(target)
    effects.add(broadcastWindowFocusChanged(target))
    effects.add(Effect(kind: EffFocusWindow, focusId: target))

proc pruneScratchpads(model: var Model) =
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.windows.hasKey(model.scratchpadWindows[i]):
      inc i
    else:
      model.scratchpadWindows.delete(i)
  var deadNames: seq[string] = @[]
  for name, winId in model.namedScratchpads.pairs:
    if not model.windows.hasKey(winId):
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)
  if model.visibleScratchpad != 0 and not model.windows.hasKey(model.visibleScratchpad):
    model.visibleScratchpad = 0
    model.isScratchpadVisible = false

proc addScratchpad(model: var Model; winId: WindowId; name = "") =
  if winId == 0:
    return
  discard model.removeWindowFromAllTags(winId)
  if not model.scratchpadWindows.contains(winId):
    model.scratchpadWindows.add(winId)
  if name.len > 0:
    model.namedScratchpads[name] = winId
  model.visibleScratchpad = 0
  model.isScratchpadVisible = false

proc showScratchpad(model: var Model; winId: WindowId; effects: var seq[Effect]) =
  if winId == 0 or not model.windows.hasKey(winId):
    return
  var win = model.windows[winId]
  win.isMinimized = false
  win.isMaximized = false
  model.windows[winId] = win
  if not model.scratchpadWindows.contains(winId):
    model.scratchpadWindows.add(winId)
  model.visibleScratchpad = winId
  model.isScratchpadVisible = true
  model.recordFocus(winId)
  effects.add(broadcastWindowFocusChanged(winId))
  effects.add(Effect(kind: EffFocusWindow, focusId: winId))
  effects.add(Effect(kind: EffManageDirty))

proc hideScratchpad(model: var Model; effects: var seq[Effect]) =
  model.visibleScratchpad = 0
  model.isScratchpadVisible = false
  let focused = model.focusedOnActiveTag()
  if focused != 0:
    effects.add(Effect(kind: EffFocusWindow, focusId: focused))
  effects.add(Effect(kind: EffManageDirty))

proc restoreScratchpad(model: var Model; effects: var seq[Effect]) =
  model.pruneScratchpads()
  let winId =
    if model.visibleScratchpad != 0: model.visibleScratchpad
    elif model.scratchpadWindows.len > 0: model.scratchpadWindows[^1]
    else: 0'u32
  if winId == 0:
    return
  var i = 0
  while i < model.scratchpadWindows.len:
    if model.scratchpadWindows[i] == winId:
      model.scratchpadWindows.delete(i)
    else:
      inc i
  var deadNames: seq[string] = @[]
  for name, namedWin in model.namedScratchpads.pairs:
    if namedWin == winId:
      deadNames.add(name)
  for name in deadNames:
    model.namedScratchpads.del(name)
  model.visibleScratchpad = 0
  model.isScratchpadVisible = false
  let tagId = if model.activeTag == 0: 1'u32 else: model.activeTag
  var tag = model.ensureTag(tagId)
  tag.columns.add(Column(windows: @[winId], widthProportion: DefaultColumnWidth))
  tag.focusedWindow = winId
  model.tags[tagId] = tag
  model.focusWindow(winId, effects)

proc update*(model: Model, msg: Msg): (Model, seq[Effect]) =
  var nextModel = model
  var effects: seq[Effect] = @[]

  if model.sessionLocked and msg.kind.isFocusChangingCommand():
    return (nextModel, effects)

  case msg.kind
  of WlOutputDimensions:
    if msg.outputId == 0:
      nextModel.screenWidth = max(0'i32, msg.width)
      nextModel.screenHeight = max(0'i32, msg.height)
    else:
      var output = nextModel.outputs.getOrDefault(msg.outputId, OutputData(id: msg.outputId))
      output.w = max(0'i32, msg.width)
      output.h = max(0'i32, msg.height)
      nextModel.outputs[msg.outputId] = output
      nextModel.syncPrimaryOutput()
      nextModel.syncPrimaryOutputTag()

  of WlOutputName:
    if msg.nameOutputId != 0:
      var output = nextModel.outputs.getOrDefault(msg.nameOutputId, OutputData(id: msg.nameOutputId))
      output.name = msg.outputName.strip()
      nextModel.outputs[msg.nameOutputId] = output

  of WlOutputPosition:
    if msg.positionOutputId != 0:
      var output = nextModel.outputs.getOrDefault(msg.positionOutputId, OutputData(id: msg.positionOutputId))
      output.x = msg.outputX
      output.y = msg.outputY
      nextModel.outputs[msg.positionOutputId] = output
      nextModel.syncPrimaryOutput()
      nextModel.syncPrimaryOutputTag()

  of WlOutputUsable:
    if msg.usableOutputId != 0:
      var output = nextModel.outputs.getOrDefault(msg.usableOutputId, OutputData(id: msg.usableOutputId))
      output.usableX = msg.usableX
      output.usableY = msg.usableY
      output.usableW = max(0'i32, msg.usableW)
      output.usableH = max(0'i32, msg.usableH)
      output.hasUsable = true
      nextModel.outputs[msg.usableOutputId] = output
      nextModel.syncPrimaryOutput()
      nextModel.syncPrimaryOutputTag()

  of WlOutputRemoved:
    if msg.removedOutputId != 0:
      nextModel.outputs.del(msg.removedOutputId)
      nextModel.outputTags.del(msg.removedOutputId)
      if nextModel.primaryOutput == msg.removedOutputId:
        nextModel.primaryOutput = 0
      nextModel.syncPrimaryOutput()
      nextModel.syncPrimaryOutputTag()
      var clearedFullscreen: seq[WindowId] = @[]
      for winId, win in nextModel.windows.pairs:
        if win.isFullscreen and win.fullscreenOutput == msg.removedOutputId:
          clearedFullscreen.add(winId)
      for winId in clearedFullscreen:
        var win = nextModel.windows[winId]
        win.isFullscreen = false
        win.fullscreenOutput = 0
        nextModel.windows[winId] = win
        effects.add(Effect(kind: EffSetFullscreen, fsWinId: winId, isFullscreen: false))
      if clearedFullscreen.len > 0:
        effects.add(Effect(kind: EffManageDirty))

  of WlWindowCreated:
    discard nextModel.removeWindowFromAllTags(msg.windowId)
    discard nextModel.removeWindowFromScratchpad(msg.windowId)

    var win = WindowData(id: msg.windowId, appId: msg.appId, title: msg.title, identifier: msg.createdIdentifier, widthProportion: DefaultWindowWidth, heightProportion: DefaultWindowHeight)
    var hasRestoredTag = false
    var targetTag = if nextModel.activeTag == 0: 1'u32 else: nextModel.activeTag
    if nextModel.restoreTagByWindow.hasKey(msg.windowId):
      targetTag = nextModel.restoreTagByWindow[msg.windowId]
      nextModel.restoreTagByWindow.del(msg.windowId)
      hasRestoredTag = targetTag != 0
    var forcedLayout = 0
    for rule in nextModel.windowRules:
      let appIdMatches = rule.appIdMatch == "" or msg.appId.contains(rule.appIdMatch)
      let titleMatches = rule.titleMatch == "" or msg.title.contains(rule.titleMatch)
      if appIdMatches and titleMatches:
        if rule.defaultTag != 0 and not hasRestoredTag: targetTag = rule.defaultTag
        if rule.openFloating:
          win.isFloating = true
          win.floatingGeom = Rect(x: nextModel.screenWidth div 4, y: nextModel.screenHeight div 4, w: nextModel.screenWidth div 2, h: nextModel.screenHeight div 2)
        if rule.forcedLayout != 0: forcedLayout = rule.forcedLayout
        break
    nextModel.windows[msg.windowId] = win
    if not nextModel.tags.hasKey(targetTag):
      nextModel.tags[targetTag] = initTagState(targetTag, if forcedLayout != 0: safeLayoutMode(forcedLayout) else: Scroller)
    elif forcedLayout != 0:
      var tag = nextModel.tags[targetTag]
      tag.layoutMode = safeLayoutMode(forcedLayout, tag.layoutMode)
      nextModel.tags[targetTag] = tag
    var tag = nextModel.tags[targetTag]
    tag.columns.add(Column(windows: @[msg.windowId], widthProportion: DefaultColumnWidth))
    if not nextModel.sessionLocked:
      tag.focusedWindow = msg.windowId
    nextModel.tags[targetTag] = tag
    effects.add(nextModel.broadcastWindowOpened(win))
    effects.add(Effect(kind: EffManageDirty))

  of WlWindowDestroyed:
    nextModel.windows.del(msg.destroyedId)
    discard nextModel.removeWindowFromAllTags(msg.destroyedId)
    discard nextModel.removeWindowFromScratchpad(msg.destroyedId)
    if nextModel.pointerOp.windowId == msg.destroyedId:
      nextModel.pointerOp = PointerOpState(kind: OpNone)
    effects.add(broadcastWindowClosed(msg.destroyedId))
    effects.add(Effect(kind: EffManageDirty))

  of WlWindowDimensions:
    if nextModel.windows.hasKey(msg.dimensionsWindowId):
      var win = nextModel.windows[msg.dimensionsWindowId]
      win.actualW = max(0'i32, msg.actualWidth)
      win.actualH = max(0'i32, msg.actualHeight)
      nextModel.windows[msg.dimensionsWindowId] = win

  of WlWindowDecorationHint:
    if nextModel.windows.hasKey(msg.decorationWindowId):
      var win = nextModel.windows[msg.decorationWindowId]
      win.hasDecorationHint = true
      win.decorationHint = msg.decorationHint
      nextModel.windows[msg.decorationWindowId] = win
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowPresentationHint:
    if nextModel.windows.hasKey(msg.presentationWindowId):
      var win = nextModel.windows[msg.presentationWindowId]
      win.hasPresentationHint = true
      win.presentationHint = msg.presentationHint
      nextModel.windows[msg.presentationWindowId] = win

  of WlWindowMenuRequested:
    if nextModel.windowMenu.command.len > 0 and nextModel.windows.hasKey(msg.menuWindowId):
      effects.add(Effect(
        kind: EffSpawnWindowMenu,
        windowMenuCommand: nextModel.windowMenu.command,
        windowMenuId: msg.menuWindowId,
        windowMenuX: msg.menuX,
        windowMenuY: msg.menuY))

  of WlShellSurfaceInteraction:
    if msg.shellSurfaceId != 0 and not nextModel.sessionLocked and not nextModel.layerFocusExclusive:
      effects.add(Effect(kind: EffFocusShellSurface, focusShellSurfaceId: msg.shellSurfaceId))

  of WlModifiersChanged:
    nextModel.activeModifiers = msg.newModifiers

  of WlFocusChanged:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      if msg.newFocusedId == 0 or tag.containsWindow(msg.newFocusedId):
        tag.focusedWindow = msg.newFocusedId
        nextModel.tags[nextModel.activeTag] = tag
        nextModel.recordFocus(msg.newFocusedId)
        effects.add(broadcastWindowFocusChanged(msg.newFocusedId))
        if msg.newFocusedId != 0:
          effects.add(Effect(kind: EffFocusWindow, focusId: msg.newFocusedId))

  of WlSessionLocked:
    nextModel.sessionLocked = true
    nextModel.pointerOp = PointerOpState(kind: OpNone)
    effects.add(Effect(kind: EffManageDirty))

  of WlSessionUnlocked:
    nextModel.sessionLocked = false
    let focused = nextModel.focusedOnActiveTag()
    if focused != 0:
      effects.add(broadcastWindowFocusChanged(focused))
      effects.add(Effect(kind: EffFocusWindow, focusId: focused))
    effects.add(Effect(kind: EffManageDirty))

  of WlWindowFullscreenRequested:
    if nextModel.windows.hasKey(msg.fullscreenRequestId):
      var win = nextModel.windows[msg.fullscreenRequestId]
      let outputId = nextModel.chooseFullscreenOutput(msg.fullscreenOutputId)
      win.isFullscreen = true
      win.fullscreenOutput = outputId
      nextModel.windows[msg.fullscreenRequestId] = win
      effects.add(Effect(kind: EffSetFullscreen, fsWinId: msg.fullscreenRequestId, isFullscreen: true, fsOutputId: outputId))
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowExitFullscreenRequested:
    if nextModel.windows.hasKey(msg.exitFullscreenRequestId):
      var win = nextModel.windows[msg.exitFullscreenRequestId]
      win.isFullscreen = false
      win.fullscreenOutput = 0
      nextModel.windows[msg.exitFullscreenRequestId] = win
      effects.add(Effect(kind: EffSetFullscreen, fsWinId: msg.exitFullscreenRequestId, isFullscreen: false))
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowMaximizeRequested:
    if nextModel.windows.hasKey(msg.maximizeRequestId):
      var win = nextModel.windows[msg.maximizeRequestId]
      win.isMaximized = true
      win.isMinimized = false
      nextModel.windows[msg.maximizeRequestId] = win
      effects.add(Effect(kind: EffSetMaximized, maxWinId: msg.maximizeRequestId, isMaximized: true))
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowUnmaximizeRequested:
    if nextModel.windows.hasKey(msg.unmaximizeRequestId):
      var win = nextModel.windows[msg.unmaximizeRequestId]
      win.isMaximized = false
      nextModel.windows[msg.unmaximizeRequestId] = win
      effects.add(Effect(kind: EffSetMaximized, maxWinId: msg.unmaximizeRequestId, isMaximized: false))
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowMinimizeRequested:
    if nextModel.windows.hasKey(msg.minimizeRequestId):
      var win = nextModel.windows[msg.minimizeRequestId]
      win.isMinimized = true
      win.isMaximized = false
      nextModel.windows[msg.minimizeRequestId] = win
      for tagId, tag in nextModel.tags.mpairs:
        if tag.focusedWindow == msg.minimizeRequestId:
          tag.recomputeVisibleFocus(nextModel)
          if tagId == nextModel.activeTag and tag.focusedWindow != 0:
            effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))
      effects.add(Effect(kind: EffSetMaximized, maxWinId: msg.minimizeRequestId, isMaximized: false))
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowParent:
    if nextModel.windows.hasKey(msg.childWindowId):
      var win = nextModel.windows[msg.childWindowId]
      win.parentId = msg.parentWindowId
      nextModel.windows[msg.childWindowId] = win
      effects.add(Effect(kind: EffManageDirty))

  of WlWindowIdentifier:
    if nextModel.windows.hasKey(msg.identifierWindowId):
      var win = nextModel.windows[msg.identifierWindowId]
      win.identifier = msg.identifier
      nextModel.windows[msg.identifierWindowId] = win

  of WlWindowAppId:
    if nextModel.windows.hasKey(msg.appIdWindowId):
      var win = nextModel.windows[msg.appIdWindowId]
      win.appId = msg.updatedAppId
      nextModel.windows[msg.appIdWindowId] = win
      effects.add(nextModel.broadcastWindowOpened(win))

  of WlWindowTitle:
    if nextModel.windows.hasKey(msg.titleWindowId):
      var win = nextModel.windows[msg.titleWindowId]
      win.title = msg.updatedTitle
      nextModel.windows[msg.titleWindowId] = win
      effects.add(nextModel.broadcastWindowOpened(win))

  of WlWindowDimensionsHint:
    if nextModel.windows.hasKey(msg.hintWindowId):
      var win = nextModel.windows[msg.hintWindowId]
      win.minWidth = max(0'i32, msg.minWidth)
      win.minHeight = max(0'i32, msg.minHeight)
      win.maxWidth = max(0'i32, msg.maxWidth)
      win.maxHeight = max(0'i32, msg.maxHeight)
      if win.maxWidth > 0 and win.maxWidth < win.minWidth:
        win.maxWidth = win.minWidth
      if win.maxHeight > 0 and win.maxHeight < win.minHeight:
        win.maxHeight = win.minHeight
      nextModel.windows[msg.hintWindowId] = win

  of WlLayerFocusExclusive:
    nextModel.layerFocusExclusive = true
    effects.add(Effect(kind: EffManageDirty))

  of WlLayerFocusNonExclusive, WlLayerFocusNone:
    nextModel.layerFocusExclusive = false
    effects.add(Effect(kind: EffManageDirty))

  of WlPointerMoveRequested:
    if nextModel.windows.hasKey(msg.moveWinId):
      let win = nextModel.windows[msg.moveWinId]
      if win.isFloating:
        nextModel.pointerOp = PointerOpState(kind: OpMove, windowId: msg.moveWinId, initialGeom: win.floatingGeom)
        effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.moveSeat))

  of WlPointerResizeRequested:
    if nextModel.windows.hasKey(msg.resizeWinId):
      let win = nextModel.windows[msg.resizeWinId]
      if win.isFloating:
        nextModel.pointerOp = PointerOpState(kind: OpResize, windowId: msg.resizeWinId, initialGeom: win.floatingGeom, edges: msg.resizeEdges)
        effects.add(Effect(kind: EffInformResizeStart, resizeLifecycleWinId: msg.resizeWinId))
        effects.add(Effect(kind: EffOpStartPointer, opSeat: msg.resizeSeat))

  of WlPointerDelta:
    let op = nextModel.pointerOp
    if op.kind != OpNone and nextModel.windows.hasKey(op.windowId):
      var win = nextModel.windows[op.windowId]
      if op.kind == OpMove:
        win.floatingGeom.x = op.initialGeom.x + msg.dx
        win.floatingGeom.y = op.initialGeom.y + msg.dy
      elif op.kind == OpResize:
        if (op.edges and 1) != 0:
          win.floatingGeom.y = op.initialGeom.y + msg.dy
          win.floatingGeom.h = max(50, op.initialGeom.h - msg.dy)
        elif (op.edges and 2) != 0: win.floatingGeom.h = max(50, op.initialGeom.h + msg.dy)
        if (op.edges and 4) != 0:
          win.floatingGeom.x = op.initialGeom.x + msg.dx
          win.floatingGeom.w = max(50, op.initialGeom.w - msg.dx)
        elif (op.edges and 8) != 0: win.floatingGeom.w = max(50, op.initialGeom.w + msg.dx)
      nextModel.windows[op.windowId] = win
      effects.add(Effect(kind: EffManageDirty))

  of WlPointerRelease:
    if nextModel.pointerOp.kind == OpResize and nextModel.pointerOp.windowId != 0:
      effects.add(Effect(kind: EffInformResizeEnd, resizeLifecycleWinId: nextModel.pointerOp.windowId))
    nextModel.pointerOp = PointerOpState(kind: OpNone)

  of CmdSetLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.layoutMode = msg.newLayout
      nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdSwitchLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      let cycle = if nextModel.layoutCycle.len > 0: nextModel.layoutCycle else: @[Scroller, MasterStack, Grid, Monocle, VerticalScroller]
      let idx = cycle.find(tag.layoutMode)
      tag.layoutMode = cycle[if idx == -1: 0 else: (idx + 1) mod cycle.len]
      nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdMoveToTag:
    let activeTagId = nextModel.activeTag
    let targetTagId = if msg.targetTag == 0: activeTagId else: msg.targetTag
    if nextModel.tags.hasKey(activeTagId) and targetTagId != 0:
      let focused = nextModel.tags[activeTagId].focusedWindow
      if focused != 0 and nextModel.tags[activeTagId].containsWindow(focused):
        discard nextModel.removeWindowFromAllTags(focused)
        discard nextModel.removeWindowFromScratchpad(focused)
        var targetTag = nextModel.ensureTag(targetTagId)
        targetTag.columns.add(Column(windows: @[focused], widthProportion: DefaultColumnWidth))
        targetTag.focusedWindow = focused
        nextModel.tags[targetTagId] = targetTag
        if nextModel.overviewActive: nextModel.activeTag = targetTagId
        let broadcastTag = nextModel.activeTagOrFallback()
        if broadcastTag != 0:
          effects.add(broadcastWorkspaceActivated(broadcastTag, nextModel.tags[broadcastTag].name))
        effects.add(Effect(kind: EffManageDirty))

  of CmdSwapWindowToTag:
    let activeTagId = nextModel.activeTag
    let targetTagId = msg.targetTagSwap
    if nextModel.tags.hasKey(activeTagId) and targetTagId != 0:
      let activeFocused = nextModel.tags[activeTagId].focusedWindow
      if activeFocused != 0 and nextModel.tags[activeTagId].containsWindow(activeFocused):
        if not nextModel.tags.hasKey(targetTagId) or nextModel.tags[targetTagId].columns.len == 0:
          return update(nextModel, Msg(kind: CmdMoveToTag, targetTag: targetTagId))
        var activeTag = nextModel.tags[activeTagId]
        var targetTag = nextModel.tags[targetTagId]
        let targetFocused = targetTag.focusedWindow
        if targetFocused == 0 or not targetTag.containsWindow(targetFocused):
          return update(nextModel, Msg(kind: CmdMoveToTag, targetTag: targetTagId))
        let activePos = activeTag.findWindow(activeFocused)
        let targetPos = targetTag.findWindow(targetFocused)
        if activePos.found and targetPos.found:
          activeTag.columns[activePos.colIdx].windows[activePos.winIdx] = targetFocused
          targetTag.columns[targetPos.colIdx].windows[targetPos.winIdx] = activeFocused
          activeTag.focusedWindow = targetFocused
          targetTag.focusedWindow = activeFocused
          nextModel.tags[activeTagId] = activeTag
          nextModel.tags[targetTagId] = targetTag
          effects.add(broadcastWorkspaceActivated(activeTagId, activeTag.name))
          effects.add(Effect(kind: EffManageDirty))

  of CmdRenameTag:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.name = msg.newName
      nextModel.tags[nextModel.activeTag] = tag
      effects.add(broadcastWorkspaceActivated(nextModel.activeTag, tag.name))

  of CmdGroupWindows:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      let tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0 and tag.containsWindow(focused):
        let gid = nextModel.nextGroupId + 1; nextModel.nextGroupId = gid
        nextModel.groups[gid] = GroupState(id: gid, windows: @[focused], activeWindow: focused)
        effects.add(Effect(kind: EffManageDirty))

  of CmdUngroupWindow: effects.add(Effect(kind: EffManageDirty))
  of CmdFocusNextInGroup: effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterCount:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.masterCount = max(1, msg.count); nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdAdjustMasterCount:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.masterCount = max(1, tag.masterCount + msg.deltaMC); nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterRatio:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.masterSplitRatio = clamp(msg.ratio, 0.05, 0.95); nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdAdjustMasterRatio:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.masterSplitRatio = clamp(tag.masterSplitRatio + msg.deltaMR, 0.05, 0.95); nextModel.tags[nextModel.activeTag] = tag
      effects.add(Effect(kind: EffManageDirty))

  of CmdResizeWidth:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        if tag.layoutMode == Scroller:
          for i in 0 ..< tag.columns.len:
            if tag.columns[i].windows.contains(focused): tag.columns[i].widthProportion = clamp(tag.columns[i].widthProportion + msg.deltaW, 0.05, 1.0); break
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))
        elif tag.layoutMode == VerticalScroller:
          if nextModel.windows.hasKey(focused):
            var win = nextModel.windows[focused]; win.widthProportion = clamp(win.widthProportion + msg.deltaW, 0.05, 1.0)
            nextModel.windows[focused] = win; effects.add(Effect(kind: EffManageDirty))
        elif tag.layoutMode == MasterStack:
          tag.masterSplitRatio = clamp(tag.masterSplitRatio + msg.deltaW, 0.05, 0.95); nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))

  of CmdResizeHeight:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        if tag.layoutMode == VerticalScroller:
          for i in 0 ..< tag.columns.len:
            if tag.columns[i].windows.contains(focused): tag.columns[i].widthProportion = clamp(tag.columns[i].widthProportion + msg.deltaH, 0.05, 1.0); break
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))
        elif tag.layoutMode == Scroller:
          if nextModel.windows.hasKey(focused):
            var win = nextModel.windows[focused]; win.heightProportion = clamp(win.heightProportion + msg.deltaH, 0.05, 1.0)
            nextModel.windows[focused] = win; effects.add(Effect(kind: EffManageDirty))

  of CmdResizeFloating:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]
        if win.isFloating:
          win.floatingGeom.w = max(50, win.floatingGeom.w + msg.deltaFW); win.floatingGeom.h = max(50, win.floatingGeom.h + msg.deltaFH)
          nextModel.windows[focused] = win; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveFloating:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      let focused = nextModel.tags[activeTagId].focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]
        if win.isFloating:
          win.floatingGeom.x += msg.moveDX; win.floatingGeom.y += msg.moveDY
          nextModel.windows[focused] = win; effects.add(Effect(kind: EffManageDirty))

  of CmdAdjustGaps:
    nextModel.outerGaps = max(0, nextModel.outerGaps + msg.deltaG); nextModel.innerGaps = nextModel.outerGaps div 2
    effects.add(Effect(kind: EffManageDirty))

  of CmdToggleGaps:
    if nextModel.outerGaps > 0:
      nextModel.previousOuterGaps = nextModel.outerGaps; nextModel.previousInnerGaps = nextModel.innerGaps
      nextModel.outerGaps = 0; nextModel.innerGaps = 0
    else: nextModel.outerGaps = nextModel.previousOuterGaps; nextModel.innerGaps = nextModel.previousInnerGaps
    effects.add(Effect(kind: EffManageDirty))

  of CmdSetColumnWidth:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        if tag.layoutMode == Scroller:
          for i in 0 ..< tag.columns.len:
            if tag.columns[i].windows.contains(focused):
              tag.columns[i].widthProportion = clamp(msg.targetWidth, 0.05, 1.0)
              break
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdConsumeWindow:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused): colIdx = i; break
        if colIdx != -1 and colIdx < tag.columns.len - 1 and tag.columns[colIdx + 1].windows.len > 0:
          let nextColWin = tag.columns[colIdx+1].windows[0]; tag.columns[colIdx+1].windows.delete(0)
          tag.columns[colIdx].windows.add(nextColWin)
          if tag.columns[colIdx+1].windows.len == 0: tag.columns.delete(colIdx+1)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdExpelWindow:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1; var winIdx = -1
        for i in 0 ..< tag.columns.len:
          let j = tag.columns[i].windows.find(focused); if j != -1: colIdx = i; winIdx = j; break
        if colIdx != -1 and tag.columns[colIdx].windows.len > 1:
          tag.columns[colIdx].windows.delete(winIdx)
          tag.columns.insert(Column(windows: @[focused], widthProportion: 0.5), colIdx + 1)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdZoom:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0 and tag.columns.len > 0 and tag.columns[0].windows.len > 0:
        let master = tag.columns[0].windows[0]
        if focused != master:
          for i in 0 ..< tag.columns.len:
            let j = tag.columns[i].windows.find(focused)
            if j != -1:
              tag.columns[i].windows[j] = master; tag.columns[0].windows[0] = focused; break
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveToScratchpad:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      let focused = nextModel.tags[activeTagId].focusedWindow
      if focused != 0 and nextModel.tags[activeTagId].containsWindow(focused):
        nextModel.addScratchpad(focused)
        effects.add(Effect(kind: EffManageDirty))

  of CmdMoveToNamedScratchpad:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId) and msg.scratchpadName.strip().len > 0:
      let focused = nextModel.tags[activeTagId].focusedWindow
      if focused != 0 and nextModel.tags[activeTagId].containsWindow(focused):
        nextModel.addScratchpad(focused, msg.scratchpadName.strip())
        effects.add(Effect(kind: EffManageDirty))

  of CmdToggleScratchpad:
    nextModel.pruneScratchpads()
    if nextModel.isScratchpadVisible:
      nextModel.hideScratchpad(effects)
    elif nextModel.scratchpadWindows.len > 0:
      nextModel.showScratchpad(nextModel.scratchpadWindows[^1], effects)

  of CmdToggleNamedScratchpad:
    let name = msg.scratchpadName.strip()
    if name.len > 0:
      nextModel.pruneScratchpads()
      if nextModel.namedScratchpads.hasKey(name):
        let winId = nextModel.namedScratchpads[name]
        if nextModel.isScratchpadVisible and nextModel.visibleScratchpad == winId:
          nextModel.hideScratchpad(effects)
        else:
          nextModel.showScratchpad(winId, effects)
      elif nextModel.tags.hasKey(nextModel.activeTag):
        let focused = nextModel.tags[nextModel.activeTag].focusedWindow
        if focused != 0 and nextModel.tags[nextModel.activeTag].containsWindow(focused):
          nextModel.addScratchpad(focused, name)
          nextModel.showScratchpad(focused, effects)

  of CmdRestoreScratchpad:
    nextModel.restoreScratchpad(effects)

  of CmdMoveColumnLeft:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused): colIdx = i; break
        if colIdx > 0:
          let temp = tag.columns[colIdx]; tag.columns[colIdx] = tag.columns[colIdx-1]; tag.columns[colIdx-1] = temp
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveColumnRight:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused): colIdx = i; break
        if colIdx != -1 and colIdx < tag.columns.len - 1:
          let temp = tag.columns[colIdx]; tag.columns[colIdx] = tag.columns[colIdx+1]; tag.columns[colIdx+1] = temp
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveColumnToFirst:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused): colIdx = i; break
        if colIdx > 0:
          let col = tag.columns[colIdx]
          tag.columns.delete(colIdx)
          tag.columns.insert(col, 0)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveColumnToLast:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused): colIdx = i; break
        if colIdx != -1 and colIdx < tag.columns.len - 1:
          let col = tag.columns[colIdx]
          tag.columns.delete(colIdx)
          tag.columns.add(col)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveWindowLeft:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1; var winIdx = -1
        for i in 0 ..< tag.columns.len:
          let j = tag.columns[i].windows.find(focused); if j != -1: colIdx = i; winIdx = j; break
        if colIdx != -1:
          tag.columns[colIdx].windows.delete(winIdx)
          if colIdx > 0: tag.columns[colIdx-1].windows.add(focused)
          else: tag.columns.insert(Column(windows: @[focused], widthProportion: 0.5), 0)
          for i in countdown(tag.columns.len - 1, 0):
            if tag.columns[i].windows.len == 0: tag.columns.delete(i)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveWindowRight:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1; var winIdx = -1
        for i in 0 ..< tag.columns.len:
          let j = tag.columns[i].windows.find(focused); if j != -1: colIdx = i; winIdx = j; break
        if colIdx != -1:
          tag.columns[colIdx].windows.delete(winIdx)
          if colIdx < tag.columns.len - 1: tag.columns[colIdx+1].windows.insert(focused, 0)
          else: tag.columns.add(Column(windows: @[focused], widthProportion: 0.5))
          for i in countdown(tag.columns.len - 1, 0):
            if tag.columns[i].windows.len == 0: tag.columns.delete(i)
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))

  of CmdMoveWindowUp:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx > 0:
            let temp = tag.columns[i].windows[idx]; tag.columns[i].windows[idx] = tag.columns[i].windows[idx-1]; tag.columns[i].windows[idx-1] = temp
            nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty)); break

  of CmdMoveWindowDown:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx != -1 and idx < tag.columns[i].windows.len - 1:
            let temp = tag.columns[i].windows[idx]; tag.columns[i].windows[idx] = tag.columns[i].windows[idx+1]; tag.columns[i].windows[idx+1] = temp
            nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty)); break

  of CmdMoveWindowUpOrToWorkspaceUp:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        let pos = tag.findWindow(focused)
        if pos.found and pos.winIdx > 0:
          let temp = tag.columns[pos.colIdx].windows[pos.winIdx]
          tag.columns[pos.colIdx].windows[pos.winIdx] = tag.columns[pos.colIdx].windows[pos.winIdx - 1]
          tag.columns[pos.colIdx].windows[pos.winIdx - 1] = temp
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))
        else:
          let target = nextModel.nearestTag(-1, false)
          if target != 0:
            nextModel.moveFocusedWindowToTag(target, effects)

  of CmdMoveWindowDownOrToWorkspaceDown:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        let pos = tag.findWindow(focused)
        if pos.found and pos.winIdx < tag.columns[pos.colIdx].windows.len - 1:
          let temp = tag.columns[pos.colIdx].windows[pos.winIdx]
          tag.columns[pos.colIdx].windows[pos.winIdx] = tag.columns[pos.colIdx].windows[pos.winIdx + 1]
          tag.columns[pos.colIdx].windows[pos.winIdx + 1] = temp
          nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty))
        else:
          let target = nextModel.nearestTag(1, false)
          if target != 0:
            nextModel.moveFocusedWindowToTag(target, effects)

  of CmdSwapWindowUp:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx > 0:
            let temp = tag.columns[i].windows[idx]; tag.columns[i].windows[idx] = tag.columns[i].windows[idx-1]; tag.columns[i].windows[idx-1] = temp
            nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty)); break

  of CmdSwapWindowDown:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx != -1 and idx < tag.columns[i].windows.len - 1:
            let temp = tag.columns[i].windows[idx]; tag.columns[i].windows[idx] = tag.columns[i].windows[idx+1]; tag.columns[i].windows[idx+1] = temp
            nextModel.tags[activeTagId] = tag; effects.add(Effect(kind: EffManageDirty)); break

  of CmdToggleOverview:
    if nextModel.overviewActive:
      return update(nextModel, Msg(kind: CmdCloseOverview))
    else:
      return update(nextModel, Msg(kind: CmdOpenOverview))

  of CmdOpenOverview:
    if not nextModel.overviewActive:
      nextModel.overviewActive = true
      effects.add(Effect(kind: EffManageDirty))
      effects.add(broadcastOverview(true))
      effects.add(Effect(kind: EffFocusShellUi))

  of CmdCloseOverview:
    if nextModel.overviewActive:
      nextModel.overviewActive = false
      effects.add(Effect(kind: EffManageDirty))
      effects.add(broadcastOverview(false))
      nextModel.focusOverviewSelection(effects)

  of CmdToggleFloating:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let activeTagId = nextModel.activeTag; var tag = nextModel.tags[activeTagId]; let focused = tag.focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]; win.isFloating = not win.isFloating
        if win.isFloating: win.floatingGeom = Rect(x: nextModel.screenWidth div 4, y: nextModel.screenHeight div 4, w: nextModel.screenWidth div 2, h: nextModel.screenHeight div 2)
        nextModel.windows[focused] = win; effects.add(Effect(kind: EffManageDirty))

  of CmdToggleFullscreen:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]; win.isFullscreen = not win.isFullscreen; nextModel.windows[focused] = win
        if not win.isFullscreen:
          win.fullscreenOutput = 0
          nextModel.windows[focused] = win
        else:
          win.fullscreenOutput = nextModel.chooseFullscreenOutput(0)
          nextModel.windows[focused] = win
        effects.add(Effect(kind: EffSetFullscreen, fsWinId: focused, isFullscreen: win.isFullscreen, fsOutputId: win.fullscreenOutput)); effects.add(Effect(kind: EffManageDirty))

  of CmdToggleMaximized:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]
        win.isMaximized = not win.isMaximized
        if win.isMaximized:
          win.isMinimized = false
        nextModel.windows[focused] = win
        effects.add(Effect(kind: EffSetMaximized, maxWinId: focused, isMaximized: win.isMaximized))
        effects.add(Effect(kind: EffManageDirty))

  of CmdMinimize:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0:
        return update(nextModel, Msg(kind: WlWindowMinimizeRequested, minimizeRequestId: focused))

  of CmdSelectWindow:
    let wasOverviewActive = nextModel.overviewActive
    nextModel.overviewActive = false
    let tagId = nextModel.activeTagOrFallback()
    if tagId != 0:
      nextModel.activeTag = tagId
      effects.add(broadcastWorkspaceActivated(tagId, nextModel.tags[tagId].name))
    if wasOverviewActive:
      effects.add(broadcastOverview(false))
    nextModel.focusOverviewSelection(effects)
    effects.add(Effect(kind: EffManageDirty))

  of CmdFocusTag:
    nextModel.focusTag(msg.focusTag, effects)

  of CmdFocusWindowById:
    nextModel.focusWindow(msg.focusWindowId, effects)

  of CmdCloseWindowById:
    if nextModel.windows.hasKey(msg.closeWindowId):
      effects.add(Effect(kind: EffCloseWindow, closeId: msg.closeWindowId))

  of CmdSpawn:
    if msg.spawnCommand.len > 0:
      effects.add(Effect(kind: EffSpawn, spawnCommand: msg.spawnCommand))

  of CmdTick:
    if nextModel.enableAnimations:
      var changed = false; let speed = nextModel.animationSpeed; let epsilon: float32 = 0.5
      for tagId, tag in nextModel.tags.mpairs:
        let dx = tag.targetViewportXOffset - tag.currentViewportXOffset
        if abs(dx) > epsilon: tag.currentViewportXOffset += dx * speed; changed = true
        else: tag.currentViewportXOffset = tag.targetViewportXOffset
        let dy = tag.targetViewportYOffset - tag.currentViewportYOffset
        if abs(dy) > epsilon: tag.currentViewportYOffset += dy * speed; changed = true
        else: tag.currentViewportYOffset = tag.targetViewportYOffset
      if changed: effects.add(Effect(kind: EffManageDirty))

  of CmdFocusDirection:
    nextModel.focusByDirection(msg.direction, effects)

  of CmdFocusLast:
    let current = nextModel.focusedOnActiveTag()
    for i in countdown(nextModel.focusHistory.len - 1, 0):
      let candidate = nextModel.focusHistory[i]
      if candidate != current and nextModel.windows.hasKey(candidate) and not nextModel.windows[candidate].isMinimized:
        nextModel.focusWindow(candidate, effects)
        break

  of CmdFocusTagLeft:
    nextModel.focusTag(nextModel.nearestTag(-1, false), effects)

  of CmdFocusTagRight:
    nextModel.focusTag(nextModel.nearestTag(1, false), effects)

  of CmdFocusColumnFirst:
    nextModel.focusColumnAtEdge(true, effects)

  of CmdFocusColumnLast:
    nextModel.focusColumnAtEdge(false, effects)

  of CmdFocusWindowOrWorkspaceUp:
    nextModel.focusWindowOrTag(-1, effects)

  of CmdFocusWindowOrWorkspaceDown:
    nextModel.focusWindowOrTag(1, effects)

  of CmdFocusOccupiedTagLeft:
    nextModel.focusTag(nextModel.nearestTag(-1, true), effects)

  of CmdFocusOccupiedTagRight:
    nextModel.focusTag(nextModel.nearestTag(1, true), effects)

  of CmdMoveToTagLeft:
    let target = nextModel.nearestTag(-1, false)
    if target != 0:
      return update(nextModel, Msg(kind: CmdMoveToTag, targetTag: target))

  of CmdMoveToTagRight:
    let target = nextModel.nearestTag(1, false)
    if target != 0:
      return update(nextModel, Msg(kind: CmdMoveToTag, targetTag: target))

  of CmdFocusNext:
    if nextModel.overviewActive:
      nextModel.focusOverviewByStep(1, effects)
    elif nextModel.tags.hasKey(nextModel.activeTag):
      let activeTagId = nextModel.activeTag; var tag = nextModel.tags[activeTagId]; var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows:
          if not nextModel.windows.hasKey(win) or not nextModel.windows[win].isMinimized:
            allWindows.add(win)
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow); let nextIdx = (if idx == -1: 0 else: (idx + 1) mod allWindows.len)
        tag.focusedWindow = allWindows[nextIdx]; nextModel.tags[activeTagId] = tag
        nextModel.recordFocus(tag.focusedWindow)
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow)); effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdFocusPrev:
    if nextModel.overviewActive:
      nextModel.focusOverviewByStep(-1, effects)
    elif nextModel.tags.hasKey(nextModel.activeTag):
      let activeTagId = nextModel.activeTag; var tag = nextModel.tags[activeTagId]; var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows:
          if not nextModel.windows.hasKey(win) or not nextModel.windows[win].isMinimized:
            allWindows.add(win)
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow); let prevIdx = (if idx - 1 < 0: allWindows.len - 1 else: idx - 1)
        tag.focusedWindow = allWindows[prevIdx]; nextModel.tags[activeTagId] = tag
        nextModel.recordFocus(tag.focusedWindow)
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow)); effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdCloseWindow:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0: effects.add(Effect(kind: EffCloseWindow, closeId: focused))

  of CmdLockSession:
    if nextModel.screenLock.command.len > 0:
      effects.add(Effect(kind: EffSpawnScreenLock, screenLockCommand: nextModel.screenLock.command))
    else:
      effects.add(Effect(kind: EffLog, msg: "screen lock command is not configured"))

  of CmdWarpPointer:
    effects.add(Effect(kind: EffPointerWarp, warpX: msg.warpX, warpY: msg.warpY))

  of CmdEatNextKey:
    effects.add(Effect(kind: EffEnsureNextKeyEaten))

  of CmdCancelEatNextKey:
    effects.add(Effect(kind: EffCancelEnsureNextKeyEaten))

  of CmdStopManager:
    effects.add(Effect(kind: EffStopManager))

  of CmdExitSession:
    if nextModel.allowExitSession:
      effects.add(Effect(kind: EffExitSession))
    else:
      effects.add(Effect(kind: EffLog, msg: "exit-session is disabled by config"))

  of CmdFocusShellUi:
    if not nextModel.sessionLocked and not nextModel.layerFocusExclusive:
      effects.add(Effect(kind: EffFocusShellUi))

  of CmdScreenshot:
    effects.add(Effect(
      kind: EffScreenshot,
      screenshotKind: msg.screenshotKind,
      screenshotPath: msg.screenshotPath,
      screenshotShowPointer: msg.screenshotShowPointer
    ))

  of CmdReloadConfig, CmdSpawnTerminal: effects.add(Effect(kind: EffManageDirty))

  else: discard

  if msg.kind.shouldBroadcastWindowsChanged():
    effects.add(nextModel.broadcastWindowsChanged())

  return (nextModel, effects)
