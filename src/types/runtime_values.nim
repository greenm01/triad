import core

type
  JanetLayoutId* = distinct string
  NativeLayoutId* = distinct string

  PresentationMode* {.pure.} = enum
    PresentationDefault
    PresentationVsync
    PresentationAsync

  OutputConfigTransform* {.pure.} = enum
    OutputTransformNormal
    OutputTransform90
    OutputTransform180
    OutputTransform270
    OutputTransformFlipped
    OutputTransformFlipped90
    OutputTransformFlipped180
    OutputTransformFlipped270

  LayoutMode* {.pure.} = enum
    Scroller
    VerticalScroller
    MasterStack
    Grid
    Monocle
    Deck
    CenterTile
    RightTile
    VerticalTile
    VerticalGrid
    VerticalDeck
    TGMix

  LayoutSelectionKind* {.pure.} = enum
    Builtin
    Custom
    Native

  FrameNodeKind* {.pure.} = enum
    Leaf
    Split

  FrameSplitOrientation* {.pure.} = enum
    Horizontal
    Vertical

  LayoutSelection* = object
    kind*: LayoutSelectionKind
    builtin*: LayoutMode
    customId*: JanetLayoutId
    nativeId*: NativeLayoutId

  JanetLayoutConfig* = object
    id*: JanetLayoutId
    fallback*: LayoutSelection

  NativeLayoutConfig* = object
    id*: NativeLayoutId
    fallback*: LayoutSelection

  FrameTabsConfig* = object
    activeColor*: uint32
    activeUnfocusedColor*: uint32
    inactiveColor*: uint32
    activeLineColor*: uint32
    activeUnfocusedLineColor*: uint32

  Direction* {.pure.} = enum
    DirLeft
    DirRight
    DirUp
    DirDown

  ParentedRole* {.pure.} = enum
    Dialog
    Tool
    Plain

  WindowRuleMaximizePolicy* {.pure.} = enum
    Edge
    Column
    Ignore

  WindowRuleIdleInhibitMode* {.pure.} = enum
    IdleInhibitNone
    IdleInhibitFocused
    IdleInhibitVisible

  FloatingPositionAnchor* {.pure.} = enum
    TopLeft
    TopRight
    BottomLeft
    BottomRight
    Top
    Bottom
    Left
    Right

  WindowRuleFloatingConfig* = object
    xRatioSet*: bool
    xRatio*: float32
    yRatioSet*: bool
    yRatio*: float32
    widthRatioSet*: bool
    widthRatio*: float32
    widthSet*: bool
    width*: int32
    heightRatioSet*: bool
    heightRatio*: float32
    heightSet*: bool
    height*: int32

  WindowRuleFloatingPositionConfig* = object
    set*: bool
    x*, y*: int32
    relativeTo*: FloatingPositionAnchor

  WindowRuleBorderConfig* = object
    widthSet*: bool
    width*: int32
    activeColorSet*: bool
    activeColor*: uint32
    inactiveColorSet*: bool
    inactiveColor*: uint32

  WindowRuleFocusRingConfig* = object
    widthSet*: bool
    width*: int32
    activeColorSet*: bool
    activeColor*: uint32

  WindowRuleMatcher* = object
    appIdSet*: bool
    appId*: string
    titleSet*: bool
    title*: string
    isActiveSet*: bool
    isActive*: bool
    isFocusedSet*: bool
    isFocused*: bool
    isActiveInColumnSet*: bool
    isActiveInColumn*: bool
    isFloatingSet*: bool
    isFloating*: bool
    atStartupSet*: bool
    atStartup*: bool

  WindowRule* = object
    appIdMatch*: string
    titleMatch*: string
    matches*: seq[WindowRuleMatcher]
    excludes*: seq[WindowRuleMatcher]
    defaultWorkspace*: uint32
    defaultWorkspaces*: seq[uint32]
    openOnOutput*: string
    defaultColumnWidthSet*: bool
    defaultColumnWidth*: float32
    scrollerProportionSet*: bool
    scrollerProportion*: float32
    scrollerSingleProportionSet*: bool
    scrollerSingleProportion*: float32
    defaultWindowWidthSet*: bool
    defaultWindowWidth*: float32
    defaultWindowHeightSet*: bool
    defaultWindowHeight*: float32
    minWidthSet*: bool
    minWidth*: int32
    minHeightSet*: bool
    minHeight*: int32
    maxWidthSet*: bool
    maxWidth*: int32
    maxHeightSet*: bool
    maxHeight*: int32
    openFloatingSet*: bool
    openFloating*: bool
    openFocusedSet*: bool
    openFocused*: bool
    openFullscreenSet*: bool
    openFullscreen*: bool
    openMaximizedSet*: bool
    openMaximized*: bool
    openMaximizedToEdgesSet*: bool
    openMaximizedToEdges*: bool
    openOnAllWorkspacesSet*: bool
    openOnAllWorkspaces*: bool
    openOverlaySet*: bool
    openOverlay*: bool
    openUnmanagedGlobalSet*: bool
    openUnmanagedGlobal*: bool
    terminalSet*: bool
    terminal*: bool
    allowSwallowSet*: bool
    allowSwallow*: bool
    maximizePolicySet*: bool
    maximizePolicy*: WindowRuleMaximizePolicy
    respectSizeHintsSet*: bool
    respectSizeHints*: bool
    centerFloatingSet*: bool
    centerFloating*: bool
    parentedRoleSet*: bool
    parentedRole*: ParentedRole
    openNamedScratchpad*: string
    floating*: WindowRuleFloatingConfig
    defaultFloatingPosition*: WindowRuleFloatingPositionConfig
    border*: WindowRuleBorderConfig
    focusRing*: WindowRuleFocusRingConfig
    clipToGeometrySet*: bool
    clipToGeometry*: bool
    dialogViewportJumpSet*: bool
    dialogViewportJump*: bool
    keyboardShortcutsInhibitSet*: bool
    keyboardShortcutsInhibit*: bool
    idleInhibitModeSet*: bool
    idleInhibitMode*: WindowRuleIdleInhibitMode
    presentationModeSet*: bool
    presentationMode*: PresentationMode
    tiledStateSet*: bool
    tiledState*: bool
    forcedLayoutSet*: bool
    forcedLayout*: int

  TagRule* = object
    tagId*: uint32
    name*: string
    defaultLayoutSet*: bool
    defaultLayout*: LayoutMode
    defaultLayoutSelection*: LayoutSelection
    openOnOutput*: string

  OutputRule* = object
    target*: string
    focusAtStartup*: bool
    workspaceSlots*: seq[uint32]
    modeSet*: bool
    modeWidth*: int32
    modeHeight*: int32
    modeRefresh*: int32
    scaleSet*: bool
    scale*: float32
    positionSet*: bool
    positionX*: int32
    positionY*: int32
    transformSet*: bool
    transform*: OutputConfigTransform
    adaptiveSyncSet*: bool
    adaptiveSync*: bool

  EnvironmentEntryConfig* = object
    name*: string
    value*: string
    unset*: bool

  WorkspaceConfig* = object
    defaultCount*: uint32
    defaultLayout*: LayoutMode
    defaultLayoutSelection*: LayoutSelection

  QuickshellConfig* = object
    enabled*: bool
    command*: string
    theme*: string
    args*: seq[string]

  ShellProfileConfig* = object
    name*: string
    launch*: seq[string]
    stop*: seq[string]
    niriCompat*: bool

  ShellWatchdogConfig* = object
    enabled*: bool
    fallback*: string
    exclusiveFocusTimeoutMs*: int32

  ShellsConfig* = object
    configured*: bool
    enabled*: bool
    active*: string
    cycle*: seq[string]
    profiles*: seq[ShellProfileConfig]
    watchdog*: ShellWatchdogConfig

  JanetConfig* = object
    enabled*: bool
    scriptDir*: string
    fuelLimit*: int32
    layouts*: seq[JanetLayoutConfig]

  TerminalConfig* = object
    command*: seq[string]

  ScreenshotConfig* = object
    directory*: string
    filenamePrefix*: string
    captureCommand*: string
    regionSelectorCommand*: string
    clipboardCommand*: string
    showPointer*: bool

  OverviewHotCornersConfig* = object
    size*: int32
    topLeft*: bool
    topRight*: bool
    bottomLeft*: bool
    bottomRight*: bool

  OverviewConfig* = object
    outerGap*: int32
    innerGapMultiplier*: float32
    zoom*: float32
    tabMode*: bool
    scrollerIndicators*: bool
    hotCorners*: OverviewHotCornersConfig

  RecentWindowDirection* {.pure.} = enum
    Forward
    Backward

  RecentWindowScope* {.pure.} = enum
    All
    Workspace
    Output

  RecentWindowFilter* {.pure.} = enum
    All
    AppId

  RecentWindowsHighlightConfig* = object
    activeColor*: uint32
    urgentColor*: uint32
    padding*: int32
    cornerRadius*: int32

  RecentWindowsPreviewConfig* = object
    maxHeight*: int32
    maxScale*: float32

  RecentWindowsConfig* = object
    enabled*: bool
    debounceMs*: int32
    openDelayMs*: int32
    highlight*: RecentWindowsHighlightConfig
    previews*: RecentWindowsPreviewConfig

  LayoutSwitchToastConfig* = object
    enabled*: bool
    timeoutMs*: int32
    ringColor*: uint32

  FloatingConfig* = object
    xRatio*: float32
    yRatio*: float32
    widthRatio*: float32
    heightRatio*: float32
    minWidth*: int32
    minHeight*: int32

  ScreenLockConfig* = object
    command*: seq[string]

  WindowMenuConfig* = object
    command*: seq[string]

  ScratchpadConfig* = object
    widthRatio*: float32
    heightRatio*: float32

  CursorConfig* = object
    theme*: string
    size*: uint32
    shakeToFind*: bool
    hideWhenTyping*: bool
    hideAfterInactiveMs*: int32

  InputAccelProfile* {.pure.} = enum
    AccelNone
    AccelFlat
    AccelAdaptive

  InputScrollMethod* {.pure.} = enum
    ScrollNone
    ScrollTwoFinger
    ScrollEdge
    ScrollOnButtonDown

  InputClickMethod* {.pure.} = enum
    ClickButtonAreas
    ClickFinger

  InputButtonMap* {.pure.} = enum
    ButtonMapLeftRightMiddle
    ButtonMapLeftMiddleRight

  InputXkbConfig* = object
    rulesSet*: bool
    rules*: string
    modelSet*: bool
    model*: string
    layoutSet*: bool
    layout*: string
    variantSet*: bool
    variant*: string
    optionsSet*: bool
    options*: string

  InputKeyboardConfig* = object
    repeatRateSet*: bool
    repeatRate*: int32
    repeatDelaySet*: bool
    repeatDelay*: int32
    numlockSet*: bool
    numlock*: bool
    capslockSet*: bool
    capslock*: bool
    xkb*: InputXkbConfig

  InputPointerConfig* = object
    offSet*: bool
    off*: bool
    naturalScrollSet*: bool
    naturalScroll*: bool
    accelProfileSet*: bool
    accelProfile*: InputAccelProfile
    accelSpeedSet*: bool
    accelSpeed*: float32
    scrollMethodSet*: bool
    scrollMethod*: InputScrollMethod
    scrollButtonSet*: bool
    scrollButton*: uint32
    scrollButtonLockSet*: bool
    scrollButtonLock*: bool
    leftHandedSet*: bool
    leftHanded*: bool
    middleEmulationSet*: bool
    middleEmulation*: bool
    scrollFactorSet*: bool
    scrollFactor*: float32

  InputTouchpadConfig* = object
    pointer*: InputPointerConfig
    tapSet*: bool
    tap*: bool
    tapButtonMapSet*: bool
    tapButtonMap*: InputButtonMap
    dragSet*: bool
    drag*: bool
    dragLockSet*: bool
    dragLock*: bool
    dwtSet*: bool
    dwt*: bool
    dwtpSet*: bool
    dwtp*: bool
    clickMethodSet*: bool
    clickMethod*: InputClickMethod
    disabledOnExternalMouseSet*: bool
    disabledOnExternalMouse*: bool

  InputConfig* = object
    keyboard*: InputKeyboardConfig
    mouse*: InputPointerConfig
    touchpad*: InputTouchpadConfig
    trackpoint*: InputPointerConfig
    trackball*: InputPointerConfig

  HotkeyOverlayPosition* {.pure.} = enum
    Top
    Center
    Bottom

  HotkeyOverlayConfig* = object
    skipAtStartup*: bool
    hideNotBound*: bool
    position*: HotkeyOverlayPosition
    columns*: int32

  HotkeyOverlayRow* = object
    key*: string
    label*: string

  PointerOpKind* {.pure.} = enum
    OpNone
    OpMove
    OpResize
    OpOverviewDrag
    OpOverviewScroll

  HotkeyOverlayTitleKind* {.pure.} = enum
    HotkeyTitleDefault
    HotkeyTitleCustom
    HotkeyTitleHidden

  BindingMode* {.pure.} = enum
    BindAlways
    BindNormal
    BindOverview
    BindRecent

  AxisBindingDirection* {.pure.} = enum
    AxisNone
    AxisUp
    AxisDown
    AxisLeft
    AxisRight

  GestureBindingDirection* {.pure.} = enum
    GestureNone
    GestureSwipeLeft
    GestureSwipeRight
    GestureSwipeUp
    GestureSwipeDown

  SwitchEventKind* {.pure.} = enum
    SwitchNone
    SwitchLidClose
    SwitchLidOpen
    SwitchTabletModeOn
    SwitchTabletModeOff

  ConfigNotificationEvent* {.pure.} = enum
    ConfigNotifyNone
    ConfigReloadSucceeded
    ConfigReloadFailed
    ConfigReloadRolledBack

  KeyBindingConfig* = object
    key*: string
    modifiers*: uint32
    command*: string
    mode*: BindingMode
    hasLayoutOverride*: bool
    layoutOverride*: uint32
    onRelease*: bool
    whileLocked*: bool
    bypassShortcutsInhibit*: bool
    hotkeyOverlayTitleKind*: HotkeyOverlayTitleKind
    hotkeyOverlayTitle*: string

  PointerBindingConfig* = object
    button*: uint32
    modifiers*: uint32
    op*: PointerOpKind
    command*: string
    mode*: BindingMode
    bypassShortcutsInhibit*: bool

  AxisBindingConfig* = object
    direction*: AxisBindingDirection
    modifiers*: uint32
    command*: string
    mode*: BindingMode
    bypassShortcutsInhibit*: bool

  GestureBindingConfig* = object
    direction*: GestureBindingDirection
    fingers*: uint32
    modifiers*: uint32
    command*: string
    mode*: BindingMode
    bypassShortcutsInhibit*: bool

  SwitchEventConfig* = object
    kind*: SwitchEventKind
    command*: string

  ConfigNotificationConfig* = object
    reloadSucceeded*: seq[string]
    reloadFailed*: seq[string]
    reloadRolledBack*: seq[string]

  ProtocolSurfacesConfig* = object
    enabled*: bool
    visibleDebug*: bool

  PointerOpState* = object
    kind*: PointerOpKind
    windowId*: uint32
    initialGeom*: Rect
    edges*: uint32
