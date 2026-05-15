import std/tables
import wayland/native/client
import protocols/river/client as river
from ../types/runtime_values import WindowId

type
  ProtocolSurfaceKind* {.pure.} = enum
    PskShell
    PskHotkeyOverlay
    PskExitSessionConfirm
    PskRecentWindows
    PskRecentWindowsChrome
    PskDecorationAbove
    PskDecorationBelow

  OwnedProtocolSurface* = object
    surface*: ptr Surface
    buffer*: ptr Buffer
    shellSurface*: ptr RiverShellSurfaceV1
    decoration*: ptr RiverDecorationV1
    node*: ptr RiverNodeV1
    bufferW*: int32
    bufferH*: int32
    inputW*: int32
    inputH*: int32
    windowId*: WindowId
    kind*: ProtocolSurfaceKind
    offsetX*: int32
    offsetY*: int32
    bufferCacheKey*: string
    syncPending*: bool

  ProtocolSurfaceRuntime* = object
    surfaces*: Table[uint32, OwnedProtocolSurface]
    ownedShellSurfaceId*: uint32
    hotkeyOverlaySurfaceId*: uint32
    exitSessionConfirmSurfaceId*: uint32
    recentWindowsSurfaceId*: uint32
    recentWindowsChromeSurfaceId*: uint32
    windowDecorationAbove*: Table[WindowId, uint32]
    windowDecorationBelow*: Table[WindowId, uint32]
