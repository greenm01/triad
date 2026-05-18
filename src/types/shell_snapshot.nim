import std/options
from core import Rect
from runtime_values import
  FrameNodeKind, FrameSplitOrientation, JanetLayoutConfig, LayoutMode, LayoutSelection,
  NativeLayoutConfig, WindowRuleIdleInhibitMode

const TriadIpcVersion* = 1

type
  ShellColumn* = object
    idx*: uint32
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool
    windows*: seq[uint32]

  ShellFrame* = object
    id*: uint32
    kind*: FrameNodeKind
    parent*: uint32
    firstChild*: uint32
    secondChild*: uint32
    orientation*: FrameSplitOrientation
    ratio*: float32
    windows*: seq[uint32]
    activeWindow*: uint32
    focused*: bool

  ShellWorkspace* = object
    tagId*: uint32
    workspaceIdx*: uint32
    name*: string
    layoutMode*: LayoutMode
    layoutId*: string
    layoutKind*: string
    fallbackLayout*: string
    isActive*: bool
    isOutputVisible*: bool
    focusedWindow*: uint32
    occupied*: bool
    outputName*: string
    columns*: seq[ShellColumn]
    frames*: seq[ShellFrame]
    masterCount*: int
    masterSplitRatio*: float32
    targetViewportXOffset*: float32
    currentViewportXOffset*: float32
    targetViewportYOffset*: float32
    currentViewportYOffset*: float32

  ShellWindow* = object
    id*: uint32
    pid*: int32
    parentId*: uint32
    title*: string
    appId*: string
    identifier*: string
    tagId*: Option[uint32]
    workspaceIdx*: uint32
    outputName*: string
    colIdx*: uint32
    winIdx*: uint32
    isFocused*: bool
    isFloating*: bool
    isFullscreen*: bool
    isMaximized*: bool
    isMinimized*: bool
    isSticky*: bool
    isOverlay*: bool
    isUnmanagedGlobal*: bool
    fullscreenOutput*: uint32
    widthProportion*: float32
    heightProportion*: float32
    actualW*: int32
    actualH*: int32
    floatingGeom*: Rect
    keyboardShortcutsInhibit*: bool
    idleInhibitMode*: WindowRuleIdleInhibitMode
    isTerminal*: bool
    allowSwallow*: bool
    swallowedBy*: uint32
    swallowing*: uint32

  ShellOutput* = object
    id*: uint32
    name*: string
    x*, y*, w*, h*: int32
    refreshRate*: int32
    isPrimary*: bool

  ShellSnapshot* = object
    version*: uint32
    activeTag*: uint32
    activeWorkspaceIdx*: uint32
    overviewActive*: bool
    overviewSelectedWindow*: uint32
    activeScratchpadWindow*: uint32
    sessionLocked*: bool
    layerFocusExclusive*: bool
    layoutCycle*: seq[LayoutMode]
    layoutCycleSelections*: seq[LayoutSelection]
    customLayouts*: seq[JanetLayoutConfig]
    nativeLayouts*: seq[NativeLayoutConfig]
    keyboardLayoutNames*: seq[string]
    keyboardLayoutIndex*: uint32
    workspaces*: seq[ShellWorkspace]
    windows*: seq[ShellWindow]
    outputs*: seq[ShellOutput]
