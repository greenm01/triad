import std/options
from core import Rect
from runtime_values import LayoutMode, WindowRuleIdleInhibitMode

const TriadIpcVersion* = 1

type
  ShellColumn* = object
    idx*: uint32
    widthProportion*: float32
    scrollerSingleProportion*: float32
    isFullWidth*: bool
    windows*: seq[uint32]

  ShellWorkspace* = object
    tagId*: uint32
    workspaceIdx*: uint32
    name*: string
    layoutMode*: LayoutMode
    isActive*: bool
    isOutputVisible*: bool
    focusedWindow*: uint32
    occupied*: bool
    outputName*: string
    columns*: seq[ShellColumn]
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
    workspaces*: seq[ShellWorkspace]
    windows*: seq[ShellWindow]
    outputs*: seq[ShellOutput]
