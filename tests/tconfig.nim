import std/[options, os, sequtils, unittest]
import ../src/config/[apply, defaults, parser, reload_policy]
import ../src/core/msg
import ../src/ipc/commands
import ../src/state/[invariants, snapshot]
import ../src/systems/runtime_facade
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
      workspaces: WorkspaceConfig(defaultCount: 4),
      tagRules:
        @[
          TagRule(tagId: 1, name: "term", defaultLayout: LayoutMode.Scroller),
          TagRule(tagId: 2, name: "web", defaultLayout: LayoutMode.Grid),
        ],
      windowRules: @[WindowRule(appIdMatch: "brave", keyboardShortcutsInhibit: true)],
      startupCommands: @[@["notify-send", "triad"]],
      quickshell: QuickshellConfig(enabled: true, theme: "noctalia"),
      terminal: TerminalConfig(command: @["kitty"]),
      screenshot: ScreenshotConfig(showPointer: true),
      overview: OverviewConfig(outerGap: -1, innerGapMultiplier: 1.5),
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
workspaces { default-count 4 }
tag-rules {
  tag 2 name="web" default-layout="grid"
}
window-rule {
  match app-id="qemu"
  default-tag 3
  open-floating #true
  open-focused #false
  parented-role "tool"
  dialog-viewport-jump #true
  floating {
    x-ratio 0.02
    y-ratio 0.08
    width-ratio 0.22
    height-ratio 0.84
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
cursor {
  theme "Bibata"
  size 32
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
    check config.tagRules.len == 1
    check config.tagRules[0].tagId == 2
    check config.tagRules[0].defaultLayout == LayoutMode.Grid
    check config.windowRules.len == 1
    check config.windowRules[0].defaultTag == 3
    check config.windowRules[0].openFloatingSet
    check config.windowRules[0].openFloating
    check config.windowRules[0].openFocusedSet
    check not config.windowRules[0].openFocused
    check config.windowRules[0].parentedRole == ParentedRole.Tool
    check config.windowRules[0].dialogViewportJump
    check config.windowRules[0].floating.xRatioSet
    check config.windowRules[0].floating.xRatio == 0.02'f32
    check config.windowRules[0].floating.yRatioSet
    check config.windowRules[0].floating.yRatio == 0.08'f32
    check config.windowRules[0].floating.widthRatioSet
    check config.windowRules[0].floating.widthRatio == 0.22'f32
    check config.windowRules[0].floating.heightRatioSet
    check config.windowRules[0].floating.heightRatio == 0.84'f32
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
    check config.cursor.theme == "Bibata"
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
        overview: OverviewConfig(outerGap: -1),
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
    check model.overviewOuterGap == DefaultOverviewOuterGap
    check model.scratchpadWidthRatio == 1.0'f32
    check model.scratchpadHeightRatio == 0.1'f32
