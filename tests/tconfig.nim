import std/[options, os, sequtils, strutils, unittest]
import ../src/config/[apply, defaults, parser, reload_policy]
import ../src/core/msg
import ../src/ipc/commands
import ../src/state/[engine, invariants, snapshot]
import ../src/systems/[overview_hot_corners, runtime_facade, workspaces]
import ../src/types/[model, runtime_values]

const
  Shift = 1'u32
  Ctrl = 4'u32
  Alt = 8'u32
  Super = 64'u32

proc commandForBinding(
    config: Config, key: string, modifiers: uint32, mode = BindingMode.BindAlways
): string =
  for binding in config.keyBindings:
    if binding.key == key and binding.modifiers == modifiers and binding.mode == mode:
      return binding.command
  ""

proc msgKindForBinding(
    config: Config, key: string, modifiers: uint32, mode = BindingMode.BindAlways
): MsgKind =
  let command = config.commandForBinding(key, modifiers, mode)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  parsed.get().kind

proc layoutForBinding(config: Config, key: string, modifiers: uint32): LayoutMode =
  let command = config.commandForBinding(key, modifiers)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  check parsed.get().kind == MsgKind.CmdSetLayout
  parsed.get().newLayout

proc spawnForBinding(config: Config, key: string, modifiers: uint32): seq[string] =
  let command = config.commandForBinding(key, modifiers)
  check command.len > 0
  let parsed = parseTextCommand(command)
  check parsed.isSome
  check parsed.get().kind == MsgKind.CmdSpawn
  parsed.get().spawnCommand

