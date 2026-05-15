import runtime_values

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
    WlWindowPid
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
    WlOutputIdentity
    WlOutputDescription
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
    WlRecentWindowPointerMotion
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
    CmdMoveWindowToTag
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
    CmdSwitchProportionPreset
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
    CmdOverviewTab
    CmdRecentWindowNext
    CmdRecentWindowPrev
    CmdRecentWindowConfirm
    CmdRecentWindowCancel
    CmdRecentWindowFirst
    CmdRecentWindowLast
    CmdRecentWindowScope
    CmdRecentWindowCycleScope
    CmdRecentWindowCloseCurrent
    CmdToggleFloating
    CmdSetWindowFloatingById
    CmdSetWindowMaximizedById
    CmdToggleFullscreen
    CmdToggleFullscreenById
    CmdExitFullscreenById
    CmdToggleMaximized
    CmdMinimize
    CmdResizeFloating
    CmdSelectWindow
    CmdFocusTag
    CmdFocusWorkspaceIndex
    CmdReorderWorkspaceIndex
    CmdMoveToWorkspaceIndex
    CmdMoveWindowToWorkspaceIndex
    CmdFocusOutput
    CmdMoveWorkspaceToOutput
    CmdMoveToOutput
    CmdFocusWindowById
    CmdCloseWindowById
    CmdSpawn
    CmdSpawnTerminal
    CmdLockSession
    CmdWarpPointer
    CmdEatNextKey
    CmdCancelEatNextKey
    CmdSwitchKeyboardLayout
    CmdToggleKeyboardShortcutsInhibit
    CmdStopManager
    CmdExitSession
    CmdExitSessionImmediate
    CmdConfirmExitSession
    CmdDismissExitSessionConfirm
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
      windowId*: uint32
      createdParentWindowId*: uint32
      createdSwallowHostWindowId*: uint32
      createdPid*: int32
      appId*: string
      title*: string
      createdIdentifier*: string
      deferAdmission*: bool
    of MsgKind.WlWindowDestroyed:
      destroyedId*: uint32
    of MsgKind.WlFocusChanged:
      newFocusedId*: uint32
    of MsgKind.WlWindowFullscreenRequested:
      fullscreenRequestId*: uint32
      fullscreenOutputId*: uint32
    of MsgKind.WlWindowExitFullscreenRequested:
      exitFullscreenRequestId*: uint32
    of MsgKind.WlWindowParent:
      childWindowId*: uint32
      parentWindowId*: uint32
    of MsgKind.WlWindowIdentifier:
      identifierWindowId*: uint32
      identifier*: string
    of MsgKind.WlWindowPid:
      pidWindowId*: uint32
      windowPid*: int32
    of MsgKind.WlWindowAppId:
      appIdWindowId*: uint32
      updatedAppId*: string
    of MsgKind.WlWindowTitle:
      titleWindowId*: uint32
      updatedTitle*: string
    of MsgKind.WlWindowDimensionsHint:
      hintWindowId*: uint32
      minWidth*, minHeight*, maxWidth*, maxHeight*: int32
    of MsgKind.WlWindowDimensions:
      dimensionsWindowId*: uint32
      actualWidth*, actualHeight*: int32
    of MsgKind.WlWindowDecorationHint:
      decorationWindowId*: uint32
      decorationHint*: uint32
    of MsgKind.WlWindowPresentationHint:
      presentationWindowId*: uint32
      presentationHint*: uint32
    of MsgKind.WlWindowMenuRequested:
      menuWindowId*: uint32
      menuX*: int32
      menuY*: int32
    of MsgKind.WlWindowMaximizeRequested:
      maximizeRequestId*: uint32
    of MsgKind.WlWindowUnmaximizeRequested:
      unmaximizeRequestId*: uint32
    of MsgKind.WlWindowMinimizeRequested:
      minimizeRequestId*: uint32
    of MsgKind.WlWindowAdmissionSettled:
      admissionWindowId*: uint32
    of MsgKind.WlOutputDimensions:
      outputId*: uint32
      width*: int32
      height*: int32
    of MsgKind.WlOutputName:
      nameOutputId*: uint32
      outputName*: string
    of MsgKind.WlOutputIdentity:
      identityOutputId*: uint32
      outputMake*: string
      outputModel*: string
    of MsgKind.WlOutputDescription:
      descriptionOutputId*: uint32
      outputDescription*: string
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
      moveWinId*: uint32
      moveSeat*: pointer # ptr RiverSeatV1
    of MsgKind.WlPointerResizeRequested:
      resizeWinId*: uint32
      resizeSeat*: pointer # ptr RiverSeatV1
      resizeEdges*: uint32
    of MsgKind.WlOverviewPointerDragRequested:
      overviewDragWinId*: uint32
      overviewDragSeat*: pointer # ptr RiverSeatV1
      overviewDragX*, overviewDragY*: int32
    of MsgKind.WlOverviewPointerScrollRequested:
      overviewScrollSeat*: pointer # ptr RiverSeatV1
      overviewScrollX*, overviewScrollY*: int32
    of MsgKind.WlOverviewWheel:
      overviewWheelX*, overviewWheelY*: int32
      overviewWheelHorizontal*, overviewWheelVertical*: int32
    of MsgKind.WlRecentWindowPointerMotion:
      recentPointerX*, recentPointerY*: int32
    of MsgKind.WlPointerDelta:
      dx*, dy*: int32
    of MsgKind.WlShellSurfaceInteraction:
      shellSurfaceId*: uint32
    of MsgKind.WlModifiersChanged:
      oldModifiers*: uint32
      newModifiers*: uint32
    of MsgKind.CmdOverviewTab:
      overviewTabModifiers*: uint32
    of MsgKind.CmdMoveFloating:
      moveDX*, moveDY*: int32
    of MsgKind.CmdSetLayout:
      newLayout*: LayoutMode
      layoutTargetTag*: uint32
    of MsgKind.CmdFocusDirection:
      direction*: Direction
    of MsgKind.CmdRecentWindowNext, MsgKind.CmdRecentWindowPrev:
      recentScope*: RecentWindowScope
      recentScopeSet*: bool
      recentFilter*: RecentWindowFilter
      recentFilterSet*: bool
    of MsgKind.CmdRecentWindowScope:
      recentTargetScope*: RecentWindowScope
    of MsgKind.CmdMoveToTag:
      targetTag*: uint32
    of MsgKind.CmdMoveWindowToTag:
      moveWindowId*: uint32
      moveTargetTag*: uint32
      moveFollowWindow*: bool
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
    of MsgKind.CmdSwitchProportionPreset:
      proportionPresetDelta*: int
    of MsgKind.CmdAdjustGaps:
      deltaG*: int32
    of MsgKind.CmdResizeFloating:
      deltaFW*, deltaFH*: int32
    of MsgKind.CmdFocusTag:
      focusTag*: uint32
    of MsgKind.CmdFocusWorkspaceIndex, MsgKind.CmdMoveToWorkspaceIndex:
      workspaceIndex*: uint32
    of MsgKind.CmdReorderWorkspaceIndex:
      reorderWorkspaceIndex*: uint32
      reorderTargetIndex*: uint32
    of MsgKind.CmdMoveWindowToWorkspaceIndex:
      moveWorkspaceWindowId*: uint32
      moveWorkspaceIndex*: uint32
      moveWorkspaceFollowWindow*: bool
    of MsgKind.CmdFocusOutput, MsgKind.CmdMoveWorkspaceToOutput, MsgKind.CmdMoveToOutput:
      outputTarget*: string
    of MsgKind.CmdFocusWindowById:
      focusWindowId*: uint32
    of MsgKind.CmdSetWindowFloatingById:
      floatingWindowId*: uint32
      windowFloating*: bool
    of MsgKind.CmdSetWindowMaximizedById:
      maximizedWindowId*: uint32
      windowMaximized*: bool
    of MsgKind.CmdCloseWindowById:
      closeWindowId*: uint32
    of MsgKind.CmdToggleFullscreenById, MsgKind.CmdExitFullscreenById:
      fullscreenWindowId*: uint32
    of MsgKind.CmdSpawn:
      spawnCommand*: seq[string]
    of MsgKind.CmdWarpPointer:
      warpX*, warpY*: int32
    of MsgKind.CmdSwitchKeyboardLayout:
      keyboardLayoutDelta*: int32
      keyboardLayoutIndex*: int32
    of MsgKind.CmdScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotPointerMode*: ScreenshotPointerMode
      screenshotWriteToDisk*: bool
      screenshotCopyToClipboard*: bool
    else:
      discard
