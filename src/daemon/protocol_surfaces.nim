import std/tables
import wayland/native/client
import protocols/river/client as river

type
  ProtocolSurfaceKind* {.pure.} = enum
    PskShell
    PskHotkeyOverlay
    PskExitSessionConfirm
    PskLayoutSwitchToast
    PskRecentWindows
    PskRecentWindowsChrome
    PskDecorationAbove
    PskDecorationBelow
    PskFrameEmpty

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
    windowId*: uint32
    frameId*: uint32
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
    layoutSwitchToastSurfaceId*: uint32
    recentWindowsSurfaceId*: uint32
    recentWindowsChromeSurfaceId*: uint32
    windowDecorationAbove*: Table[uint32, uint32]
    windowDecorationBelow*: Table[uint32, uint32]
    frameEmptySurfaces*: Table[uint32, uint32]
    surfaceToOwned*: Table[uint32, uint32]