suite "KDL Configuration Parser":
  test "config application preserves live window state":
    let initial = initRuntimeStateFromConfig(
      Config(
        layout: LayoutConfig(
          gaps: 8,
          borderWidth: DefaultBorderWidth,
          focusedBorderColor: DefaultFocusedBorderColor,
          unfocusedBorderColor: DefaultUnfocusedBorderColor,
        ),
        workspaces: WorkspaceConfig(defaultCount: 3),
      )
    )
    var state = initial
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 7, appId: "brave", title: "Brave")
    )
    discard state.applyRuntimeUpdate(
      Msg(
        kind: MsgKind.WlWindowDimensions,
        dimensionsWindowId: 7,
        actualWidth: 1200,
        actualHeight: 800,
      )
    )

    let config = Config(
      layout: LayoutConfig(
        gaps: 24,
        centerFocusedColumn: "on-overflow",
        defaultColumnWidth: 0.66,
        defaultWindowWidth: 0.77,
        defaultWindowHeight: 0.88,
        defaultMasterCount: 2,
        defaultMasterRatio: 0.6,
        borderWidth: 4,
        focusedBorderColor: 0x112233ff'u32,
        unfocusedBorderColor: 0x445566ff'u32,
        scrollerFocusCenter: true,
        scrollerPreferCenter: true,
        enableAnimations: false,
        animationSpeed: 0.5,
        smartGaps: true,
        layoutCycle: @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.VerticalGrid],
      ),
      workspaces: WorkspaceConfig(defaultCount: 4, defaultLayout: LayoutMode.Scroller),
      tagRules:
        @[
          TagRule(tagId: 1, name: "term"),
          TagRule(
            tagId: 2,
            name: "web",
            defaultLayoutSet: true,
            defaultLayout: LayoutMode.Grid,
          ),
        ],
      windowRules: @[WindowRule(appIdMatch: "brave", keyboardShortcutsInhibit: true)],
      startupCommands: @[@["notify-send", "triad"]],
      quickshell: QuickshellConfig(enabled: true, theme: "noctalia"),
      terminal: TerminalConfig(command: @["kitty"]),
      screenshot: ScreenshotConfig(showPointer: true),
      overview: OverviewConfig(outerGap: -1, innerGapMultiplier: 1.5, zoom: 0.25),
      floating: FloatingConfig(
        xRatio: 0.2,
        yRatio: 0.3,
        widthRatio: 0.4,
        heightRatio: 0.5,
        minWidth: 80,
        minHeight: 90,
      ),
      screenLock: ScreenLockConfig(command: @["swaylock"]),
      windowMenu: WindowMenuConfig(command: @["bemenu"]),
      scratchpad: ScratchpadConfig(widthRatio: 0.7, heightRatio: 0.6),
      cursor: CursorConfig(theme: "Bibata", size: 32),
      presentationMode: PresentationMode.PresentationAsync,
      allowExitSession: true,
      protocolSurfaces: ProtocolSurfacesConfig(enabled: true),
      keyBindings:
        @[
          KeyBindingConfig(
            key: "r",
            modifiers: 12'u32,
            command: "triad-reload",
            bypassShortcutsInhibit: true,
          )
        ],
      pointerBindings:
        @[
          PointerBindingConfig(
            button: 0x110'u32,
            modifiers: 64'u32,
            op: PointerOpKind.OpMove,
            command: "move",
          )
        ],
    )

    check state.applyRuntimeConfig(config)
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 24
    check state.model.innerGaps == 12
    check state.model.borderWidth == 4
    check state.model.defaultWorkspaceCount == 4
    check state.model.layoutCycle ==
      @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.VerticalGrid]
    check state.model.terminal.command == @["kitty"]
    check state.model.overviewZoom == 0.25'f32
    check state.model.keyBindings.len == 1

    let snapshot = state.model.shellSnapshot()
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 7
    check snapshot.windows[0].appId == "brave"
    check snapshot.windows[0].actualW == 1200
    check snapshot.workspaces[0].name == "term"

  test "Default reload binding requests full Triad reload":
    let reloads = defaultKeyBindings().filterIt(it.command == "triad-reload")
    check reloads.len == 1
    check reloads[0].key == "r"
    check reloads[0].modifiers == 12'u32
    check reloads[0].bypassShortcutsInhibit
    check defaultKeyBindings().allIt(it.command != "reload-config")

  test "Strict config load rejects invalid KDL":
    let path = getCurrentDir() / "test_invalid_reload.kdl"
    writeFile(path, "layout { gaps ")
    let loaded = loadConfigStrict(path)
    removeFile(path)

    check not loaded.ok
    check loaded.error.len > 0

  test "Strict config load rejects invalid window rule regex":
    let path = getCurrentDir() / "test_invalid_window_rule_regex.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="["
  open-floating #true
}
""",
    )
    let loaded = loadConfigStrict(path)
    removeFile(path)

    check not loaded.ok
    check loaded.error.contains("window-rule[0].match[0] app-id")

  test "Text command parser accepts targeted window recovery commands":
    let focus = parseTextCommand("focus-window 42")
    check focus.isSome
    check focus.get().kind == MsgKind.CmdFocusWindowById
    check focus.get().focusWindowId == 42

    let close = parseTextCommand("close-window 43")
    check close.isSome
    check close.get().kind == MsgKind.CmdCloseWindowById
    check close.get().closeWindowId == 43

    let exitFullscreen = parseTextCommand("exit-fullscreen 44")
    check exitFullscreen.isSome
    check exitFullscreen.get().kind == MsgKind.CmdExitFullscreenById
    check exitFullscreen.get().fullscreenWindowId == 44

    let toggleFullscreen = parseTextCommand("toggle-fullscreen 45")
    check toggleFullscreen.isSome
    check toggleFullscreen.get().kind == MsgKind.CmdToggleFullscreenById
    check toggleFullscreen.get().fullscreenWindowId == 45

    let focusedToggle = parseTextCommand("toggle-fullscreen")
    check focusedToggle.isSome
    check focusedToggle.get().kind == MsgKind.CmdToggleFullscreen

    let fullscreenWindow = parseTextCommand("fullscreen-window")
    check fullscreenWindow.isSome
    check fullscreenWindow.get().kind == MsgKind.CmdToggleFullscreen

    let maximizeColumn = parseTextCommand("maximize-column")
    check maximizeColumn.isSome
    check maximizeColumn.get().kind == MsgKind.CmdMaximizeColumn

    let maximizeToEdges = parseTextCommand("maximize-window-to-edges")
    check maximizeToEdges.isSome
    check maximizeToEdges.get().kind == MsgKind.CmdToggleMaximized

    let screenshot = parseTextCommand(
      "screenshot-screen --path /tmp/a.png --hide-pointer --no-clipboard"
    )
    check screenshot.isSome
    check screenshot.get().kind == MsgKind.CmdScreenshot
    check screenshot.get().screenshotKind == ScreenshotKind.ShotScreen
    check screenshot.get().screenshotPath == "/tmp/a.png"
    check screenshot.get().screenshotPointerMode == ScreenshotPointerMode.PointerHide
    check screenshot.get().screenshotWriteToDisk
    check not screenshot.get().screenshotCopyToClipboard

    let clipboardOnly = parseTextCommand("screenshot --clipboard-only")
    check clipboardOnly.isSome
    check clipboardOnly.get().screenshotKind == ScreenshotKind.ShotRegion
    check not clipboardOnly.get().screenshotWriteToDisk
    check clipboardOnly.get().screenshotCopyToClipboard

    check parseTextCommand("screenshot --clipboard-only --no-clipboard").isNone
    check parseTextCommand("screenshot --path").isNone

  test "Config reload debouncer coalesces file watcher events":
    var debouncer: ConfigReloadDebouncer
    debouncer.schedule(1000, debounceMs = 200)
    debouncer.schedule(1050, debounceMs = 200)

    check not debouncer.takeDue(1249)
    check debouncer.takeDue(1250)
    check not debouncer.takeDue(1300)

  test "Parser reads layout, workspace, binding, and command settings":
    let path = getCurrentDir() / "test_config_dod.kdl"
    writeFile(
      path,
      """
