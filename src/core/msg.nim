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
    else:
      discard
