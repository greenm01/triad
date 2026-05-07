import model

type
  MsgKind* = enum
    # Wayland Events
    WlWindowCreated,
    WlWindowDestroyed,
    WlFocusChanged,
    WlOutputDimensions,
    WlManageStart,
    WlRenderStart,

    # User Commands (IPC/Keybinds)
    CmdSetLayout,
    CmdFocusNext,
    CmdFocusPrev,
    CmdMoveWindow,
    CmdMoveToTag,
    CmdSetMasterCount,
    CmdSetMasterRatio,
    CmdToggleOverview,
    CmdToggleFloating,
    CmdSelectWindow,
    CmdTick,
    CmdReloadConfig

  Msg* = object
    case kind*: MsgKind
    of WlWindowCreated:
      windowId*: WindowId
      appId*: string
      title*: string
    of WlWindowDestroyed:
      destroyedId*: WindowId
    of WlFocusChanged:
      newFocusedId*: WindowId
    of WlOutputDimensions:
      width*: int32
      height*: int32
    of CmdSetLayout:
      newLayout*: LayoutMode
    of CmdMoveToTag:
      targetTag*: uint32
    of CmdSetMasterCount:
      count*: int
    of CmdSetMasterRatio:
      ratio*: float32
    else:
      discard
