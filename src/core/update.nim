import model, msg, tables

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffLog

  Effect* = object
    case kind*: EffectKind
    of EffLog:
      msg*: string
    of EffSetPosition:
      windowId*: WindowId
      x*, y*, w*, h*: int32
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
    
    # Add to active tag
    let activeTag = nextModel.activeTag
    if not nextModel.tags.hasKey(activeTag):
      nextModel.tags[activeTag] = TagState(tagId: activeTag, layoutMode: Scroller)
    
    # Simple logic: each new window gets its own column for now
    var tag = nextModel.tags[activeTag]
    tag.columns.add(Column(windows: @[msg.windowId], widthProportion: 0.5))
    nextModel.tags[activeTag] = tag
    
  of WlWindowDestroyed:
    nextModel.windows.del(msg.destroyedId)
    # Also need to remove from columns in all tags (DOD optimization: index windows by tag?)
    for tagId, tag in nextModel.tags.mpairs:
      for i in countdown(tag.columns.len - 1, 0):
        tag.columns[i].windows.keepIf(proc(id: WindowId): bool = id != msg.destroyedId)
        if tag.columns[i].windows.len == 0:
          tag.columns.delete(i)

  of CmdSetLayout:
    if nextModel.tags.hasKey(nextModel.activeTag):
      nextModel.tags[nextModel.activeTag].layoutMode = msg.newLayout

  else:
    discard

  return (nextModel, effects)