layout {
  gaps 32
  center-focused-column "always"
  default-column-width { proportion 0.7 }
  default-window-width { proportion 0.8 }
  default-window-height { proportion 0.9 }
  master {
    count 2
    split-ratio 0.6
  }
  border {
    width 3
    active-color "#112233"
    inactive-color "#445566"
  }
  scroller-focus-center #true
  scroller-prefer-center #true
  enable-animations #false
  animation-speed 0.4
  smart-gaps #true
  layout-cycle "scroller" "deck" "vertical-grid"
}
workspaces {
  default-count 4
  default-layout "scroller"
}
workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web" default-layout="grid"
}
window-rule {
  match app-id="qemu"
  default-workspace 3
  open-on-output "HDMI-A-1"
  open-named-scratchpad "files"
  default-column-width { proportion 0.65 }
  default-window-width { proportion 0.75 }
  default-window-height { proportion 0.85 }
  min-width 640
  min-height 400
  max-width 1920
  max-height 1200
  open-floating #true
  open-focused #false
  open-fullscreen #false
  open-maximized #true
  open-maximized-to-edges #false
  respect-size-hints #false
  center-floating #true
  parented-role "tool"
  presentation-mode "async"
  border {
    width 5
    active-color "#abcdef"
    inactive-color "#12345680"
  }
  focus-ring {
    width 7
    active-color "#fedcba"
  }
  default-floating-position x=32 y=48 relative-to="bottom-left"
  dialog-viewport-jump #true
  floating {
    x-ratio 0.02
    y-ratio 0.08
    width 880
    height 640
  }
}
spawn-at-startup "notify-send" "triad"
quickshell {
  command "qs"
  theme "noctalia"
  args "--verbose"
}
terminal { command "kitty" }
screenshot {
  directory "~/shots"
  filename-prefix "triad-test"
  capture-command "grim -t png"
  region-selector-command "slurp -d"
  clipboard-command "wl-copy --type image/png"
  show-pointer #true
}
screen-lock { command "swaylock" }
window-menu-command "bemenu"
scratchpad {
  width-ratio 0.7
  height-ratio 0.6
}
overview {
  outer-gap 80
  inner-gap-multiplier 1.75
  zoom 0.25
  hot-corners {
    size 12
    top-left
    top-right #false
    bottom-right
  }
}
cursor {
  theme "Bibata"
  size 32
  shake-to-find
}
presentation-mode "async"
allow-exit-session #true
protocol-surfaces {
  enabled #true
  visible-debug #true
}
hotkey-overlay {
  skip-at-startup
  hide-not-bound
}
bindings {
  mirror-hjkl-arrows #true
  bind "Super+Return" "spawn-terminal"
  bind "SUPER+CTRL+c" "layout-center-tile" allow-inhibiting=#false
  bind "Super+/" "toggle-hotkey-overlay" hotkey-overlay-title="Show Important Hotkeys"
  bind "Super+Shift+?" "focus-last" hotkey-overlay-title=#null
  bind "NONE+F12" "focus-last"
  pointer-bind "Super+left" "move"
  pointer-bind "Super+middle" "toggle-maximized"
  pointer-bind "right" "close-window" mode="overview"
  pointer-bind "Super+btn_back" "focus-last"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.gaps == 32
    check config.mirrorHjklArrows
    check config.layout.borderWidth == 3
    check config.layout.centerFocusedColumn == "always"
    check config.layout.layoutCycle ==
      @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.VerticalGrid]
    check config.workspaces.defaultCount == 4
    check config.workspaces.defaultLayout == LayoutMode.Scroller
    check config.tagRules.len == 2
    check config.tagRules[0].tagId == 1
    check config.tagRules[0].name == "term"
    check not config.tagRules[0].defaultLayoutSet
    check config.tagRules[1].tagId == 2
    check config.tagRules[1].defaultLayoutSet
    check config.tagRules[1].defaultLayout == LayoutMode.Grid
    check config.windowRules.len == 1
    check config.windowRules[0].matches.len == 1
    check config.windowRules[0].matches[0].appIdSet
    check config.windowRules[0].matches[0].appId == "qemu"
    check not config.windowRules[0].matches[0].titleSet
    check config.windowRules[0].defaultWorkspace == 3
    check config.windowRules[0].openOnOutput == "HDMI-A-1"
    check config.windowRules[0].openNamedScratchpad == "files"
    check config.windowRules[0].defaultColumnWidthSet
    check config.windowRules[0].defaultColumnWidth == 0.65'f32
    check config.windowRules[0].defaultWindowWidthSet
    check config.windowRules[0].defaultWindowWidth == 0.75'f32
    check config.windowRules[0].defaultWindowHeightSet
    check config.windowRules[0].defaultWindowHeight == 0.85'f32
    check config.windowRules[0].minWidthSet
    check config.windowRules[0].minWidth == 640
    check config.windowRules[0].minHeightSet
    check config.windowRules[0].minHeight == 400
    check config.windowRules[0].maxWidthSet
    check config.windowRules[0].maxWidth == 1920
    check config.windowRules[0].maxHeightSet
    check config.windowRules[0].maxHeight == 1200
    check config.windowRules[0].openFloatingSet
    check config.windowRules[0].openFloating
    check config.windowRules[0].openFocusedSet
    check not config.windowRules[0].openFocused
    check config.windowRules[0].openFullscreenSet
    check not config.windowRules[0].openFullscreen
    check config.windowRules[0].openMaximizedSet
    check config.windowRules[0].openMaximized
    check config.windowRules[0].openMaximizedToEdgesSet
    check not config.windowRules[0].openMaximizedToEdges
    check config.windowRules[0].respectSizeHintsSet
    check not config.windowRules[0].respectSizeHints
    check config.windowRules[0].centerFloatingSet
    check config.windowRules[0].centerFloating
    check config.windowRules[0].parentedRoleSet
    check config.windowRules[0].parentedRole == ParentedRole.Tool
    check config.windowRules[0].presentationModeSet
    check config.windowRules[0].presentationMode == PresentationMode.PresentationAsync
    check config.windowRules[0].border.widthSet
    check config.windowRules[0].border.width == 5
    check config.windowRules[0].border.activeColorSet
    check config.windowRules[0].border.activeColor == 0xabcdefff'u32
    check config.windowRules[0].border.inactiveColorSet
    check config.windowRules[0].border.inactiveColor == 0x12345680'u32
    check config.windowRules[0].focusRing.widthSet
    check config.windowRules[0].focusRing.width == 7
    check config.windowRules[0].focusRing.activeColorSet
    check config.windowRules[0].focusRing.activeColor == 0xfedcbaff'u32
    check config.windowRules[0].defaultFloatingPosition.set
    check config.windowRules[0].defaultFloatingPosition.x == 32
    check config.windowRules[0].defaultFloatingPosition.y == 48
    check config.windowRules[0].defaultFloatingPosition.relativeTo ==
      FloatingPositionAnchor.BottomLeft
    check config.windowRules[0].dialogViewportJumpSet
    check config.windowRules[0].dialogViewportJump
    check config.windowRules[0].floating.xRatioSet
    check config.windowRules[0].floating.xRatio == 0.02'f32
    check config.windowRules[0].floating.yRatioSet
    check config.windowRules[0].floating.yRatio == 0.08'f32
    check config.windowRules[0].floating.widthSet
    check config.windowRules[0].floating.width == 880
    check config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.height == 640
    check config.startupCommands == @[@["notify-send", "triad"]]
    check config.quickshell.theme == "noctalia"
    check config.terminal.command.len > 0
    check config.screenshot.directory == "~/shots"
    check config.screenshot.filenamePrefix == "triad-test"
    check config.screenshot.captureCommand == "grim -t png"
    check config.screenshot.regionSelectorCommand == "slurp -d"
    check config.screenshot.clipboardCommand == "wl-copy --type image/png"
    check config.screenshot.showPointer
    check config.screenLock.command == @["swaylock"]
    check config.windowMenu.command == @["bemenu"]
    check config.scratchpad.widthRatio == 0.7'f32
    check config.overview.outerGap == 80
    check config.overview.innerGapMultiplier == 1.75'f32
    check config.overview.zoom == 0.25'f32
    check config.overview.hotCorners.size == 12
    check config.overview.hotCorners.topLeft
    check not config.overview.hotCorners.topRight
    check not config.overview.hotCorners.bottomLeft
    check config.overview.hotCorners.bottomRight
    check config.cursor.theme == "Bibata"
    check config.cursor.shakeToFind
    check config.presentationMode == PresentationMode.PresentationAsync
    check config.allowExitSession
    check config.protocolSurfaces.enabled
    check config.hotkeyOverlay.skipAtStartup
    check config.hotkeyOverlay.hideNotBound
    check config.keyBindings.len > 0
    check config.commandForBinding("c", Super + Ctrl) == "layout-center-tile"
    let uppercaseBindings =
      config.keyBindings.filterIt(it.key == "c" and it.modifiers == Super + Ctrl)
    check uppercaseBindings.len == 1
    check uppercaseBindings[0].bypassShortcutsInhibit
    check config.commandForBinding("Slash", Super) == "toggle-hotkey-overlay"
    let titledBindings =
      config.keyBindings.filterIt(it.key == "Slash" and it.modifiers == Super)
    check titledBindings.len == 1
    check titledBindings[0].hotkeyOverlayTitleKind ==
      HotkeyOverlayTitleKind.HotkeyTitleCustom
    check titledBindings[0].hotkeyOverlayTitle == "Show Important Hotkeys"
    let hiddenBindings = config.keyBindings.filterIt(
      it.key == "Question" and it.modifiers == Super + Shift
    )
    check hiddenBindings.len == 1
    check hiddenBindings[0].hotkeyOverlayTitleKind ==
      HotkeyOverlayTitleKind.HotkeyTitleHidden
    check config.commandForBinding("F12", 0'u32) == "focus-last"
    check config.pointerBindings.len == 4
    check config.pointerBindings.anyIt(
      it.button == 0x110'u32 and it.op == PointerOpKind.OpMove
    )
    check config.pointerBindings.anyIt(
      it.button == 0x112'u32 and it.command == "toggle-maximized"
    )
    check config.pointerBindings.anyIt(
      it.button == 0x111'u32 and it.command == "close-window" and
        it.mode == BindingMode.BindOverview
    )
    check config.pointerBindings.anyIt(
      it.button == 0x116'u32 and it.command == "focus-last"
    )

  test "HJKL mirroring preserves binding settings":
    let path = getCurrentDir() / "test_config_mirror.kdl"
    writeFile(
      path,
      """
bindings {
  mirror-hjkl-arrows #true
  bind "Super+h" "focus-left" allow-inhibiting=#false
  bind "Super+j" "focus-down" mode="overview"
  bind "Super+k" "focus-up" allow-inhibiting=#false
  bind "Super+Left" "custom-left"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.commandForBinding("Left", Super) == "custom-left"
    check config.commandForBinding("Down", Super, BindingMode.BindOverview) ==
      "focus-down"
    let mirroredDown = config.keyBindings.filterIt(
      it.key == "Down" and it.modifiers == Super and it.mode == BindingMode.BindOverview
    )
    check mirroredDown.len == 1
    let mirroredUp = config.keyBindings.filterIt(
      it.key == "Up" and it.modifiers == Super and it.command == "focus-up"
    )
    check mirroredUp.len == 1
    check mirroredUp[0].bypassShortcutsInhibit

  test "Config adds hotkey overlay fallback when key slot is free":
    let path = getCurrentDir() / "test_config_hotkey_fallback.kdl"
    writeFile(
      path,
      """
bindings {
  bind "Super+q" "close-window"
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.hotkeyOverlay.skipAtStartup
    check config.msgKindForBinding("Slash", Super + Shift) ==
      MsgKind.CmdToggleHotkeyOverlay

    writeFile(
      path,
      """
bindings {
  bind "Super+Shift+Slash" "focus-last"
}
""",
    )
    let occupied = loadConfig(path)
    removeFile(path)

    check occupied.msgKindForBinding("Slash", Super + Shift) == MsgKind.CmdFocusLast

  test "cursor shake-to-find defaults off and supports explicit false":
    let path = getCurrentDir() / "test_config_cursor_shake.kdl"
    writeFile(
      path,
      """
cursor {
  theme "default"
  size 24
}
""",
    )
    let defaultOff = loadConfig(path)
    removeFile(path)

    check not defaultOff.cursor.shakeToFind

    writeFile(
      path,
      """
cursor {
  theme "default"
  size 24
  shake-to-find #false
}
""",
    )
    let explicitFalse = loadConfig(path)
    removeFile(path)

    check not explicitFalse.cursor.shakeToFind

  test "Default bindings follow Niri-style movement and scratchpad chords":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")

    check config.msgKindForBinding("h", Super + Ctrl) == MsgKind.CmdMoveColumnLeft
    check config.msgKindForBinding("Left", Super + Ctrl) == MsgKind.CmdMoveColumnLeft
    check config.msgKindForBinding("j", Super + Ctrl) == MsgKind.CmdMoveWindowDown
    check config.msgKindForBinding("Down", Super + Ctrl) == MsgKind.CmdMoveWindowDown
    check config.msgKindForBinding("k", Super + Ctrl) == MsgKind.CmdMoveWindowUp
    check config.msgKindForBinding("l", Super + Ctrl) == MsgKind.CmdMoveColumnRight
    check config.msgKindForBinding("h", Super + Alt) == MsgKind.CmdMoveWindowLeft
    check config.msgKindForBinding("Right", Super + Alt) == MsgKind.CmdMoveWindowRight
    check config.msgKindForBinding("w", Super) == MsgKind.CmdToggleScratchpad
    check config.msgKindForBinding("w", Super + Shift) == MsgKind.CmdMoveToScratchpad
    check config.msgKindForBinding("r", Super + Shift) == MsgKind.CmdRestoreScratchpad
    check config.spawnForBinding("c", Super) ==
      @["wtype", "-M", "ctrl", "-P", "Insert", "-p", "Insert", "-m", "ctrl"]
    check config.spawnForBinding("v", Super) ==
      @["wtype", "-M", "shift", "-P", "Insert", "-p", "Insert", "-m", "shift"]
    check config.spawnForBinding("x", Super) ==
      @["wtype", "-M", "ctrl", "x", "-m", "ctrl"]
    check config.msgKindForBinding("Print", 0'u32) == MsgKind.CmdScreenshot
    check config.commandForBinding("Print", Ctrl) == "screenshot-screen"
    check config.commandForBinding("Print", Alt) == "screenshot-window"
    check config.commandForBinding("Print", Super) == "screenshot --clipboard-only"
    check config.msgKindForBinding("Slash", Super + Shift) ==
      MsgKind.CmdToggleHotkeyOverlay
    for key in ["c", "v", "x"]:
      let bindings =
        config.keyBindings.filterIt(it.key == key and it.modifiers == Super)
      check bindings.len == 1
      check bindings[0].bypassShortcutsInhibit
    check config.layoutForBinding("c", Super + Ctrl) == LayoutMode.CenterTile
    check config.layoutForBinding("v", Super + Ctrl) == LayoutMode.Deck
    check config.layoutForBinding("x", Super + Ctrl) == LayoutMode.Monocle
    check config.layoutForBinding("c", Super + Shift) == LayoutMode.RightTile
    check parseTextCommand("layout-tgmix").get().newLayout == LayoutMode.TGMix

  test "config defaults clamp invalid runtime values":
    var model = Model()
    model.applyConfig(
      Config(
        layout: LayoutConfig(
          gaps: -9,
          centerFocusedColumn: "sideways",
          defaultColumnWidth: 4.0,
          defaultWindowWidth: -1.0,
          defaultWindowHeight: 0.0,
          defaultMasterCount: 0,
          defaultMasterRatio: 2.0,
          animationSpeed: 5.0,
        ),
        workspaces: WorkspaceConfig(defaultCount: 0),
        overview: OverviewConfig(
          outerGap: -1,
          zoom: 99.0,
          hotCorners: OverviewHotCornersConfig(size: 5000, topLeft: true),
        ),
        scratchpad: ScratchpadConfig(widthRatio: 4.0, heightRatio: 0.0),
      )
    )

    check model.outerGaps == 0
    check model.centerFocusedColumn == "never"
    check model.defaultColumnWidth == 1.0'f32
    check model.defaultWindowWidth == 0.05'f32
    check model.defaultWindowHeight == 0.05'f32
    check model.defaultMasterCount == 1
    check model.defaultMasterRatio == 0.95'f32
    check model.animationSpeed == 1.0'f32
    check model.defaultWorkspaceCount == DefaultWorkspaceCount
    check model.defaultWorkspaceLayout == LayoutMode.Scroller
    check model.overviewOuterGap == DefaultOverviewOuterGap
    check model.overviewZoom == 0.75'f32
    check model.overviewHotCorners.size == 1000
    check model.scratchpadWidthRatio == 1.0'f32
    check model.scratchpadHeightRatio == 0.1'f32

  test "Window rule parser preserves explicit false policy fields":
    let path = getTempDir() / "triad-window-rule-explicit-false.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  parented-role "dialog"
  open-fullscreen #false
  open-maximized #false
  open-maximized-to-edges #false
  maximize-policy "ignore"
  respect-size-hints #false
  center-floating #false
  dialog-viewport-jump #false
  keyboard-shortcuts-inhibit #false
  presentation-mode "default"
  border { width 0 }
  focus-ring { width 0 }
  tiled-state #false
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].parentedRoleSet
    check config.windowRules[0].parentedRole == ParentedRole.Dialog
    check config.windowRules[0].openFullscreenSet
    check not config.windowRules[0].openFullscreen
    check config.windowRules[0].openMaximizedSet
    check not config.windowRules[0].openMaximized
    check config.windowRules[0].openMaximizedToEdgesSet
    check not config.windowRules[0].openMaximizedToEdges
    check config.windowRules[0].maximizePolicySet
    check config.windowRules[0].maximizePolicy == WindowRuleMaximizePolicy.Ignore
    check config.windowRules[0].respectSizeHintsSet
    check not config.windowRules[0].respectSizeHints
    check config.windowRules[0].centerFloatingSet
    check not config.windowRules[0].centerFloating
    check config.windowRules[0].dialogViewportJumpSet
    check not config.windowRules[0].dialogViewportJump
    check config.windowRules[0].keyboardShortcutsInhibitSet
    check not config.windowRules[0].keyboardShortcutsInhibit
    check config.windowRules[0].presentationModeSet
    check config.windowRules[0].presentationMode == PresentationMode.PresentationDefault
    check config.windowRules[0].border.widthSet
    check config.windowRules[0].border.width == 0
    check config.windowRules[0].focusRing.widthSet
    check config.windowRules[0].focusRing.width == 0
    check config.windowRules[0].tiledStateSet
    check not config.windowRules[0].tiledState

  test "Window rule parser clamps opening sizing proportions":
    let path = getTempDir() / "triad-window-rule-sizing.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  open-on-output "DP-1"
  default-column-width { proportion 2.0 }
  scroller-proportion { proportion 0.65 }
  scroller-single-proportion { proportion 0.0 }
  default-window-width { proportion 0.0 }
  default-window-height { proportion 0.4 }
  floating {
    width -12
    height 70000
  }
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].openOnOutput == "DP-1"
    check config.windowRules[0].defaultColumnWidthSet
    check config.windowRules[0].defaultColumnWidth == 1.0'f32
    check config.windowRules[0].scrollerProportionSet
    check config.windowRules[0].scrollerProportion == 0.65'f32
    check config.windowRules[0].scrollerSingleProportionSet
    check config.windowRules[0].scrollerSingleProportion == 0.05'f32
    check config.windowRules[0].defaultWindowWidthSet
    check config.windowRules[0].defaultWindowWidth == 0.05'f32
    check config.windowRules[0].defaultWindowHeightSet
    check config.windowRules[0].defaultWindowHeight == 0.4'f32
    check config.windowRules[0].floating.widthSet
    check config.windowRules[0].floating.width == 1
    check config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.height == 65535

  test "Window rule parser ignores empty named scratchpad targets":
    let path = getTempDir() / "triad-window-rule-empty-scratchpad.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  open-named-scratchpad ""
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].openNamedScratchpad.len == 0

  test "Window rule parser lets latest floating size field win per axis":
    let path = getTempDir() / "triad-window-rule-floating-size-order.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  floating {
    width-ratio 0.25
    width 900
    height 480
    height-ratio 0.5
  }
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].floating.widthSet
    check not config.windowRules[0].floating.widthRatioSet
    check config.windowRules[0].floating.width == 900
    check config.windowRules[0].floating.heightRatioSet
    check not config.windowRules[0].floating.heightSet
    check config.windowRules[0].floating.heightRatio == 0.5'f32

  test "Window rule parser clamps size bounds and preserves explicit zero":
    let path = getTempDir() / "triad-window-rule-bounds.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="demo"
  min-width -1
  min-height 400
  max-width 70000
  max-height 0
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].minWidthSet
    check config.windowRules[0].minWidth == 0
    check config.windowRules[0].minHeightSet
    check config.windowRules[0].minHeight == 400
    check config.windowRules[0].maxWidthSet
    check config.windowRules[0].maxWidth == 65535
    check config.windowRules[0].maxHeightSet
    check config.windowRules[0].maxHeight == 0

  test "Window rule parser reads multiple matches and excludes":
    let path = getTempDir() / "triad-window-rule-matchers.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="^org\\.gimp\\." title="Welcome" is-focused=#true is-active=#false at-startup=#true
  match app-id="^gimp-tool$" is-floating=#true is-active-in-column=#false
  exclude title="Private" is-floating=#false at-startup=#false
  default-workspace 4
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 1
    check config.windowRules[0].matches.len == 2
    check config.windowRules[0].matches[0].appIdSet
    check config.windowRules[0].matches[0].appId == "^org\\.gimp\\."
    check config.windowRules[0].matches[0].titleSet
    check config.windowRules[0].matches[0].title == "Welcome"
    check config.windowRules[0].matches[0].isFocusedSet
    check config.windowRules[0].matches[0].isFocused
    check config.windowRules[0].matches[0].isActiveSet
    check not config.windowRules[0].matches[0].isActive
    check config.windowRules[0].matches[0].atStartupSet
    check config.windowRules[0].matches[0].atStartup
    check config.windowRules[0].matches[1].appIdSet
    check config.windowRules[0].matches[1].appId == "^gimp-tool$"
    check config.windowRules[0].matches[1].isFloatingSet
    check config.windowRules[0].matches[1].isFloating
    check config.windowRules[0].matches[1].isActiveInColumnSet
    check not config.windowRules[0].matches[1].isActiveInColumn
    check config.windowRules[0].excludes.len == 1
    check config.windowRules[0].excludes[0].titleSet
    check config.windowRules[0].excludes[0].title == "Private"
    check config.windowRules[0].excludes[0].isFloatingSet
    check not config.windowRules[0].excludes[0].isFloating
    check config.windowRules[0].excludes[0].atStartupSet
    check not config.windowRules[0].excludes[0].atStartup

  test "Window rule parser reads multi-workspace targets":
    let path = getTempDir() / "triad-window-rule-workspaces.kdl"
    writeFile(
      path,
      """
window-rule {
  match app-id="multi"
  default-workspaces 2 4 2 0
}

window-rule {
  match app-id="plural-wins"
  default-workspace 2
  default-workspaces 5 3 5
}

window-rule {
  match app-id="singular-wins"
  default-workspaces 2 3
  default-workspace 4
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.windowRules.len == 3
    check config.windowRules[0].defaultWorkspace == 2
    check config.windowRules[0].defaultWorkspaces == @[2'u32, 4'u32]
    check config.windowRules[1].defaultWorkspace == 5
    check config.windowRules[1].defaultWorkspaces == @[5'u32, 3'u32]
    check config.windowRules[2].defaultWorkspace == 4
    check config.windowRules[2].defaultWorkspaces == @[4'u32]

  test "workspace config uses global default layout and explicit overrides":
    var model = initRuntimeStateFromConfig(
      Config(
        workspaces: WorkspaceConfig(defaultCount: 2, defaultLayout: LayoutMode.Deck),
        tagRules:
          @[
            TagRule(
              tagId: 1,
              name: "term",
              defaultLayoutSet: true,
              defaultLayout: LayoutMode.Grid,
            ),
            TagRule(tagId: 3, name: "dynamic"),
          ],
      )
    ).model

    var snapshot = model.shellSnapshot()
    check snapshot.workspaces[0].name == "term"
    check snapshot.workspaces[0].layoutMode == LayoutMode.Grid
    check snapshot.workspaces[1].layoutMode == LayoutMode.Deck

    let dynamicTag = model.ensureWorkspaceSlot(3)
    check dynamicTag != NullTagId
    let dynamic = model.tagData(dynamicTag)
    check dynamic.isSome
    check dynamic.get().name == "dynamic"
    check dynamic.get().layoutMode == LayoutMode.Deck

  test "legacy tag config names are not accepted":
    let path = getTempDir() / "triad-legacy-tag-config.kdl"
    writeFile(
      path,
      """
workspaces { default-count 3 }
tag-rules {
  tag 2 name="web" default-layout="grid"
}
window-rule {
  match app-id="qemu"
  default-tag 3
}
""",
    )
    let config = loadConfig(path)
    removeFile(path)

    check config.tagRules.len == 0
    check config.windowRules.len == 1
    check config.windowRules[0].defaultWorkspace == 0

  test "overview hot corner geometry follows output bounds":
    var model = initRuntimeStateFromConfig(
      Config(
        overview: OverviewConfig(
          hotCorners:
            OverviewHotCornersConfig(size: 10, topLeft: true, bottomRight: true)
        )
      )
    ).model
    discard model.addOutput(ExternalOutputId(1), x = 0, y = 0, w = 100, h = 100)
    discard model.addOutput(ExternalOutputId(2), x = 100, y = 0, w = 100, h = 100)

    check model.overviewHotCornerAt(0, 0)
    check model.overviewHotCornerAt(199, 99)
    check not model.overviewHotCornerAt(99, 0)
    check not model.overviewHotCornerAt(50, 50)
