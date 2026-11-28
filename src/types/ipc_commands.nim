type
  CommandId* {.pure.} = enum
    FocusNext
    FocusPrev
    FocusLeft
    FocusRight
    FocusUp
    FocusDown
    FocusLast
    SwitchFocusBetweenFloatingAndTiling
    FocusTagLeft
    FocusTagRight
    FocusOccupiedTagLeft
    FocusOccupiedTagRight
    FocusColumnFirst
    FocusColumnLast
    FocusWindowOrWorkspaceUp
    FocusWindowOrWorkspaceDown
    MoveToTagLeft
    MoveToTagRight
    CloseWindow
    FocusWindow
    MoveWindowToTag
    MoveWindowToWorkspace
    SetWindowFloating
    SetWindowMaximized
    SetLayoutForWorkspace
    LayoutCustom
    LayoutNative
    FrameSplitHorizontal
    FrameSplitVertical
    FrameUnsplit
    FrameTabNext
    FrameTabPrev
    FrameResizeLeft
    FrameResizeRight
    FrameResizeUp
    FrameResizeDown
    FrameSplitToggle
    FrameFocusParent
    FrameFocusChild
    FrameBindApp
    FrameUnbindApp
    SplitTreeSplitHorizontal
    SplitTreeSplitVertical
    SplitTreeSplitToggle
    SplitTreeLayoutSplitHorizontal
    SplitTreeLayoutSplitVertical
    SplitTreeLayoutToggleSplit
    SplitTreeLayoutStacking
    SplitTreeLayoutTabbed
    SplitTreeFocusParent
    SplitTreeFocusChild
    SplitTreeLayoutCycleAll
    SplitTreeLayoutDefault
    SplitTreeLayoutCycleList
    SplitTreeFocusNextSibling
    SplitTreeFocusPrevSibling
    BspBalance
    BspEqualize
    BspPreselectLeft
    BspPreselectRight
    BspPreselectUp
    BspPreselectDown
    DwindleSplitLeft
    DwindleSplitRight
    DwindleSplitUp
    DwindleSplitDown
    DwindleSplitHorizontal
    DwindleSplitVertical
    BspPreselectCancel
    BspPreselectRatio
    ConfigReload
    LayoutScroller
    LayoutVerticalScroller
    LayoutTile
    LayoutGrid
    LayoutMonocle
    LayoutDeck
    LayoutCenterTile
    LayoutRightTile
    LayoutVerticalTile
    LayoutVerticalGrid
    LayoutVerticalDeck
    LayoutTGMix
    LayoutSpiral
    SwitchLayout
    SwitchKeyboardLayout
    ToggleOverview
    OpenOverview
    CloseOverview
    RecentWindowNext
    RecentWindowPrev
    RecentWindowConfirm
    RecentWindowCancel
    RecentWindowFirst
    RecentWindowLast
    RecentWindowScope
    RecentWindowCycleScope
    RecentWindowCloseCurrent
    ToggleFloating
    ToggleFullscreen
    ExitFullscreen
    ToggleMaximized
    Minimize
    RestoreMinimized
    Screenshot
    ScreenshotScreen
    ScreenshotWindow
    Spawn
    SpawnTerminal
    LockSession
    PowerOffMonitors
    PowerOnMonitors
    PowerOffMonitor
    PowerOnMonitor
    WarpPointer
    EatNextKey
    CancelEatNextKey
    ToggleKeyboardShortcutsInhibit
    StopManager
    TriadReload
    ExitSession
    FocusShellUi
    SwitchShell
    CycleShell
    ShowHotkeyOverlay
    HideHotkeyOverlay
    ToggleHotkeyOverlay
    MoveToScratchpad
    MoveToNamedScratchpad
    ToggleScratchpad
    ToggleNamedScratchpad
    RestoreScratchpad
    SelectWindow
    RenameTag
    GroupWindows
    UngroupWindow
    FocusNextInGroup
    MoveFloating
    ResizeFloating
    MoveToTag
    MoveToWorkspace
    FocusOutput
    MoveWorkspaceToOutput
    MoveToOutput
    FocusWorkspace
    NewWorkspace
    FocusTag
    SwapToTag
    MasterCount
    AdjustMasterCount
    MasterRatio
    AdjustMasterRatio
    ResizeWidth
    ResizeHeight
    SetColumnWidth
    SwitchProportionPreset
    MaximizeColumn
    AdjustGaps
    ToggleGaps
    Zoom
    ConsumeWindow
    ExpelWindow
    MoveColumnLeft
    MoveColumnRight
    MoveColumnToFirst
    MoveColumnToLast
    MoveWindowLeft
    MoveWindowRight
    MoveWindowUp
    MoveWindowDown
    MoveWindowUpOrToWorkspaceUp
    MoveWindowDownOrToWorkspaceDown
    SwapWindowUp
    SwapWindowDown

  CommandArgShape* {.pure.} = enum
    NoArgs
    OptionalWindowId
    RequiredWindowId
    WindowTagFollow
    WindowWorkspaceFollow
    WindowBool
    TagLayout
    RequiredTag
    RequiredWorkspaceIdx
    RequiredName
    RequiredOutput
    RequiredFloatDelta
    RequiredFloatValue
    RequiredIntCount
    RequiredIntDelta
    OptionalIntDelta
    MoveDelta
    ResizeDelta
    RecentAdvance
    RecentScope
    SpawnArgv
    WarpPointer
    Screenshot
    SplitTreeModeList
    OptionalFloatDelta
    KeyboardLayoutTarget

  CommandMeta* = object
    argShape*: CommandArgShape
    defined: bool

  CommandSpelling* = tuple[text: string, id: CommandId, canonical: bool]

