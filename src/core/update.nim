import model, msg, tables, strutils

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
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
    
  of WlWindowDestroyed:
    nextModel.windows.del(msg.destroyedId)
    # Also need to remove from columns in all tags (DOD optimization: index windows by tag?)
    for tagId, tag in nextModel.tags.mpairs:
      for i in countdown(tag.columns.len - 1, 0):
        tag.columns[i].windows.keepIf(proc(id: WindowId): bool = id != msg.destroyedId)
        if tag.columns[i].windows.len == 0:
          tag.columns.delete(i)
      
      if tag.focusedWindow == msg.destroyedId:
        # Simple fallback: focus first window in first column
        if tag.columns.len > 0 and tag.columns[0].windows.len > 0:
          tag.focusedWindow = tag.columns[0].windows[0]
        else:
          tag.focusedWindow = 0

  of WlFocusChanged:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].focusedWindow = msg.newFocusedId

  of CmdSetLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].layoutMode = msg.newLayout

  of CmdFocusNext:
    if nextModel.tags.hasKey(nextModel.activeTag):
      var tag = nextModel.tags[nextModel.activeTag]
      var allWindows: seq[WindowId] = @[]
      for col in tag.columns:
        for win in col.windows:
          allWindows.add(win)
      
      if allWindows.len > 0:
        let idx = allWindows.find(tag.focusedWindow)
        let nextIdx = (idx + 1) mod allWindows.len
        tag.focusedWindow = allWindows[nextIdx]
        
        # Recalculate viewport offset for Scroller mode
        if tag.layoutMode == Scroller:
          # This is a bit complex as we need to know column widths
          # For now, let's just use a simple heuristic or a full layout preview
          # DOD: We'll eventually move this to a shared helper
          discard

        nextModel.tags[nextModel.activeTag] = tag
        effects.add(Effect(kind: EffFocusWindow, focusId: tag.focusedWindow))

  of CmdFocusPrev:
    if nextModel.tags.hasKey(nextModel.activeTag):
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
