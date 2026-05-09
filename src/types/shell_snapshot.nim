import options
from runtime_values import LayoutMode, Rect, WindowId

const TriadIpcVersion* = 1

type
  ShellColumn* = object
    idx*: uint32
    widthProportion*: float32
    windows*: seq[WindowId]

  ShellWorkspace* = object
    tagId*: uint32
    workspaceIdx*: uint32
    name*: string
    layoutMode*: LayoutMode
    isActive*: bool
    focusedWindow*: WindowId
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
    id*: WindowId
    title*: string
    appId*: string
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
    fullscreenOutput*: uint32
    widthProportion*: float32
    heightProportion*: float32
    actualW*: int32
    actualH*: int32
    floatingGeom*: Rect
    keyboardShortcutsInhibit*: bool

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
    layoutCycle*: seq[LayoutMode]
    workspaces*: seq[ShellWorkspace]
    windows*: seq[ShellWindow]
    outputs*: seq[ShellOutput]