const
  CommandSpellings* = [
    (text: "focus-next", id: CommandId.FocusNext, canonical: true),
    (text: "focus-prev", id: CommandId.FocusPrev, canonical: true),
    (text: "focus-left", id: CommandId.FocusLeft, canonical: true),
    (text: "focus-right", id: CommandId.FocusRight, canonical: true),
    (text: "focus-up", id: CommandId.FocusUp, canonical: true),
    (text: "focus-down", id: CommandId.FocusDown, canonical: true),
    (text: "focus-last", id: CommandId.FocusLast, canonical: true),
    (
      text: "switch-focus-between-floating-and-tiling",
      id: CommandId.SwitchFocusBetweenFloatingAndTiling,
      canonical: true,
    ),
    (text: "focus-tag-left", id: CommandId.FocusTagLeft, canonical: true),
    (text: "focus-tag-right", id: CommandId.FocusTagRight, canonical: true),
    (
      text: "focus-occupied-tag-left",
      id: CommandId.FocusOccupiedTagLeft,
      canonical: true,
    ),
    (
      text: "focus-occupied-tag-right",
      id: CommandId.FocusOccupiedTagRight,
      canonical: true,
    ),
    (text: "focus-column-first", id: CommandId.FocusColumnFirst, canonical: true),
    (text: "focus-column-last", id: CommandId.FocusColumnLast, canonical: true),
    (
      text: "focus-window-or-workspace-up",
      id: CommandId.FocusWindowOrWorkspaceUp,
      canonical: true,
    ),
    (
      text: "focus-window-or-workspace-down",
      id: CommandId.FocusWindowOrWorkspaceDown,
      canonical: true,
    ),
    (text: "move-to-tag-left", id: CommandId.MoveToTagLeft, canonical: true),
    (text: "move-to-tag-right", id: CommandId.MoveToTagRight, canonical: true),
    (text: "close-window", id: CommandId.CloseWindow, canonical: true),
    (text: "focus-window", id: CommandId.FocusWindow, canonical: true),
    (text: "move-window-to-tag", id: CommandId.MoveWindowToTag, canonical: true),
    (
      text: "move-window-to-workspace",
      id: CommandId.MoveWindowToWorkspace,
      canonical: true,
    ),
    (text: "set-window-floating", id: CommandId.SetWindowFloating, canonical: true),
    (text: "set-window-maximized", id: CommandId.SetWindowMaximized, canonical: true),
    (
      text: "set-layout-for-workspace",
      id: CommandId.SetLayoutForWorkspace,
      canonical: true,
    ),
    (text: "layout-custom", id: CommandId.LayoutCustom, canonical: true),
    (text: "layout-native", id: CommandId.LayoutNative, canonical: true),
    (
      text: "frame-split-horizontal",
      id: CommandId.FrameSplitHorizontal,
      canonical: true,
    ),
    (text: "frame-split-vertical", id: CommandId.FrameSplitVertical, canonical: true),
    (text: "frame-unsplit", id: CommandId.FrameUnsplit, canonical: true),
    (text: "frame-tab-next", id: CommandId.FrameTabNext, canonical: true),
    (text: "frame-tab-prev", id: CommandId.FrameTabPrev, canonical: true),
    (text: "frame-resize-left", id: CommandId.FrameResizeLeft, canonical: true),
    (text: "frame-resize-right", id: CommandId.FrameResizeRight, canonical: true),
    (text: "frame-resize-up", id: CommandId.FrameResizeUp, canonical: true),
    (text: "frame-resize-down", id: CommandId.FrameResizeDown, canonical: true),
    (text: "frame-split-toggle", id: CommandId.FrameSplitToggle, canonical: true),
    (text: "frame-focus-parent", id: CommandId.FrameFocusParent, canonical: true),
    (text: "frame-focus-child", id: CommandId.FrameFocusChild, canonical: true),
    (text: "frame-bind-app", id: CommandId.FrameBindApp, canonical: true),
    (text: "frame-unbind-app", id: CommandId.FrameUnbindApp, canonical: true),
    (
      text: "split-tree-split-horizontal",
      id: CommandId.SplitTreeSplitHorizontal,
      canonical: true,
    ),
    (
      text: "split-tree-split-vertical",
      id: CommandId.SplitTreeSplitVertical,
      canonical: true,
    ),
    (
      text: "split-tree-split-toggle",
      id: CommandId.SplitTreeSplitToggle,
      canonical: true,
    ),
    (
      text: "split-tree-layout-split-horizontal",
      id: CommandId.SplitTreeLayoutSplitHorizontal,
      canonical: true,
    ),
    (
      text: "split-tree-layout-split-vertical",
      id: CommandId.SplitTreeLayoutSplitVertical,
      canonical: true,
    ),
    (
      text: "split-tree-layout-toggle-split",
      id: CommandId.SplitTreeLayoutToggleSplit,
      canonical: true,
    ),
    (
      text: "split-tree-layout-stacking",
      id: CommandId.SplitTreeLayoutStacking,
      canonical: true,
    ),
    (
      text: "split-tree-layout-tabbed",
      id: CommandId.SplitTreeLayoutTabbed,
      canonical: true,
    ),
    (
      text: "split-tree-focus-parent",
      id: CommandId.SplitTreeFocusParent,
      canonical: true,
    ),
    (text: "split-tree-focus-child", id: CommandId.SplitTreeFocusChild, canonical: true),
    (
      text: "split-tree-layout-cycle-all",
      id: CommandId.SplitTreeLayoutCycleAll,
      canonical: true,
    ),
    (
      text: "split-tree-layout-default",
      id: CommandId.SplitTreeLayoutDefault,
      canonical: true,
    ),
    (
      text: "split-tree-layout-cycle",
      id: CommandId.SplitTreeLayoutCycleList,
      canonical: true,
    ),
    (
      text: "split-tree-focus-next-sibling",
      id: CommandId.SplitTreeFocusNextSibling,
      canonical: true,
    ),
    (
      text: "split-tree-focus-prev-sibling",
      id: CommandId.SplitTreeFocusPrevSibling,
      canonical: true,
    ),
    (text: "bsp-balance", id: CommandId.BspBalance, canonical: true),
    (text: "bsp-equalize", id: CommandId.BspEqualize, canonical: true),
    (text: "bsp-preselect-left", id: CommandId.BspPreselectLeft, canonical: true),
    (text: "bsp-preselect-right", id: CommandId.BspPreselectRight, canonical: true),
    (text: "bsp-preselect-up", id: CommandId.BspPreselectUp, canonical: true),
    (text: "bsp-preselect-down", id: CommandId.BspPreselectDown, canonical: true),
    (text: "dwindle-split-left", id: CommandId.DwindleSplitLeft, canonical: true),
    (text: "dwindle-split-right", id: CommandId.DwindleSplitRight, canonical: true),
    (text: "dwindle-split-up", id: CommandId.DwindleSplitUp, canonical: true),
    (text: "dwindle-split-down", id: CommandId.DwindleSplitDown, canonical: true),
    (
      text: "dwindle-split-horizontal",
      id: CommandId.DwindleSplitHorizontal,
      canonical: true,
    ),
    (
      text: "dwindle-split-vertical",
      id: CommandId.DwindleSplitVertical,
      canonical: true,
    ),
    (text: "bsp-preselect-cancel", id: CommandId.BspPreselectCancel, canonical: true),
    (text: "bsp-preselect-ratio", id: CommandId.BspPreselectRatio, canonical: true),
    (text: "config-reload", id: CommandId.ConfigReload, canonical: true),
    (text: "layout-scroller", id: CommandId.LayoutScroller, canonical: true),
    (
      text: "layout-vertical-scroller",
      id: CommandId.LayoutVerticalScroller,
      canonical: true,
    ),
    (text: "layout-tile", id: CommandId.LayoutTile, canonical: true),
    (text: "layout-grid", id: CommandId.LayoutGrid, canonical: true),
    (text: "layout-monocle", id: CommandId.LayoutMonocle, canonical: true),
    (text: "layout-deck", id: CommandId.LayoutDeck, canonical: true),
    (text: "layout-center-tile", id: CommandId.LayoutCenterTile, canonical: true),
    (text: "layout-right-tile", id: CommandId.LayoutRightTile, canonical: true),
    (text: "layout-vertical-tile", id: CommandId.LayoutVerticalTile, canonical: true),
    (text: "layout-vertical-grid", id: CommandId.LayoutVerticalGrid, canonical: true),
    (text: "layout-vertical-deck", id: CommandId.LayoutVerticalDeck, canonical: true),
    (text: "layout-tgmix", id: CommandId.LayoutTGMix, canonical: true),
    (text: "layout-spiral", id: CommandId.LayoutSpiral, canonical: true),
    (text: "switch-layout", id: CommandId.SwitchLayout, canonical: true),
    (
      text: "switch-keyboard-layout",
      id: CommandId.SwitchKeyboardLayout,
      canonical: true,
    ),
    (text: "toggle-overview", id: CommandId.ToggleOverview, canonical: true),
    (text: "open-overview", id: CommandId.OpenOverview, canonical: true),
    (text: "close-overview", id: CommandId.CloseOverview, canonical: true),
    (text: "recent-window-next", id: CommandId.RecentWindowNext, canonical: true),
    (text: "recent-window-prev", id: CommandId.RecentWindowPrev, canonical: true),
    (text: "recent-window-confirm", id: CommandId.RecentWindowConfirm, canonical: true),
    (text: "recent-window-cancel", id: CommandId.RecentWindowCancel, canonical: true),
    (text: "recent-window-first", id: CommandId.RecentWindowFirst, canonical: true),
    (text: "recent-window-last", id: CommandId.RecentWindowLast, canonical: true),
    (text: "recent-window-scope", id: CommandId.RecentWindowScope, canonical: true),
    (
      text: "recent-window-cycle-scope",
      id: CommandId.RecentWindowCycleScope,
      canonical: true,
    ),
    (
      text: "recent-window-close-current",
      id: CommandId.RecentWindowCloseCurrent,
      canonical: true,
    ),
    (text: "toggle-floating", id: CommandId.ToggleFloating, canonical: true),
    (text: "fullscreen-window", id: CommandId.ToggleFullscreen, canonical: true),
    (text: "exit-fullscreen", id: CommandId.ExitFullscreen, canonical: true),
    (text: "maximize-window-to-edges", id: CommandId.ToggleMaximized, canonical: true),
    (text: "minimize", id: CommandId.Minimize, canonical: true),
    (text: "restore-minimized", id: CommandId.RestoreMinimized, canonical: true),
    (text: "screenshot", id: CommandId.Screenshot, canonical: true),
    (text: "screenshot-screen", id: CommandId.ScreenshotScreen, canonical: true),
    (text: "screenshot-window", id: CommandId.ScreenshotWindow, canonical: true),
    (text: "spawn", id: CommandId.Spawn, canonical: true),
    (text: "spawn-terminal", id: CommandId.SpawnTerminal, canonical: true),
    (text: "lock-session", id: CommandId.LockSession, canonical: true),
    (text: "power-off-monitors", id: CommandId.PowerOffMonitors, canonical: true),
    (text: "power-on-monitors", id: CommandId.PowerOnMonitors, canonical: true),
    (text: "power-off-monitor", id: CommandId.PowerOffMonitor, canonical: true),
    (text: "power-on-monitor", id: CommandId.PowerOnMonitor, canonical: true),
    (text: "warp-pointer", id: CommandId.WarpPointer, canonical: true),
    (text: "eat-next-key", id: CommandId.EatNextKey, canonical: true),
    (text: "cancel-eat-next-key", id: CommandId.CancelEatNextKey, canonical: true),
    (
      text: "toggle-keyboard-shortcuts-inhibit",
      id: CommandId.ToggleKeyboardShortcutsInhibit,
      canonical: true,
    ),
    (text: "stop-manager", id: CommandId.StopManager, canonical: true),
    (text: "triad-reload", id: CommandId.TriadReload, canonical: true),
    (text: "exit-session", id: CommandId.ExitSession, canonical: true),
    (text: "focus-shell-ui", id: CommandId.FocusShellUi, canonical: true),
    (text: "switch-shell", id: CommandId.SwitchShell, canonical: true),
    (text: "cycle-shell", id: CommandId.CycleShell, canonical: true),
    (text: "show-hotkey-overlay", id: CommandId.ShowHotkeyOverlay, canonical: true),
    (text: "hide-hotkey-overlay", id: CommandId.HideHotkeyOverlay, canonical: true),
    (text: "toggle-hotkey-overlay", id: CommandId.ToggleHotkeyOverlay, canonical: true),
    (text: "move-to-scratchpad", id: CommandId.MoveToScratchpad, canonical: true),
    (
      text: "move-to-named-scratchpad",
      id: CommandId.MoveToNamedScratchpad,
      canonical: true,
    ),
    (text: "toggle-scratchpad", id: CommandId.ToggleScratchpad, canonical: true),
    (
      text: "toggle-named-scratchpad",
      id: CommandId.ToggleNamedScratchpad,
      canonical: true,
    ),
    (text: "restore-scratchpad", id: CommandId.RestoreScratchpad, canonical: true),
    (text: "select-window", id: CommandId.SelectWindow, canonical: true),
    (text: "rename-tag", id: CommandId.RenameTag, canonical: true),
    (text: "group-windows", id: CommandId.GroupWindows, canonical: true),
    (text: "ungroup-window", id: CommandId.UngroupWindow, canonical: true),
    (text: "focus-next-in-group", id: CommandId.FocusNextInGroup, canonical: true),
    (text: "move-floating", id: CommandId.MoveFloating, canonical: true),
    (text: "resize-floating", id: CommandId.ResizeFloating, canonical: true),
    (text: "move-to-tag", id: CommandId.MoveToTag, canonical: true),
    (text: "move-to-workspace", id: CommandId.MoveToWorkspace, canonical: true),
    (text: "focus-output", id: CommandId.FocusOutput, canonical: true),
    (
      text: "move-workspace-to-output",
      id: CommandId.MoveWorkspaceToOutput,
      canonical: true,
    ),
    (text: "move-to-output", id: CommandId.MoveToOutput, canonical: true),
    (text: "focus-workspace", id: CommandId.FocusWorkspace, canonical: true),
    (text: "new-workspace", id: CommandId.NewWorkspace, canonical: true),
    (text: "focus-tag", id: CommandId.FocusTag, canonical: true),
    (text: "swap-to-tag", id: CommandId.SwapToTag, canonical: true),
    (text: "master-count", id: CommandId.MasterCount, canonical: true),
    (text: "adjust-master-count", id: CommandId.AdjustMasterCount, canonical: true),
    (text: "master-ratio", id: CommandId.MasterRatio, canonical: true),
    (text: "adjust-master-ratio", id: CommandId.AdjustMasterRatio, canonical: true),
    (text: "resize-width", id: CommandId.ResizeWidth, canonical: true),
    (text: "resize-height", id: CommandId.ResizeHeight, canonical: true),
    (text: "set-column-width", id: CommandId.SetColumnWidth, canonical: true),
    (
      text: "switch-proportion-preset",
      id: CommandId.SwitchProportionPreset,
      canonical: true,
    ),
    (text: "maximize-column", id: CommandId.MaximizeColumn, canonical: true),
    (text: "adjust-gaps", id: CommandId.AdjustGaps, canonical: true),
    (text: "toggle-gaps", id: CommandId.ToggleGaps, canonical: true),
    (text: "zoom", id: CommandId.Zoom, canonical: true),
    (text: "consume-window", id: CommandId.ConsumeWindow, canonical: true),
    (text: "expel-window", id: CommandId.ExpelWindow, canonical: true),
    (text: "move-column-left", id: CommandId.MoveColumnLeft, canonical: true),
    (text: "move-column-right", id: CommandId.MoveColumnRight, canonical: true),
    (text: "move-column-to-first", id: CommandId.MoveColumnToFirst, canonical: true),
    (text: "move-column-to-last", id: CommandId.MoveColumnToLast, canonical: true),
    (text: "move-window-left", id: CommandId.MoveWindowLeft, canonical: true),
    (text: "move-window-right", id: CommandId.MoveWindowRight, canonical: true),
    (text: "move-window-up", id: CommandId.MoveWindowUp, canonical: true),
    (text: "move-window-down", id: CommandId.MoveWindowDown, canonical: true),
    (
      text: "move-window-up-or-to-workspace-up",
      id: CommandId.MoveWindowUpOrToWorkspaceUp,
      canonical: true,
    ),
    (
      text: "move-window-down-or-to-workspace-down",
      id: CommandId.MoveWindowDownOrToWorkspaceDown,
      canonical: true,
    ),
    (text: "swap-window-up", id: CommandId.SwapWindowUp, canonical: true),
    (text: "swap-window-down", id: CommandId.SwapWindowDown, canonical: true),
    (text: "toggle-fullscreen", id: CommandId.ToggleFullscreen, canonical: false),
    (text: "toggle-maximized", id: CommandId.ToggleMaximized, canonical: false),
    (text: "toggle-maximize", id: CommandId.ToggleMaximized, canonical: false),
    (text: "minimize-window", id: CommandId.Minimize, canonical: false),
    (text: "minimized", id: CommandId.Minimize, canonical: false),
    (text: "restore_minimized", id: CommandId.RestoreMinimized, canonical: false),
    (
      text: "keyboard-shortcuts-inhibit",
      id: CommandId.ToggleKeyboardShortcutsInhibit,
      canonical: false,
    ),
  ]

  CommandMetas* = block:
    var rows: array[CommandId, CommandMeta]
    rows[CommandId.FocusNext] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusPrev] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusUp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusDown] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwitchFocusBetweenFloatingAndTiling] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusLast] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusTagLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusTagRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusOccupiedTagLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusOccupiedTagRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusColumnFirst] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusColumnLast] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusWindowOrWorkspaceUp] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusWindowOrWorkspaceDown] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveToTagLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveToTagRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.CloseWindow] = CommandMeta(argShape: OptionalWindowId, defined: true)
    rows[CommandId.FocusWindow] = CommandMeta(argShape: RequiredWindowId, defined: true)
    rows[CommandId.MoveWindowToTag] =
      CommandMeta(argShape: WindowTagFollow, defined: true)
    rows[CommandId.MoveWindowToWorkspace] =
      CommandMeta(argShape: WindowWorkspaceFollow, defined: true)
    rows[CommandId.SetWindowFloating] = CommandMeta(argShape: WindowBool, defined: true)
    rows[CommandId.SetWindowMaximized] =
      CommandMeta(argShape: WindowBool, defined: true)
    rows[CommandId.SetLayoutForWorkspace] =
      CommandMeta(argShape: TagLayout, defined: true)
    rows[CommandId.LayoutCustom] = CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.LayoutNative] = CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.FrameSplitHorizontal] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameSplitVertical] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameUnsplit] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameTabNext] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameTabPrev] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameResizeLeft] =
      CommandMeta(argShape: OptionalFloatDelta, defined: true)
    rows[CommandId.FrameResizeRight] =
      CommandMeta(argShape: OptionalFloatDelta, defined: true)
    rows[CommandId.FrameResizeUp] =
      CommandMeta(argShape: OptionalFloatDelta, defined: true)
    rows[CommandId.FrameResizeDown] =
      CommandMeta(argShape: OptionalFloatDelta, defined: true)
    rows[CommandId.FrameSplitToggle] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameFocusParent] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameFocusChild] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameBindApp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FrameUnbindApp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeSplitHorizontal] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeSplitVertical] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeSplitToggle] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutSplitHorizontal] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutSplitVertical] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutToggleSplit] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutStacking] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutTabbed] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeFocusParent] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeFocusChild] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutCycleAll] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutDefault] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeLayoutCycleList] =
      CommandMeta(argShape: SplitTreeModeList, defined: true)
    rows[CommandId.SplitTreeFocusNextSibling] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SplitTreeFocusPrevSibling] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspBalance] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspEqualize] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectUp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectDown] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitUp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitDown] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitHorizontal] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.DwindleSplitVertical] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectCancel] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.BspPreselectRatio] =
      CommandMeta(argShape: RequiredFloatValue, defined: true)
    rows[CommandId.ConfigReload] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutScroller] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutVerticalScroller] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutTile] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutGrid] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutMonocle] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutDeck] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutCenterTile] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutRightTile] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutVerticalTile] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutVerticalGrid] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutVerticalDeck] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutTGMix] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LayoutSpiral] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwitchLayout] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwitchKeyboardLayout] =
      CommandMeta(argShape: KeyboardLayoutTarget, defined: true)
    rows[CommandId.ToggleOverview] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.OpenOverview] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.CloseOverview] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowNext] =
      CommandMeta(argShape: RecentAdvance, defined: true)
    rows[CommandId.RecentWindowPrev] =
      CommandMeta(argShape: RecentAdvance, defined: true)
    rows[CommandId.RecentWindowConfirm] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowCancel] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowFirst] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowLast] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowScope] =
      CommandMeta(argShape: RecentScope, defined: true)
    rows[CommandId.RecentWindowCycleScope] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RecentWindowCloseCurrent] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ToggleFloating] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ToggleFullscreen] =
      CommandMeta(argShape: OptionalWindowId, defined: true)
    rows[CommandId.ExitFullscreen] =
      CommandMeta(argShape: RequiredWindowId, defined: true)
    rows[CommandId.ToggleMaximized] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.Minimize] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RestoreMinimized] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.Screenshot] = CommandMeta(argShape: Screenshot, defined: true)
    rows[CommandId.ScreenshotScreen] = CommandMeta(argShape: Screenshot, defined: true)
    rows[CommandId.ScreenshotWindow] = CommandMeta(argShape: Screenshot, defined: true)
    rows[CommandId.Spawn] = CommandMeta(argShape: SpawnArgv, defined: true)
    rows[CommandId.SpawnTerminal] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.LockSession] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.PowerOffMonitors] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.PowerOnMonitors] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.PowerOffMonitor] =
      CommandMeta(argShape: RequiredOutput, defined: true)
    rows[CommandId.PowerOnMonitor] =
      CommandMeta(argShape: RequiredOutput, defined: true)
    rows[CommandId.WarpPointer] = CommandMeta(argShape: WarpPointer, defined: true)
    rows[CommandId.EatNextKey] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.CancelEatNextKey] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ToggleKeyboardShortcutsInhibit] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.StopManager] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.TriadReload] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ExitSession] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusShellUi] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwitchShell] = CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.CycleShell] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ShowHotkeyOverlay] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.HideHotkeyOverlay] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ToggleHotkeyOverlay] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveToScratchpad] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveToNamedScratchpad] =
      CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.ToggleScratchpad] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ToggleNamedScratchpad] =
      CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.RestoreScratchpad] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SelectWindow] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.RenameTag] = CommandMeta(argShape: RequiredName, defined: true)
    rows[CommandId.GroupWindows] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.UngroupWindow] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusNextInGroup] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveFloating] = CommandMeta(argShape: MoveDelta, defined: true)
    rows[CommandId.ResizeFloating] = CommandMeta(argShape: ResizeDelta, defined: true)
    rows[CommandId.MoveToTag] = CommandMeta(argShape: RequiredTag, defined: true)
    rows[CommandId.MoveToWorkspace] =
      CommandMeta(argShape: RequiredWorkspaceIdx, defined: true)
    rows[CommandId.FocusOutput] = CommandMeta(argShape: RequiredOutput, defined: true)
    rows[CommandId.MoveWorkspaceToOutput] =
      CommandMeta(argShape: RequiredOutput, defined: true)
    rows[CommandId.MoveToOutput] = CommandMeta(argShape: RequiredOutput, defined: true)
    rows[CommandId.FocusWorkspace] =
      CommandMeta(argShape: RequiredWorkspaceIdx, defined: true)
    rows[CommandId.NewWorkspace] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.FocusTag] = CommandMeta(argShape: RequiredTag, defined: true)
    rows[CommandId.SwapToTag] = CommandMeta(argShape: RequiredTag, defined: true)
    rows[CommandId.MasterCount] = CommandMeta(argShape: RequiredIntCount, defined: true)
    rows[CommandId.AdjustMasterCount] =
      CommandMeta(argShape: RequiredIntDelta, defined: true)
    rows[CommandId.MasterRatio] =
      CommandMeta(argShape: RequiredFloatValue, defined: true)
    rows[CommandId.AdjustMasterRatio] =
      CommandMeta(argShape: RequiredFloatDelta, defined: true)
    rows[CommandId.ResizeWidth] =
      CommandMeta(argShape: RequiredFloatDelta, defined: true)
    rows[CommandId.ResizeHeight] =
      CommandMeta(argShape: RequiredFloatDelta, defined: true)
    rows[CommandId.SetColumnWidth] =
      CommandMeta(argShape: RequiredFloatValue, defined: true)
    rows[CommandId.SwitchProportionPreset] =
      CommandMeta(argShape: OptionalIntDelta, defined: true)
    rows[CommandId.MaximizeColumn] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.AdjustGaps] = CommandMeta(argShape: RequiredIntDelta, defined: true)
    rows[CommandId.ToggleGaps] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.Zoom] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ConsumeWindow] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.ExpelWindow] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveColumnLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveColumnRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveColumnToFirst] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveColumnToLast] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowLeft] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowRight] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowUp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowDown] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowUpOrToWorkspaceUp] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.MoveWindowDownOrToWorkspaceDown] =
      CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwapWindowUp] = CommandMeta(argShape: NoArgs, defined: true)
    rows[CommandId.SwapWindowDown] = CommandMeta(argShape: NoArgs, defined: true)
    for id in CommandId:
      doAssert rows[id].defined, "missing command metadata"
    rows

static:
  var spellings: seq[string] = @[]
  var canonicalIds: array[CommandId, bool]
  for row in CommandSpellings:
    doAssert row.text.len > 0, "empty command spelling"
    doAssert spellings.find(row.text) < 0, "duplicate command spelling: " & row.text
    spellings.add(row.text)
    if row.canonical:
      doAssert not canonicalIds[row.id], "duplicate canonical command row"
      canonicalIds[row.id] = true
  for id in CommandId:
    doAssert canonicalIds[id], "missing canonical command spelling"
