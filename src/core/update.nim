import model, msg, tables, strutils, algorithm, json

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
    EffManageDirty,
    EffBroadcastJson,
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
    of EffBroadcastJson:
      jsonPayload*: string
    else:
      discard

# --- JSON IPC Event Helpers ---

proc broadcastWorkspaceActivated(tagId: uint32): Effect =
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
    "WindowOpened": {
      "id": win.id,
      "title": win.title,
      "app_id": win.appId
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
    if pred(s[i]):
      inc i
    else:
      s.delete(i)

proc update*(model: Model, msg: Msg): (Model, seq[Effect]) =
  var nextModel = model
  var effects: seq[Effect] = @[]

  case msg.kind
  of WlOutputDimensions:
    nextModel.screenWidth = msg.width
    nextModel.screenHeight = msg.height

  of WlWindowCreated:
    var win = WindowData(id: msg.windowId, appId: msg.appId, title: msg.title, widthProportion: 0.5, heightProportion: 1.0)
    
    # Determine target tag and floating state based on window rules
    var targetTag = nextModel.activeTag
    for rule in nextModel.windowRules:
      let appIdMatches = rule.appIdMatch == "" or msg.appId.contains(rule.appIdMatch)
      let titleMatches = rule.titleMatch == "" or msg.title.contains(rule.titleMatch)
      if appIdMatches and titleMatches:
        if rule.defaultTag != 0:
          targetTag = rule.defaultTag
        if rule.openFloating:
          win.isFloating = true
          win.floatingGeom = Rect(
            x: nextModel.screenWidth div 4,
            y: nextModel.screenHeight div 4,
            w: nextModel.screenWidth div 2,
            h: nextModel.screenHeight div 2
          )
        break

    nextModel.windows[msg.windowId] = win

    if not nextModel.tags.hasKey(targetTag):
      nextModel.tags[targetTag] = TagState(
        tagId: targetTag, 
        layoutMode: Scroller,
        masterCount: 1,
        masterSplitRatio: 0.55
      )
    
    # Add to determined tag
    var tag = nextModel.tags[targetTag]
    tag.columns.add(Column(windows: @[msg.windowId], widthProportion: 0.5))
    tag.focusedWindow = msg.windowId
    nextModel.tags[targetTag] = tag
    
    effects.add(broadcastWindowOpened(win))
    effects.add(Effect(kind: EffManageDirty))

  of WlWindowDestroyed:
    nextModel.windows.del(msg.destroyedId)
    # Also need to remove from columns in all tags
    for tagId, tag in nextModel.tags.mpairs:
      for i in countdown(tag.columns.len - 1, 0):
        tag.columns[i].windows.keepIf(proc(id: WindowId): bool = id != msg.destroyedId)
        if tag.columns[i].windows.len == 0:
          tag.columns.delete(i)
      
      if tag.focusedWindow == msg.destroyedId:
        if tag.columns.len > 0 and tag.columns[0].windows.len > 0:
          tag.focusedWindow = tag.columns[0].windows[0]
        else:
          tag.focusedWindow = 0
    effects.add(broadcastWindowClosed(msg.destroyedId))
    effects.add(Effect(kind: EffManageDirty))

  of WlFocusChanged:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].focusedWindow = msg.newFocusedId
      effects.add(broadcastWindowFocusChanged(msg.newFocusedId))

  of CmdSetLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].layoutMode = msg.newLayout
      effects.add(Effect(kind: EffManageDirty))

  of CmdMoveToTag:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      let focused = nextModel.tags[activeTagId].focusedWindow
      if focused != 0:
        # Remove from current tag
        var currentTag = nextModel.tags[activeTagId]
        for i in countdown(currentTag.columns.len - 1, 0):
          currentTag.columns[i].windows.keepIf(proc(id: WindowId): bool = id != focused)
          if currentTag.columns[i].windows.len == 0:
            currentTag.columns.delete(i)
        nextModel.tags[activeTagId] = currentTag
        
        # Add to target tag
        if not nextModel.tags.hasKey(msg.targetTag):
          nextModel.tags[msg.targetTag] = TagState(tagId: msg.targetTag, layoutMode: Scroller, masterCount: 1, masterSplitRatio: 0.55)
        
        var targetTag = nextModel.tags[msg.targetTag]
        targetTag.columns.add(Column(windows: @[focused], widthProportion: 0.5))
        targetTag.focusedWindow = focused
        nextModel.tags[msg.targetTag] = targetTag
        
        effects.add(broadcastWorkspaceActivated(msg.targetTag))
        effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterCount:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].masterCount = max(1, msg.count)
      effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterRatio:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].masterSplitRatio = clamp(msg.ratio, 0.05, 0.95)
      effects.add(Effect(kind: EffManageDirty))

  of CmdResizeWidth:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        if tag.layoutMode == Scroller:
          for i in 0 ..< tag.columns.len:
            if tag.columns[i].windows.contains(focused):
              tag.columns[i].widthProportion = clamp(tag.columns[i].widthProportion + msg.deltaW, 0.05, 1.0)
              break
          nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))
        elif tag.layoutMode == MasterStack:
          tag.masterSplitRatio = clamp(tag.masterSplitRatio + msg.deltaW, 0.05, 0.95)
          nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))

  of CmdResizeHeight:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        if tag.layoutMode == VerticalScroller:
          for i in 0 ..< tag.columns.len:
            if tag.columns[i].windows.contains(focused):
              tag.columns[i].widthProportion = clamp(tag.columns[i].widthProportion + msg.deltaH, 0.05, 1.0)
              break
          nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))

  of CmdAdjustGaps:
    nextModel.outerGaps = max(0, nextModel.outerGaps + msg.deltaG)
    nextModel.innerGaps = nextModel.outerGaps div 2
    effects.add(Effect(kind: EffManageDirty))

  of CmdMoveColumnLeft:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused):
            colIdx = i
            break
        if colIdx > 0:
          let temp = tag.columns[colIdx]
          tag.columns[colIdx] = tag.columns[colIdx-1]
          tag.columns[colIdx-1] = temp
          nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))

  of CmdMoveColumnRight:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        var colIdx = -1
        for i in 0 ..< tag.columns.len:
          if tag.columns[i].windows.contains(focused):
            colIdx = i
            break
        if colIdx != -1 and colIdx < tag.columns.len - 1:
          let temp = tag.columns[colIdx]
          tag.columns[colIdx] = tag.columns[colIdx+1]
          tag.columns[colIdx+1] = temp
          nextModel.tags[activeTagId] = tag
          effects.add(Effect(kind: EffManageDirty))

  of CmdMoveWindowUp:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx > 0:
            let temp = tag.columns[i].windows[idx]
            tag.columns[i].windows[idx] = tag.columns[i].windows[idx-1]
            tag.columns[i].windows[idx-1] = temp
            nextModel.tags[activeTagId] = tag
            effects.add(Effect(kind: EffManageDirty))
            break

  of CmdMoveWindowDown:
    let activeTagId = nextModel.activeTag
    if nextModel.tags.hasKey(activeTagId):
      var tag = nextModel.tags[activeTagId]
      let focused = tag.focusedWindow
      if focused != 0:
        for i in 0 ..< tag.columns.len:
          let idx = tag.columns[i].windows.find(focused)
          if idx != -1 and idx < tag.columns[i].windows.len - 1:
            let temp = tag.columns[i].windows[idx]
            tag.columns[i].windows[idx] = tag.columns[i].windows[idx+1]
            tag.columns[i].windows[idx+1] = temp
            nextModel.tags[activeTagId] = tag
            effects.add(Effect(kind: EffManageDirty))
            break

  of CmdToggleOverview:
    nextModel.overviewActive = not nextModel.overviewActive
    effects.add(Effect(kind: EffManageDirty))

  of CmdToggleFloating:
    if nextModel.tags.hasKey(nextModel.activeTag):
      let focused = nextModel.tags[nextModel.activeTag].focusedWindow
      if focused != 0 and nextModel.windows.hasKey(focused):
        var win = nextModel.windows[focused]
        win.isFloating = not win.isFloating
        if win.isFloating:
          win.floatingGeom = Rect(
            x: nextModel.screenWidth div 4,
            y: nextModel.screenHeight div 4,
            w: nextModel.screenWidth div 2,
            h: nextModel.screenHeight div 2
          )
        nextModel.windows[focused] = win
        effects.add(Effect(kind: EffManageDirty))

  of CmdSelectWindow:
    nextModel.overviewActive = false
    effects.add(broadcastWorkspaceActivated(nextModel.activeTag))
    effects.add(Effect(kind: EffManageDirty))

  of CmdTick:
    if nextModel.enableAnimations:
      var changed = false
      let speed = nextModel.animationSpeed
      let epsilon: float32 = 0.5

      for tagId, tag in nextModel.tags.mpairs:
        # X Offset interpolation
        let dx = tag.targetViewportXOffset - tag.currentViewportXOffset
        if abs(dx) > epsilon:
          tag.currentViewportXOffset += dx * speed
          changed = true
        else:
          tag.currentViewportXOffset = tag.targetViewportXOffset

        # Y Offset interpolation
        let dy = tag.targetViewportYOffset - tag.currentViewportYOffset
        if abs(dy) > epsilon:
          tag.currentViewportYOffset += dy * speed
          changed = true
        else:
          tag.currentViewportYOffset = tag.targetViewportYOffset

      if changed:
        effects.add(Effect(kind: EffManageDirty))

  of CmdFocusNext:
    if nextModel.overviewActive:
      var allWindows: seq[WindowId] = @[]
      # Sort tag IDs for consistent navigation order
      var tagIds: seq[uint32] = @[]
      for id in nextModel.tags.keys: tagIds.add(id)
      tagIds.sort()

      for id in tagIds:
        let tag = nextModel.tags[id]
        for col in tag.columns:
          for win in col.windows:
            allWindows.add(win)
      
      if allWindows.len > 0:
        let activeTagId = nextModel.activeTag
        let currentFocus = nextModel.tags[activeTagId].focusedWindow
        let idx = allWindows.find(currentFocus)
        let nextIdx = (if idx == -1: 0 else: (idx + 1) mod allWindows.len)
        let nextFocus = allWindows[nextIdx]
        
        # Find owner tag
        for id in tagIds:
          var found = false
          for col in nextModel.tags[id].columns:
            if col.windows.contains(nextFocus):
              found = true
              break
          if found:
            nextModel.activeTag = id
            nextModel.tags[id].focusedWindow = nextFocus
            break
            
        effects.add(broadcastWindowFocusChanged(nextFocus))
        effects.add(broadcastWorkspaceActivated(nextModel.activeTag))
        effects.add(Effect(kind: EffFocusWindow, focusId: nextFocus))

    elif nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows:
          allWindows.add(win)
      
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow)
        let nextIdx = (idx + 1) mod allWindows.len
        tag.focusedWindow = allWindows[nextIdx]
        nextModel.tags[nextModel.activeTag] = tag
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow))
        effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdFocusPrev:
    if nextModel.overviewActive:
      var allWindows: seq[WindowId] = @[]
      var tagIds: seq[uint32] = @[]
      for id in nextModel.tags.keys: tagIds.add(id)
      tagIds.sort()

      for id in tagIds:
        let tag = nextModel.tags[id]
        for col in tag.columns:
          for win in col.windows:
            allWindows.add(win)
      
      if allWindows.len > 0:
        let activeTagId = nextModel.activeTag
        let currentFocus = nextModel.tags[activeTagId].focusedWindow
        let idx = allWindows.find(currentFocus)
        let prevIdx = (if idx == -1: 0 else: (idx - 1 + allWindows.len) mod allWindows.len)
        let nextFocus = allWindows[prevIdx]
        
        # Find owner tag
        for id in tagIds:
          var found = false
          for col in nextModel.tags[id].columns:
            if col.windows.contains(nextFocus):
              found = true
              break
          if found:
            nextModel.activeTag = id
            nextModel.tags[id].focusedWindow = nextFocus
            break

        effects.add(broadcastWindowFocusChanged(nextFocus))
        effects.add(broadcastWorkspaceActivated(nextModel.activeTag))
        effects.add(Effect(kind: EffFocusWindow, focusId: nextFocus))

    elif nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows:
          allWindows.add(win)
      
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow)
        let prevIdx = (idx - 1 + allWindows.len) mod allWindows.len
        tag.focusedWindow = allWindows[prevIdx]
        nextModel.tags[nextModel.activeTag] = tag
        effects.add(broadcastWindowFocusChanged(tag.focusedWindow))
        effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  else:
    discard

  return (nextModel, effects)
