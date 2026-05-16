type
  CommandId* {.pure.} = enum
    CidFocusNext
    CidFocusPrev
    CidFocusLeft
    CidFocusRight
    CidFocusUp
    CidFocusDown
    CidFocusLast
    CidFocusTagLeft
    CidFocusTagRight
    CidFocusOccupiedTagLeft
    CidFocusOccupiedTagRight
    CidFocusColumnFirst
    CidFocusColumnLast
    CidFocusWindowOrWorkspaceUp
    CidFocusWindowOrWorkspaceDown
    CidMoveToTagLeft
    CidMoveToTagRight
    CidCloseWindow
    CidFocusWindow
    CidMoveWindowToTag
    CidMoveWindowToWorkspace
    CidSetWindowFloating
    CidSetWindowMaximized
    CidSetLayoutForWorkspace
    CidConfigReload
    CidLayoutScroller
    CidLayoutVerticalScroller
    CidLayoutTile
    CidLayoutGrid
    CidLayoutMonocle
    CidLayoutDeck
    CidLayoutCenterTile
    CidLayoutRightTile
    CidLayoutVerticalTile
    CidLayoutVerticalGrid
    CidLayoutVerticalDeck
    CidLayoutTGMix
    CidSwitchLayout
    CidToggleOverview
    CidOpenOverview
    CidCloseOverview
    CidRecentWindowNext
    CidRecentWindowPrev
    CidRecentWindowConfirm
    CidRecentWindowCancel
    CidRecentWindowFirst
    CidRecentWindowLast
    CidRecentWindowScope
    CidRecentWindowCycleScope
    CidRecentWindowCloseCurrent
    CidToggleFloating
    CidToggleFullscreen
    CidExitFullscreen
    CidToggleMaximized
    CidMinimize
    CidScreenshot
    CidScreenshotScreen
    CidScreenshotWindow
    CidSpawn
    CidSpawnTerminal
    CidLockSession
    CidWarpPointer
    CidEatNextKey
    CidCancelEatNextKey
    CidToggleKeyboardShortcutsInhibit
    CidStopManager
    CidTriadReload
    CidExitSession
    CidFocusShellUi
    CidSwitchShell
    CidCycleShell
    CidShowHotkeyOverlay
    CidHideHotkeyOverlay
    CidToggleHotkeyOverlay
    CidMoveToScratchpad
    CidMoveToNamedScratchpad
    CidToggleScratchpad
    CidToggleNamedScratchpad
    CidRestoreScratchpad
    CidSelectWindow
    CidRenameTag
    CidGroupWindows
    CidUngroupWindow
    CidFocusNextInGroup
    CidMoveFloating
    CidResizeFloating
    CidMoveToTag
    CidMoveToWorkspace
    CidFocusOutput
    CidMoveWorkspaceToOutput
    CidMoveToOutput
    CidFocusWorkspace
    CidFocusTag
    CidSwapToTag
    CidMasterCount
    CidAdjustMasterCount
    CidMasterRatio
    CidAdjustMasterRatio
    CidResizeWidth
    CidResizeHeight
    CidSetColumnWidth
    CidSwitchProportionPreset
    CidMaximizeColumn
    CidAdjustGaps
    CidToggleGaps
    CidZoom
    CidConsumeWindow
    CidExpelWindow
    CidMoveColumnLeft
    CidMoveColumnRight
    CidMoveColumnToFirst
    CidMoveColumnToLast
    CidMoveWindowLeft
    CidMoveWindowRight
    CidMoveWindowUp
    CidMoveWindowDown
    CidMoveWindowUpOrToWorkspaceUp
    CidMoveWindowDownOrToWorkspaceDown
    CidSwapWindowUp
    CidSwapWindowDown

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

  CommandSpec* = object
    id*: CommandId
    name*: string
    aliases*: string
    argShape*: CommandArgShape

