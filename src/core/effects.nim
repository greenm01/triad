import model, msg

type
  EffectKind* = enum
    EffNone,
    EffManageFinish,
    EffRenderFinish,
    EffProposeDimensions,
    EffSetPosition,
    EffFocusWindow,
    EffFocusShellSurface,
    EffCloseWindow,
    EffManageDirty,
    EffBroadcastJson,
    EffBroadcastTriadJson,
    EffOpStartPointer,
    EffOpEnd,
    EffSetFullscreen,
    EffSetMaximized,
    EffInformResizeStart,
    EffInformResizeEnd,
    EffSpawnScreenLock,
    EffSpawnWindowMenu,
    EffSpawn,
    EffPointerWarp,
    EffEnsureNextKeyEaten,
    EffCancelEnsureNextKeyEaten,
    EffStopManager,
    EffTriadReload,
    EffExitSession,
    EffFocusShellUi,
    EffScreenshot,
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
    of EffFocusShellSurface:
      focusShellSurfaceId*: uint32
    of EffCloseWindow:
      closeId*: WindowId
    of EffBroadcastJson, EffBroadcastTriadJson:
      jsonPayload*: string
      triadEventName*: string
    of EffOpStartPointer:
      opSeat*: pointer
    of EffOpEnd:
      endSeat*: pointer
    of EffSetFullscreen:
      fsWinId*: WindowId
      isFullscreen*: bool
      fsOutputId*: uint32
    of EffSetMaximized:
      maxWinId*: WindowId
      isMaximized*: bool
    of EffInformResizeStart, EffInformResizeEnd:
      resizeLifecycleWinId*: WindowId
    of EffSpawnScreenLock:
      screenLockCommand*: seq[string]
    of EffSpawnWindowMenu:
      windowMenuCommand*: seq[string]
      windowMenuId*: WindowId
      windowMenuX*: int32
      windowMenuY*: int32
    of EffSpawn:
      spawnCommand*: seq[string]
    of EffPointerWarp:
      warpX*, warpY*: int32
    of EffScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotShowPointer*: bool
    else:
      discard
