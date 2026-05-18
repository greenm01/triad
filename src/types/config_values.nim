import kdl
import runtime_values

type
  Config* = object
    layout*: LayoutConfig
    workspaces*: WorkspaceConfig
    outputRules*: seq[OutputRule]
    tagRules*: seq[TagRule]
    windowRules*: seq[WindowRule]
    environment*: seq[EnvironmentEntryConfig]
    startupCommands*: seq[seq[string]]
    quickshell*: QuickshellConfig
    shells*: ShellsConfig
    janet*: JanetConfig
    terminal*: TerminalConfig
    screenshot*: ScreenshotConfig
    input*: InputConfig
    overview*: OverviewConfig
    recentWindows*: RecentWindowsConfig
    layoutSwitchToast*: LayoutSwitchToastConfig
    floating*: FloatingConfig
    screenLock*: ScreenLockConfig
    windowMenu*: WindowMenuConfig
    scratchpad*: ScratchpadConfig
    cursor*: CursorConfig
    hotkeyOverlay*: HotkeyOverlayConfig
    configNotification*: ConfigNotificationConfig
    presentationMode*: PresentationMode
    allowExitSession*: bool
    protocolSurfaces*: ProtocolSurfacesConfig
    mirrorHjklArrows*: bool
    keyBindings*: seq[KeyBindingConfig]
    pointerBindings*: seq[PointerBindingConfig]
    axisBindings*: seq[AxisBindingConfig]
    gestureBindings*: seq[GestureBindingConfig]
    switchEvents*: seq[SwitchEventConfig]

  LayoutConfig* = object
    gaps*: int32
    centerFocusedColumn*: string
    defaultColumnWidth*: float32
    defaultWindowWidth*: float32
    defaultWindowHeight*: float32
    defaultMasterCount*: int
    defaultMasterRatio*: float32
    borderWidth*: int32
    focusedBorderColor*: uint32
    unfocusedBorderColor*: uint32
    frameTabs*: FrameTabsConfig
    scrollerFocusCenter*: bool
    scrollerPreferCenter*: bool
    scrollerProportionPresets*: seq[float32]
    enableAnimations*: bool
    animationSpeed*: float32
    animationSnapThreshold*: float32
    frameRate*: int32
    smartGaps*: bool
    layoutCycle*: seq[LayoutMode]
    layoutSelections*: seq[LayoutSelection]

  ConfigLoadResult* = object
    ok*: bool
    config*: Config
    configPaths*: seq[string]
    error*: string

  ConfigDocument* = object
    nodes*: KdlDoc
    paths*: seq[string]
