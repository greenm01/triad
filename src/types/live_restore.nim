import std/tables
from core import Rect
from runtime_values import
  FrameNodeKind, FrameSplitOrientation, JanetLayoutId, LayoutMode, NativeLayoutId

const LiveRestoreSchema* = "triad-live-restore-v2"
const
  LiveRestoreStatusPending* = "pending"
  LiveRestoreStatusApplied* = "applied"

type
  RestoredWindowState* = object
    tagId*: uint32
    parentId*: uint32
    swallowedBy*: uint32
    swallowing*: uint32
    pid*: int32
    appId*: string
    title*: string
    identifier*: string
    widthProportion*: float32
    heightProportion*: float32
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    isSticky*: bool
    isUnmanagedGlobal*: bool
    fullscreenOutput*: uint32
    floatingGeom*: Rect
    manualFloatingPosition*: bool
    isTerminal*: bool
    allowSwallow*: bool
    actualW*, actualH*: int32

  RestoredColumnState* = object
    windows*: seq[uint32]
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool

  RestoredFrameState* = object
    id*: uint32
    kind*: FrameNodeKind
    parent*: uint32
    firstChild*: uint32
    secondChild*: uint32
    orientation*: FrameSplitOrientation
    ratio*: float32
    windows*: seq[uint32]
    activeWindow*: uint32

  RestoredTagState* = object
    tagId*: uint32
    name*: string
    layoutMode*: LayoutMode
    customLayoutId*: JanetLayoutId
    nativeLayoutId*: NativeLayoutId
    columns*: seq[RestoredColumnState]
    frames*: seq[RestoredFrameState]
    focusedWindow*: uint32
    focusedFrame*: uint32
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32
    masterCount*: int
    masterSplitRatio*: float32

  LiveRestoreState* = object
    activeTag*: uint32
    focusedWindow*: uint32
    tagByWindow*: Table[uint32, uint32]
    windows*: Table[uint32, RestoredWindowState]
    tags*: Table[uint32, RestoredTagState]
    outputTags*: Table[uint32, uint32]
    scratchpadWindows*: seq[uint32]
    namedScratchpads*: Table[string, uint32]
    scratchpadRestoreSlots*: Table[uint32, seq[uint32]]
    visibleScratchpad*: uint32
    isScratchpadVisible*: bool
    focusHistory*: seq[uint32]
    workspaceHistory*: seq[uint32]
    swallowedBy*: Table[uint32, uint32]
    swallowing*: Table[uint32, uint32]

  LiveRestoreWriteResult* = object
    ok*: bool
    path*: string
    error*: string
