import model, msg, model_utils, tables, strutils, algorithm, json

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
    EffCloseWindow,
    EffManageDirty,
    EffBroadcastJson,
    EffOpStartPointer,
    EffOpEnd,
    EffSetFullscreen,
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

proc broadcastWindowOpened(win: WindowData): Effect =
  let payload = %*{
    "WindowOpenedOrChanged": {
      "window": {
        "id": win.id,
        "title": if win.title == "": newJNull() else: %win.title,
        "app_id": if win.appId == "": newJNull() else: %win.appId,
        "pid": newJNull(),
        "workspace_id": newJNull(),
        "is_focused": false,
        "is_floating": win.isFloating,
        "is_urgent": false,
        "layout": {
          "pos_in_scrolling_layout": newJNull(),
          "tile_size": [0.0, 0.0],
          "window_size": [0, 0],
          "tile_pos_in_workspace_view": newJNull(),
          "window_offset_in_tile": [0.0, 0.0]
        },
        "focus_timestamp": newJNull()
      }
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

proc keepIf[T](s: var seq[T], pred: proc(x: T): bool) =
  var i = 0
  while i < s.len:
    if pred(s[i]): inc i
    else: s.delete(i)

proc update*(model: Model, msg: Msg): (Model, seq[Effect]) =
  var nextModel = model
  var effects: seq[Effect] = @[]

  case msg.kind
  of WlOutputDimensions:
    nextModel.screenWidth = max(0'i32, msg.width)
    nextModel.screenHeight = max(0'i32, msg.height)

  of WlWindowCreated:
    discard nextModel.removeWindowFromAllTags(msg.windowId)
    discard nextModel.removeWindowFromScratchpad(msg.windowId)

    var win = WindowData(id: msg.windowId, appId: msg.appId, title: msg.title, widthProportion: DefaultWindowWidth, heightProportion: DefaultWindowHeight)
    var targetTag = if nextModel.activeTag == 0: 1'u32 else: nextModel.activeTag
    var forcedLayout = 0
    for rule in nextModel.windowRules:
      let appIdMatches = rule.appIdMatch == "" or msg.appId.contains(rule.appIdMatch)
      let titleMatches = rule.titleMatch == "" or msg.title.contains(rule.titleMatch)
      if appIdMatches and titleMatches:
        if rule.defaultTag != 0: targetTag = rule.defaultTag
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
    tag.focusedWindow = msg.windowId
    nextModel.tags[targetTag] = tag
    effects.add(broadcastWindowOpened(win))
    effects.add(Effect(kind: EffManageDirty))

  of WlWindowDestroyed:
    nextModel.windows.del(msg.destroyedId)
    discard nextModel.removeWindowFromAllTags(msg.destroyedId)
    discard nextModel.removeWindowFromScratchpad(msg.destroyedId)
    if nextModel.pointerOp.windowId == msg.destroyedId:
      nextModel.pointerOp = PointerOpState(kind: OpNone)
    effects.add(broadcastWindowClosed(msg.destroyedId))
    effects.add(Effect(kind: EffManageDirty))

  of WlFocusChanged:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      if msg.newFocusedId == 0 or tag.containsWindow(msg.newFocusedId):
        tag.focusedWindow = msg.newFocusedId
        nextModel.tags[nextModel.activeTag] = tag
        effects.add(broadcastWindowFocusChanged(msg.newFocusedId))

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
    nextModel.pointerOp = PointerOpState(kind: OpNone)

  of CmdSetLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      tag.layoutMode = msg.newLayout
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
        var tag = nextModel.tags[activeTagId]
        discard tag.removeWindow(focused)
        nextModel.tags[activeTagId] = tag
        if not nextModel.scratchpadWindows.contains(focused):
          nextModel.scratchpadWindows.add(focused)
        effects.add(Effect(kind: EffManageDirty))

  of CmdToggleScratchpad:
    nextModel.isScratchpadVisible = not nextModel.isScratchpadVisible
    if nextModel.isScratchpadVisible and nextModel.scratchpadWindows.len > 0:
      effects.add(Effect(kind: EffFocusWindow, focusId: nextModel.scratchpadWindows[^1]))
    effects.add(Effect(kind: EffManageDirty))

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

  of CmdToggleOverview: nextModel.overviewActive = not nextModel.overviewActive; effects.add(Effect(kind: EffManageDirty))

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
        effects.add(Effect(kind: EffSetFullscreen, fsWinId: focused, isFullscreen: win.isFullscreen)); effects.add(Effect(kind: EffManageDirty))

  of CmdSelectWindow:
    nextModel.overviewActive = false
    let tagId = nextModel.activeTagOrFallback()
    if tagId != 0:
      nextModel.activeTag = tagId
      effects.add(broadcastWorkspaceActivated(tagId, nextModel.tags[tagId].name))
    effects.add(Effect(kind: EffManageDirty))

  of CmdFocusTag:
    if nextModel.tags.hasKey(msg.focusTag):
      nextModel.activeTag = msg.focusTag
      var tag = nextModel.tags[msg.focusTag]
      tag.recomputeFocus()
      nextModel.tags[msg.focusTag] = tag
      effects.add(broadcastWorkspaceActivated(msg.focusTag, tag.name))
      if tag.focusedWindow != 0:
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow))
        effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))
      effects.add(Effect(kind: EffManageDirty))

  of CmdFocusWindowById:
    var foundTag = 0'u32
    for tagId, tag in nextModel.tags.pairs:
      if tag.containsWindow(msg.focusWindowId):
        foundTag = tagId
        break
    if foundTag != 0 and nextModel.windows.hasKey(msg.focusWindowId):
      nextModel.activeTag = foundTag
      var tag = nextModel.tags[foundTag]
      tag.focusedWindow = msg.focusWindowId
      nextModel.tags[foundTag] = tag
      effects.add(broadcastWorkspaceActivated(foundTag, tag.name))
      effects.add(broadcastWindowFocusChanged(msg.focusWindowId))
      effects.add(Effect(kind: EffFocusWindow, focusId: msg.focusWindowId))
      effects.add(Effect(kind: EffManageDirty))

  of CmdCloseWindowById:
    if nextModel.windows.hasKey(msg.closeWindowId):
      effects.add(Effect(kind: EffCloseWindow, closeId: msg.closeWindowId))

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

  of CmdFocusNext:
    if nextModel.overviewActive:
      var allWindows: seq[WindowId] = @[]; var tagIds: seq[uint32] = @[]
      for id in nextModel.tags.keys: tagIds.add(id)
      tagIds.sort()
      for id in tagIds:
        let tag = nextModel.tags[id]
        for col in tag.columns:
          for win in col.windows: allWindows.add(win)
      if allWindows.len > 0:
        let activeTagId = nextModel.activeTag
        let currentFocus = if nextModel.tags.hasKey(activeTagId): nextModel.tags[activeTagId].focusedWindow else: 0'u32
        let idx = allWindows.find(currentFocus)
        let nextIdx = (if idx == -1: 0 else: (idx + 1) mod allWindows.len); let nextFocus = allWindows[nextIdx]
        for id in tagIds:
          var found = false
          for col in nextModel.tags[id].columns:
            if col.windows.contains(nextFocus): found = true; break
          if found:
            nextModel.activeTag = id; var tag = nextModel.tags[id]; tag.focusedWindow = nextFocus; nextModel.tags[id] = tag; break
        effects.add(broadcastWindowFocusChanged(nextFocus))
        let tagId = nextModel.activeTagOrFallback()
        if tagId != 0:
          nextModel.activeTag = tagId
          effects.add(broadcastWorkspaceActivated(tagId, nextModel.tags[tagId].name))
        effects.add(Effect(kind: EffFocusWindow, focusId: nextFocus))
    elif nextModel.tags.hasKey(nextModel.activeTag):
      let activeTagId = nextModel.activeTag; var tag = nextModel.tags[activeTagId]; var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows: allWindows.add(win)
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow); let nextIdx = (if idx == -1: 0 else: (idx + 1) mod allWindows.len)
        tag.focusedWindow = allWindows[nextIdx]; nextModel.tags[activeTagId] = tag
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow)); effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdFocusPrev:
    if nextModel.overviewActive:
      var allWindows: seq[WindowId] = @[]; var tagIds: seq[uint32] = @[]
      for id in nextModel.tags.keys: tagIds.add(id)
      tagIds.sort()
      for id in tagIds:
        let tag = nextModel.tags[id]
        for col in tag.columns:
          for win in col.windows: allWindows.add(win)
      if allWindows.len > 0:
        let activeTagId = nextModel.activeTag
        let currentFocus = if nextModel.tags.hasKey(activeTagId): nextModel.tags[activeTagId].focusedWindow else: 0'u32
        let idx = allWindows.find(currentFocus)
        let prevIdx = (if idx == -1: 0 else: (idx - 1 + allWindows.len) mod allWindows.len); let nextFocus = allWindows[prevIdx]
        for id in tagIds:
          var found = false
          for col in nextModel.tags[id].columns:
            if col.windows.contains(nextFocus): found = true; break
          if found:
            nextModel.activeTag = id; var tag = nextModel.tags[id]; tag.focusedWindow = nextFocus; nextModel.tags[id] = tag; break
        effects.add(broadcastWindowFocusChanged(nextFocus))
        let tagId = nextModel.activeTagOrFallback()
        if tagId != 0:
          nextModel.activeTag = tagId
          effects.add(broadcastWorkspaceActivated(tagId, nextModel.tags[tagId].name))
        effects.add(Effect(kind: EffFocusWindow, focusId: nextFocus))
    elif nextModel.tags.hasKey(nextModel.activeTag):
      let activeTagId = nextModel.activeTag; var tag = nextModel.tags[activeTagId]; var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows: allWindows.add(win)
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow); let prevIdx = (if idx - 1 < 0: allWindows.len - 1 else: idx - 1)
        tag.focusedWindow = allWindows[prevIdx]; nextModel.tags[activeTagId] = tag
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow)); effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdCloseWindow:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0: effects.add(Effect(kind: EffCloseWindow, closeId: focused))

  of CmdReloadConfig: effects.add(Effect(kind: EffManageDirty))

  else: discard

  return (nextModel, effects)
