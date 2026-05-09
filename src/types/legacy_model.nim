import tables
import runtime_values

export runtime_values

type
  Model* = object
    tags*: Table[uint32, TagState]
    windows*: Table[WindowId, WindowData]
    outputs*: Table[uint32, OutputData]
    primaryOutput*: uint32
    outputTags*: Table[uint32, uint32]
    groups*: Table[uint32, GroupState]
    tagRules*: seq[TagRule]
    workspaces*: WorkspaceConfig
    windowRules*: seq[WindowRule]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    overview*: OverviewConfig
    floating*: FloatingConfig
    screenLock*: ScreenLockConfig
    windowMenu*: WindowMenuConfig
    scratchpad*: ScratchpadConfig
    cursor*: CursorConfig
    presentationMode*: PresentationMode
    allowExitSession*: bool
    protocolSurfaces*: ProtocolSurfacesConfig
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]
    pointerOp*: PointerOpState
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool
    activeTag*: uint32
    overviewActive*: bool
    layerFocusExclusive*: bool
    sessionLocked*: bool
    activeModifiers*: uint32
    screenWidth*: int32
    screenHeight*: int32
    outerGaps*: int32
    innerGaps*: int32
    previousOuterGaps*: int32
    previousInnerGaps*: int32
    smartGaps*: bool
    borderWidth*: int32
    focusedBorderColor*: uint32
    unfocusedBorderColor*: uint32
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    centerFocusedColumn*: string
    defaultColumnWidth*: float32
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    enableAnimations*: bool
    animationSpeed*: float32
    layoutCycle*: seq[LayoutMode]
    scratchpadWidthRatio*: float32
    scratchpadHeightRatio*: float32
    focusHistory*: seq[WindowId]
    workspaceHistory*: seq[uint32]
    restoreActiveTag*: uint32
    restoreTagByWindow*: Table[WindowId, uint32]
    restoreWindows*: Table[WindowId, RestoredWindowState]
    restoreTags*: Table[uint32, RestoredTagState]
    restoreFocusedWindow*: WindowId
    nextGroupId*: uint32
