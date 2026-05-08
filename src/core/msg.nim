import model

type
  MsgKind* = enum
    # Wayland Events
    WlWindowCreated,
    WlWindowDestroyed,
    WlFocusChanged,
    WlWindowFullscreenRequested,
    WlWindowExitFullscreenRequested,
    WlWindowParent,
    WlWindowIdentifier,
    WlWindowAppId,
    WlWindowTitle,
    WlWindowDimensionsHint,
    WlWindowDimensions,
    WlWindowMaximizeRequested,
    WlWindowUnmaximizeRequested,
    WlWindowMinimizeRequested,
    WlLayerFocusExclusive,
    WlLayerFocusNonExclusive,
    WlLayerFocusNone,
    WlOutputDimensions,
    WlOutputPosition,
    WlOutputUsable,
    WlOutputRemoved,
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
    CmdToggleMaximized,
    CmdMinimize,
    CmdResizeFloating,
    CmdSelectWindow,
    CmdFocusTag,
    CmdFocusWindowById,
    CmdCloseWindowById,
    CmdSpawnTerminal,
    CmdTick,
    CmdReloadConfig

  Msg* = object
    case kind*: MsgKind
    of WlWindowCreated:
      windowId*: WindowId
      appId*: string
      title*: string
      createdIdentifier*: string
    of WlWindowDestroyed:
      destroyedId*: WindowId
    of WlFocusChanged:
      newFocusedId*: WindowId
    of WlWindowFullscreenRequested:
      fullscreenRequestId*: WindowId
      fullscreenOutputId*: uint32
    of WlWindowExitFullscreenRequested:
      exitFullscreenRequestId*: WindowId
    of WlWindowParent:
      childWindowId*: WindowId
      parentWindowId*: WindowId
    of WlWindowIdentifier:
      identifierWindowId*: WindowId
      identifier*: string
    of WlWindowAppId:
      appIdWindowId*: WindowId
      updatedAppId*: string
    of WlWindowTitle:
      titleWindowId*: WindowId
      updatedTitle*: string
    of WlWindowDimensionsHint:
      hintWindowId*: WindowId
      minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    of WlWindowDimensions:
      dimensionsWindowId*: WindowId
      actualWidth*, actualHeight*: int32
    of WlWindowMaximizeRequested:
      maximizeRequestId*: WindowId
    of WlWindowUnmaximizeRequested:
      unmaximizeRequestId*: WindowId
    of WlWindowMinimizeRequested:
      minimizeRequestId*: WindowId
    of WlOutputDimensions:
      outputId*: uint32
      width*: int32
      height*: int32
    of WlOutputPosition:
      positionOutputId*: uint32
      outputX*: int32
      outputY*: int32
    of WlOutputUsable:
      usableOutputId*: uint32
      usableX*: int32
      usableY*: int32
      usableW*: int32
      usableH*: int32
    of WlOutputRemoved:
      removedOutputId*: uint32
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
