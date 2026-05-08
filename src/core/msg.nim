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
    WlPointerMoveRequested,
    WlPointerResizeRequested,
    WlPointerDelta,
    WlPointerRelease,

    # User Commands (IPC/Keybinds)
    CmdSetLayout,
    CmdFocusNext,
    CmdFocusPrev,
    CmdCloseWindow,
    CmdMoveWindow,
    CmdMoveWindowLeft,
    CmdMoveWindowRight,
    CmdMoveWindowUp,
    CmdMoveWindowDown,
    CmdMoveColumnLeft,
    CmdMoveColumnRight,
    CmdSwapWindowUp,
    CmdSwapWindowDown,
    CmdConsumeWindow,
    CmdExpelWindow,
    CmdZoom,
    CmdToggleGaps,
    CmdMoveFloating,
    CmdMoveToTag,
    CmdSwapWindowToTag,
    CmdRenameTag,
    CmdGroupWindows,
    CmdUngroupWindow,
    CmdFocusNextInGroup,
    CmdSetMasterCount,
    CmdSetMasterRatio,
    CmdAdjustMasterCount,
    CmdAdjustMasterRatio,
    CmdResizeWidth,
    CmdResizeHeight,
    CmdSetColumnWidth,
    CmdAdjustGaps,
    CmdToggleGapsRel, # Unused
    CmdMoveToScratchpad,
    CmdToggleScratchpad,
    CmdToggleOverview,
    CmdToggleFloating,
    CmdToggleFullscreen,
    CmdResizeFloating,
    CmdSelectWindow,
    CmdFocusTag,
    CmdFocusWindowById,
    CmdCloseWindowById,
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
    of WlPointerMoveRequested:
      moveWinId*: WindowId
      moveSeat*: pointer # ptr RiverSeatV1
    of WlPointerResizeRequested:
      resizeWinId*: WindowId
      resizeSeat*: pointer # ptr RiverSeatV1
      resizeEdges*: uint32
    of WlPointerDelta:
      dx*, dy*: int32
    of CmdMoveFloating:
      moveDX*, moveDY*: int32
    of CmdSetLayout:
      newLayout*: LayoutMode
    of CmdMoveToTag:
      targetTag*: uint32
    of CmdSwapWindowToTag:
      targetTagSwap*: uint32
    of CmdRenameTag:
      newName*: string
    of CmdSetMasterCount:
      count*: int
    of CmdSetMasterRatio:
      ratio*: float32
    of CmdAdjustMasterCount:
      deltaMC*: int
    of CmdAdjustMasterRatio:
      deltaMR*: float32
    of CmdResizeWidth:
      deltaW*: float32
    of CmdResizeHeight:
      deltaH*: float32
    of CmdSetColumnWidth:
      targetWidth*: float32
    of CmdAdjustGaps:
      deltaG*: int32
    of CmdResizeFloating:
      deltaFW*, deltaFH*: int32
    of CmdFocusTag:
      focusTag*: uint32
    of CmdFocusWindowById:
      focusWindowId*: WindowId
    of CmdCloseWindowById:
      closeWindowId*: WindowId
    else:
      discard
