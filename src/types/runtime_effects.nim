import runtime_messages

type
  EffectKind* {.pure.} = enum
    EffNone
    EffManageFinish
    EffRenderFinish
    EffProposeDimensions
    EffSetPosition
    EffFocusWindow
    EffFocusShellSurface
    EffCloseWindow
    EffManageDirty
    EffBroadcastJson
    EffBroadcastTriadJson
    EffOpStartPointer
    EffOpEnd
    EffSetFullscreen
    EffSetMaximized
    EffSetIdleInhibit
    EffInformResizeStart
    EffInformResizeEnd
    EffSpawnScreenLock
    EffSpawnWindowMenu
    EffSpawn
    EffPointerWarp
    EffEnsureNextKeyEaten
    EffCancelEnsureNextKeyEaten
    EffStopManager
    EffTriadReload
    EffExitSession
    EffFocusShellUi
    EffScreenshot
    EffLog

  Effect* = object
    case kind*: EffectKind
    of EffectKind.EffLog:
      msg*: string
    of EffectKind.EffSetPosition:
      windowId*: uint32
      x*, y*, w*, h*: int32
    of EffectKind.EffFocusWindow:
      focusId*: uint32
    of EffectKind.EffFocusShellSurface:
      focusShellSurfaceId*: uint32
    of EffectKind.EffCloseWindow:
      closeId*: uint32
    of EffectKind.EffBroadcastJson, EffectKind.EffBroadcastTriadJson:
      jsonPayload*: string
      triadEventName*: string
    of EffectKind.EffOpStartPointer:
      opSeat*: pointer
    of EffectKind.EffOpEnd:
      endSeat*: pointer
    of EffectKind.EffSetFullscreen:
      fsWinId*: uint32
      isFullscreen*: bool
      fsOutputId*: uint32
    of EffectKind.EffSetMaximized:
      maxWinId*: uint32
      isMaximized*: bool
    of EffectKind.EffSetIdleInhibit:
      idleInhibitActive*: bool
    of EffectKind.EffInformResizeStart, EffectKind.EffInformResizeEnd:
      resizeLifecycleWinId*: uint32
    of EffectKind.EffSpawnScreenLock:
      screenLockCommand*: seq[string]
    of EffectKind.EffSpawnWindowMenu:
      windowMenuCommand*: seq[string]
      windowMenuId*: uint32
      windowMenuX*: int32
      windowMenuY*: int32
    of EffectKind.EffSpawn:
      spawnCommand*: seq[string]
    of EffectKind.EffPointerWarp:
      warpX*, warpY*: int32
    of EffectKind.EffScreenshot:
      screenshotKind*: ScreenshotKind
      screenshotPath*: string
      screenshotPointerMode*: ScreenshotPointerMode
      screenshotWriteToDisk*: bool
      screenshotCopyToClipboard*: bool
    else:
      discard
