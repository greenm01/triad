import msg
import ../types/runtime_values

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
      windowId*: WindowId
      x*, y*, w*, h*: int32
    of EffectKind.EffFocusWindow:
      focusId*: WindowId
    of EffectKind.EffFocusShellSurface:
      focusShellSurfaceId*: uint32
    of EffectKind.EffCloseWindow:
      closeId*: WindowId
    of EffectKind.EffBroadcastJson, EffectKind.EffBroadcastTriadJson:
      jsonPayload*: string
      triadEventName*: string
    of EffectKind.EffOpStartPointer:
      opSeat*: pointer
    of EffectKind.EffOpEnd:
      endSeat*: pointer
    of EffectKind.EffSetFullscreen:
      fsWinId*: WindowId
      isFullscreen*: bool
      fsOutputId*: uint32
    of EffectKind.EffSetMaximized:
      maxWinId*: WindowId
      isMaximized*: bool
    of EffectKind.EffInformResizeStart, EffectKind.EffInformResizeEnd:
      resizeLifecycleWinId*: WindowId
    of EffectKind.EffSpawnScreenLock:
      screenLockCommand*: seq[string]
    of EffectKind.EffSpawnWindowMenu:
      windowMenuCommand*: seq[string]
      windowMenuId*: WindowId
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
