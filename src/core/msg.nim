import ../types/runtime_values

type
  ScreenshotKind* {.pure.} = enum
    ShotRegion
    ShotScreen
    ShotWindow

  ScreenshotPointerMode* {.pure.} = enum
    PointerDefault
    PointerShow
    PointerHide

  MsgKind* {.pure.} = enum
    # Wayland Events
    WlWindowCreated
    WlWindowDestroyed
    WlFocusChanged
    WlWindowFullscreenRequested
    WlWindowExitFullscreenRequested
    WlWindowParent
    WlWindowIdentifier
    WlWindowAppId
    WlWindowTitle
    WlWindowDimensionsHint
    WlWindowDimensions
    WlWindowDecorationHint
    WlWindowPresentationHint
    WlWindowMenuRequested
    WlWindowMaximizeRequested
    WlWindowUnmaximizeRequested
    WlWindowMinimizeRequested
    WlWindowAdmissionSettled
    WlLayerFocusExclusive
    WlLayerFocusNonExclusive
    WlLayerFocusNone
    WlSessionLocked
    WlSessionUnlocked
    WlOutputDimensions
    WlOutputName
    WlOutputPosition
    WlOutputUsable
    WlOutputRemoved
    WlManageStart
    WlRenderStart
    WlPointerMoveRequested
    WlPointerResizeRequested
    WlOverviewPointerDragRequested
    WlOverviewPointerScrollRequested
    WlOverviewWheel
    WlPointerDelta
    WlPointerRelease
    WlShellSurfaceInteraction
    WlModifiersChanged

    # User Commands (IPC/Keybinds)
    CmdSetLayout
    CmdFocusNext
    CmdFocusPrev
    CmdFocusDirection
    CmdFocusLast
    CmdFocusTagLeft
    CmdFocusTagRight
    CmdFocusOccupiedTagLeft
    CmdFocusOccupiedTagRight
    CmdFocusColumnFirst
    CmdFocusColumnLast
    CmdFocusWindowOrWorkspaceUp
    CmdFocusWindowOrWorkspaceDown
    CmdMoveToTagLeft
    CmdMoveToTagRight
    CmdCloseWindow
    CmdMoveWindow
    CmdMoveWindowLeft
    CmdMoveWindowRight
    CmdMoveWindowUp
    CmdMoveWindowDown
    CmdMoveWindowUpOrToWorkspaceUp
    CmdMoveWindowDownOrToWorkspaceDown
    CmdMoveColumnLeft
    CmdMoveColumnRight
    CmdMoveColumnToFirst
    CmdMoveColumnToLast
    CmdSwapWindowUp
    CmdSwapWindowDown
    CmdConsumeWindow
    CmdExpelWindow
    CmdZoom
    CmdToggleGaps
    CmdMoveFloating
    CmdMoveToTag
    CmdSwapWindowToTag
    CmdRenameTag
    CmdGroupWindows
    CmdUngroupWindow
    CmdFocusNextInGroup
    CmdSetMasterCount
    CmdSetMasterRatio
    CmdAdjustMasterCount
    CmdAdjustMasterRatio
    CmdMaximizeColumn
    CmdResizeWidth
    CmdResizeHeight
    CmdSetColumnWidth
    CmdAdjustGaps
    CmdToggleGapsRel # Unused
    CmdMoveToScratchpad
    CmdMoveToNamedScratchpad
    CmdToggleScratchpad
    CmdToggleNamedScratchpad
    CmdRestoreScratchpad
    CmdToggleOverview
    CmdOpenOverview
    CmdCloseOverview
    CmdToggleFloating
    CmdToggleFullscreen
    CmdToggleFullscreenById
    CmdExitFullscreenById
    CmdToggleMaximized
    CmdMinimize
    CmdResizeFloating
    CmdSelectWindow
    CmdFocusTag
    CmdFocusWorkspaceIndex
    CmdMoveToWorkspaceIndex
    CmdFocusWindowById
    CmdCloseWindowById
    CmdSpawn
    CmdSpawnTerminal
    CmdLockSession
    CmdWarpPointer
    CmdEatNextKey
    CmdCancelEatNextKey
    CmdToggleKeyboardShortcutsInhibit
    CmdStopManager
    CmdExitSession
    CmdFocusShellUi
    CmdShowHotkeyOverlay
    CmdHideHotkeyOverlay
    CmdToggleHotkeyOverlay
    CmdTick
    CmdExpireStartupWindowRules
    CmdConfigReload
    CmdTriadReload
    CmdSwitchLayout
    CmdScreenshot

  Msg* = object
    case kind*: MsgKind
    of MsgKind.WlWindowCreated:
      windowId*: WindowId
      createdParentWindowId*: WindowId
      appId*: string
      title*: string
      createdIdentifier*: string
      deferAdmission*: bool
    of MsgKind.WlWindowDestroyed:
      destroyedId*: WindowId
    of MsgKind.WlFocusChanged:
      newFocusedId*: WindowId
    of MsgKind.WlWindowFullscreenRequested:
      fullscreenRequestId*: WindowId
      fullscreenOutputId*: uint32
    of MsgKind.WlWindowExitFullscreenRequested:
      exitFullscreenRequestId*: WindowId
    of MsgKind.WlWindowParent:
      childWindowId*: WindowId
      parentWindowId*: WindowId
    of MsgKind.WlWindowIdentifier:
      identifierWindowId*: WindowId
      identifier*: string
    of MsgKind.WlWindowAppId:
      appIdWindowId*: WindowId
      updatedAppId*: string
    of MsgKind.WlWindowTitle:
      titleWindowId*: WindowId
      updatedTitle*: string
    of MsgKind.WlWindowDimensionsHint:
      hintWindowId*: WindowId
      minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    of MsgKind.WlWindowDimensions:
      dimensionsWindowId*: WindowId
      actualWidth*, actualHeight*: int32
    of MsgKind.WlWindowDecorationHint:
      decorationWindowId*: WindowId
      decorationHint*: uint32
    of MsgKind.WlWindowPresentationHint:
      presentationWindowId*: WindowId
      presentationHint*: uint32
    of MsgKind.WlWindowMenuRequested:
      menuWindowId*: WindowId
      menuX*: int32
      menuY*: int32
    of MsgKind.WlWindowMaximizeRequested:
      maximizeRequestId*: WindowId
    of MsgKind.WlWindowUnmaximizeRequested:
      unmaximizeRequestId*: WindowId
    of MsgKind.WlWindowMinimizeRequested:
      minimizeRequestId*: WindowId
    of MsgKind.WlWindowAdmissionSettled:
      admissionWindowId*: WindowId
    of MsgKind.WlOutputDimensions:
      outputId*: uint32
      width*: int32
      height*: int32
    of MsgKind.WlOutputName:
      nameOutputId*: uint32
      outputName*: string
    of MsgKind.WlOutputPosition:
      positionOutputId*: uint32
      outputX*: int32
      outputY*: int32
    of MsgKind.WlOutputUsable:
      usableOutputId*: uint32
      usableX*: int32
      usableY*: int32
      usableW*: int32
      usableH*: int32
    of MsgKind.WlOutputRemoved:
      removedOutputId*: uint32
    of MsgKind.WlPointerMoveRequested:
      moveWinId*: WindowId
      moveSeat*: pointer # ptr RiverSeatV1
    of MsgKind.WlPointerResizeRequested:
      resizeWinId*: WindowId
      resizeSeat*: pointer # ptr RiverSeatV1
      resizeEdges*: uint32
    of MsgKind.WlOverviewPointerDragRequested:
      overviewDragWinId*: WindowId
      overviewDragSeat*: pointer # ptr RiverSeatV1
      overviewDragX*, overviewDragY*: int32
    of MsgKind.WlOverviewPointerScrollRequested:
      overviewScrollSeat*: pointer # ptr RiverSeatV1
      overviewScrollX*, overviewScrollY*: int32
    of MsgKind.WlOverviewWheel:
      overviewWheelX*, overviewWheelY*: int32
      overviewWheelHorizontal*, overviewWheelVertical*: int32
    of MsgKind.WlPointerDelta:
      dx*, dy*: int32
    of MsgKind.WlShellSurfaceInteraction:
      shellSurfaceId*: uint32
    of MsgKind.WlModifiersChanged:
      oldModifiers*: uint32
      newModifiers*: uint32
    of MsgKind.CmdMoveFloating:
      moveDX*, moveDY*: int32
    of MsgKind.CmdSetLayout:
      newLayout*: LayoutMode
      layoutTargetTag*: uint32
    of MsgKind.CmdFocusDirection:
      direction*: Direction
    of MsgKind.CmdMoveToTag:
      targetTag*: uint32
    of MsgKind.CmdSwapWindowToTag:
      targetTagSwap*: uint32
    of MsgKind.CmdRenameTag:
      newName*: string
    of MsgKind.CmdMoveToNamedScratchpad, MsgKind.CmdToggleNamedScratchpad:
      scratchpadName*: string
    of MsgKind.CmdSetMasterCount:
      count*: int
    of MsgKind.CmdSetMasterRatio:
      ratio*: float32
    of MsgKind.CmdAdjustMasterCount:
      deltaMC*: int
    of MsgKind.CmdAdjustMasterRatio:
      deltaMR*: float32
    of MsgKind.CmdResizeWidth:
      deltaW*: float32
    of MsgKind.CmdResizeHeight:
      deltaH*: float32
    of MsgKind.CmdSetColumnWidth:
      targetWidth*: float32
    of MsgKind.CmdAdjustGaps:
      deltaG*: int32
    of MsgKind.CmdResizeFloating:
      deltaFW*, deltaFH*: int32
    of MsgKind.CmdFocusTag:
      focusTag*: uint32
    of MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdMoveToWorkspaceIndex:
      workspaceIndex*: uint32
    of MsgKind.CmdFocusWindowById:
      focusWindowId*: WindowId
    of MsgKind.CmdCloseWindowById:
      closeWindowId*: WindowId
    of MsgKind.CmdToggleFullscreenById, MsgKind.CmdExitFullscreenById:
      fullscreenWindowId*: WindowId
    of MsgKind.CmdSpawn:
      spawnCommand*: seq[string]
    of MsgKind.CmdWarpPointer:
      warpX*, warpY*: int32
    of MsgKind.CmdScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotPointerMode*: ScreenshotPointerMode
      screenshotWriteToDisk*: bool
      screenshotCopyToClipboard*: bool
    else:
      discard