const CommandSpecs* = [
  CommandSpec(id: CommandId.CidFocusNext, name: "focus-next", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusPrev, name: "focus-prev", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusLeft, name: "focus-left", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusRight, name: "focus-right", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusUp, name: "focus-up", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusDown, name: "focus-down", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusLast, name: "focus-last", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusTagLeft, name: "focus-tag-left", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusTagRight, name: "focus-tag-right", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidFocusOccupiedTagLeft,
    name: "focus-occupied-tag-left",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidFocusOccupiedTagRight,
    name: "focus-occupied-tag-right",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidFocusColumnFirst, name: "focus-column-first", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidFocusColumnLast, name: "focus-column-last", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidFocusWindowOrWorkspaceUp,
    name: "focus-window-or-workspace-up",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidFocusWindowOrWorkspaceDown,
    name: "focus-window-or-workspace-down",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidMoveToTagLeft, name: "move-to-tag-left", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveToTagRight, name: "move-to-tag-right", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidCloseWindow, name: "close-window", argShape: OptionalWindowId
  ),
  CommandSpec(
    id: CommandId.CidFocusWindow, name: "focus-window", argShape: RequiredWindowId
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowToTag,
    name: "move-window-to-tag",
    argShape: WindowTagFollow,
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowToWorkspace,
    name: "move-window-to-workspace",
    argShape: WindowWorkspaceFollow,
  ),
  CommandSpec(
    id: CommandId.CidSetWindowFloating,
    name: "set-window-floating",
    argShape: WindowBool,
  ),
  CommandSpec(
    id: CommandId.CidSetWindowMaximized,
    name: "set-window-maximized",
    argShape: WindowBool,
  ),
  CommandSpec(
    id: CommandId.CidSetLayoutForWorkspace,
    name: "set-layout-for-workspace",
    argShape: TagLayout,
  ),
  CommandSpec(id: CommandId.CidConfigReload, name: "config-reload", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidLayoutScroller, name: "layout-scroller", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidLayoutVerticalScroller,
    name: "layout-vertical-scroller",
    argShape: NoArgs,
  ),
  CommandSpec(id: CommandId.CidLayoutTile, name: "layout-tile", argShape: NoArgs),
  CommandSpec(id: CommandId.CidLayoutGrid, name: "layout-grid", argShape: NoArgs),
  CommandSpec(id: CommandId.CidLayoutMonocle, name: "layout-monocle", argShape: NoArgs),
  CommandSpec(id: CommandId.CidLayoutDeck, name: "layout-deck", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidLayoutCenterTile, name: "layout-center-tile", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidLayoutRightTile, name: "layout-right-tile", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidLayoutVerticalTile, name: "layout-vertical-tile", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidLayoutVerticalGrid, name: "layout-vertical-grid", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidLayoutVerticalDeck, name: "layout-vertical-deck", argShape: NoArgs
  ),
  CommandSpec(id: CommandId.CidLayoutTGMix, name: "layout-tgmix", argShape: NoArgs),
  CommandSpec(id: CommandId.CidSwitchLayout, name: "switch-layout", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidToggleOverview, name: "toggle-overview", argShape: NoArgs
  ),
  CommandSpec(id: CommandId.CidOpenOverview, name: "open-overview", argShape: NoArgs),
  CommandSpec(id: CommandId.CidCloseOverview, name: "close-overview", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidRecentWindowNext,
    name: "recent-window-next",
    argShape: RecentAdvance,
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowPrev,
    name: "recent-window-prev",
    argShape: RecentAdvance,
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowConfirm,
    name: "recent-window-confirm",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowCancel, name: "recent-window-cancel", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowFirst, name: "recent-window-first", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowLast, name: "recent-window-last", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowScope,
    name: "recent-window-scope",
    argShape: RecentScope,
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowCycleScope,
    name: "recent-window-cycle-scope",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidRecentWindowCloseCurrent,
    name: "recent-window-close-current",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidToggleFloating, name: "toggle-floating", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidToggleFullscreen,
    name: "fullscreen-window",
    aliases: "toggle-fullscreen",
    argShape: OptionalWindowId,
  ),
  CommandSpec(
    id: CommandId.CidExitFullscreen, name: "exit-fullscreen", argShape: RequiredWindowId
  ),
  CommandSpec(
    id: CommandId.CidToggleMaximized,
    name: "maximize-window-to-edges",
    aliases: "toggle-maximized|toggle-maximize",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidMinimize,
    name: "minimize",
    aliases: "minimize-window",
    argShape: NoArgs,
  ),
  CommandSpec(id: CommandId.CidScreenshot, name: "screenshot", argShape: Screenshot),
  CommandSpec(
    id: CommandId.CidScreenshotScreen, name: "screenshot-screen", argShape: Screenshot
  ),
  CommandSpec(
    id: CommandId.CidScreenshotWindow, name: "screenshot-window", argShape: Screenshot
  ),
  CommandSpec(id: CommandId.CidSpawn, name: "spawn", argShape: SpawnArgv),
  CommandSpec(id: CommandId.CidSpawnTerminal, name: "spawn-terminal", argShape: NoArgs),
  CommandSpec(id: CommandId.CidLockSession, name: "lock-session", argShape: NoArgs),
  CommandSpec(id: CommandId.CidWarpPointer, name: "warp-pointer", argShape: WarpPointer),
  CommandSpec(id: CommandId.CidEatNextKey, name: "eat-next-key", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidCancelEatNextKey, name: "cancel-eat-next-key", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidToggleKeyboardShortcutsInhibit,
    name: "toggle-keyboard-shortcuts-inhibit",
    aliases: "keyboard-shortcuts-inhibit",
    argShape: NoArgs,
  ),
  CommandSpec(id: CommandId.CidStopManager, name: "stop-manager", argShape: NoArgs),
  CommandSpec(id: CommandId.CidTriadReload, name: "triad-reload", argShape: NoArgs),
  CommandSpec(id: CommandId.CidExitSession, name: "exit-session", argShape: NoArgs),
  CommandSpec(id: CommandId.CidFocusShellUi, name: "focus-shell-ui", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidSwitchShell, name: "switch-shell", argShape: RequiredName
  ),
  CommandSpec(id: CommandId.CidCycleShell, name: "cycle-shell", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidShowHotkeyOverlay, name: "show-hotkey-overlay", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidHideHotkeyOverlay, name: "hide-hotkey-overlay", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidToggleHotkeyOverlay,
    name: "toggle-hotkey-overlay",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidMoveToScratchpad, name: "move-to-scratchpad", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveToNamedScratchpad,
    name: "move-to-named-scratchpad",
    argShape: RequiredName,
  ),
  CommandSpec(
    id: CommandId.CidToggleScratchpad, name: "toggle-scratchpad", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidToggleNamedScratchpad,
    name: "toggle-named-scratchpad",
    argShape: RequiredName,
  ),
  CommandSpec(
    id: CommandId.CidRestoreScratchpad, name: "restore-scratchpad", argShape: NoArgs
  ),
  CommandSpec(id: CommandId.CidSelectWindow, name: "select-window", argShape: NoArgs),
  CommandSpec(id: CommandId.CidRenameTag, name: "rename-tag", argShape: RequiredName),
  CommandSpec(id: CommandId.CidGroupWindows, name: "group-windows", argShape: NoArgs),
  CommandSpec(id: CommandId.CidUngroupWindow, name: "ungroup-window", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidFocusNextInGroup, name: "focus-next-in-group", argShape: NoArgs
  ),
  CommandSpec(id: CommandId.CidMoveFloating, name: "move-floating", argShape: MoveDelta),
  CommandSpec(
    id: CommandId.CidResizeFloating, name: "resize-floating", argShape: ResizeDelta
  ),
  CommandSpec(id: CommandId.CidMoveToTag, name: "move-to-tag", argShape: RequiredTag),
  CommandSpec(
    id: CommandId.CidMoveToWorkspace,
    name: "move-to-workspace",
    argShape: RequiredWorkspaceIdx,
  ),
  CommandSpec(
    id: CommandId.CidFocusOutput, name: "focus-output", argShape: RequiredOutput
  ),
  CommandSpec(
    id: CommandId.CidMoveWorkspaceToOutput,
    name: "move-workspace-to-output",
    argShape: RequiredOutput,
  ),
  CommandSpec(
    id: CommandId.CidMoveToOutput, name: "move-to-output", argShape: RequiredOutput
  ),
  CommandSpec(
    id: CommandId.CidFocusWorkspace,
    name: "focus-workspace",
    argShape: RequiredWorkspaceIdx,
  ),
  CommandSpec(id: CommandId.CidFocusTag, name: "focus-tag", argShape: RequiredTag),
  CommandSpec(id: CommandId.CidSwapToTag, name: "swap-to-tag", argShape: RequiredTag),
  CommandSpec(
    id: CommandId.CidMasterCount, name: "master-count", argShape: RequiredIntCount
  ),
  CommandSpec(
    id: CommandId.CidAdjustMasterCount,
    name: "adjust-master-count",
    argShape: RequiredIntDelta,
  ),
  CommandSpec(
    id: CommandId.CidMasterRatio, name: "master-ratio", argShape: RequiredFloatValue
  ),
  CommandSpec(
    id: CommandId.CidAdjustMasterRatio,
    name: "adjust-master-ratio",
    argShape: RequiredFloatDelta,
  ),
  CommandSpec(
    id: CommandId.CidResizeWidth, name: "resize-width", argShape: RequiredFloatDelta
  ),
  CommandSpec(
    id: CommandId.CidResizeHeight, name: "resize-height", argShape: RequiredFloatDelta
  ),
  CommandSpec(
    id: CommandId.CidSetColumnWidth,
    name: "set-column-width",
    argShape: RequiredFloatValue,
  ),
  CommandSpec(
    id: CommandId.CidSwitchProportionPreset,
    name: "switch-proportion-preset",
    argShape: OptionalIntDelta,
  ),
  CommandSpec(
    id: CommandId.CidMaximizeColumn, name: "maximize-column", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidAdjustGaps, name: "adjust-gaps", argShape: RequiredIntDelta
  ),
  CommandSpec(id: CommandId.CidToggleGaps, name: "toggle-gaps", argShape: NoArgs),
  CommandSpec(id: CommandId.CidZoom, name: "zoom", argShape: NoArgs),
  CommandSpec(id: CommandId.CidConsumeWindow, name: "consume-window", argShape: NoArgs),
  CommandSpec(id: CommandId.CidExpelWindow, name: "expel-window", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidMoveColumnLeft, name: "move-column-left", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveColumnRight, name: "move-column-right", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveColumnToFirst, name: "move-column-to-first", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveColumnToLast, name: "move-column-to-last", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowLeft, name: "move-window-left", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowRight, name: "move-window-right", argShape: NoArgs
  ),
  CommandSpec(id: CommandId.CidMoveWindowUp, name: "move-window-up", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidMoveWindowDown, name: "move-window-down", argShape: NoArgs
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowUpOrToWorkspaceUp,
    name: "move-window-up-or-to-workspace-up",
    argShape: NoArgs,
  ),
  CommandSpec(
    id: CommandId.CidMoveWindowDownOrToWorkspaceDown,
    name: "move-window-down-or-to-workspace-down",
    argShape: NoArgs,
  ),
  CommandSpec(id: CommandId.CidSwapWindowUp, name: "swap-window-up", argShape: NoArgs),
  CommandSpec(
    id: CommandId.CidSwapWindowDown, name: "swap-window-down", argShape: NoArgs
  ),
]
