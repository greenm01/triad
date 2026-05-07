import model, msg, tables, strutils, algorithm

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
    EffManageDirty,
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
    else:
      discard

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
    let win = WindowData(id: msg.windowId, appId: msg.appId, title: msg.title, widthProportion: 0.5, heightProportion: 1.0)
    nextModel.windows[msg.windowId] = win
    
    # Determine target tag based on window rules
    var targetTag = nextModel.activeTag
    for rule in nextModel.windowRules:
      let appIdMatches = rule.appIdMatch == "" or msg.appId.contains(rule.appIdMatch)
      let titleMatches = rule.titleMatch == "" or msg.title.contains(rule.titleMatch)
      if appIdMatches and titleMatches and rule.defaultTag != 0:
        targetTag = rule.defaultTag
        break

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
    
    # If added to background tag, we might need a re-render if it affects something
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
    effects.add(Effect(kind: EffManageDirty))

  of WlFocusChanged:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].focusedWindow = msg.newFocusedId

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
        
        effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterCount:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].masterCount = max(1, msg.count)
      effects.add(Effect(kind: EffManageDirty))

  of CmdSetMasterRatio:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].masterSplitRatio = clamp(msg.ratio, 0.05, 0.95)
      effects.add(Effect(kind: EffManageDirty))

  of CmdToggleOverview:
    nextModel.overviewActive = not nextModel.overviewActive
    effects.add(Effect(kind: EffManageDirty))

  of CmdSelectWindow:
    nextModel.overviewActive = false
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
        effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  else:
    discard

  return (nextModel, effects)
