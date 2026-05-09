import os, sequtils, unittest
import ../src/config/defaults
import ../src/config/dod_apply
import ../src/config/parser
import ../src/config/reload_policy
import ../src/core/msg
import ../src/state/dod_invariants
import ../src/state/dod_snapshot
import ../src/systems/dod_runtime_state
import ../src/types/dod_model
import ../src/types/runtime_values

suite "KDL Configuration Parser":
  test "DOD config application preserves live window state":
    let initial = initRuntimeStateFromConfig(Config(
      layout: LayoutConfig(
        gaps: 8,
        borderWidth: DefaultBorderWidth,
        focusedBorderColor: DefaultFocusedBorderColor,
        unfocusedBorderColor: DefaultUnfocusedBorderColor),
      workspaces: WorkspaceConfig(defaultCount: 3)))
    var state = initial.state
    discard state.applyObservedRuntimeUpdate(Msg(
      kind: WlWindowCreated,
      windowId: 7,
      appId: "brave",
      title: "Brave"))
    discard state.applyObservedRuntimeUpdate(Msg(
      kind: WlWindowDimensions,
      dimensionsWindowId: 7,
      actualWidth: 1200,
      actualHeight: 800))

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
        layoutCycle: @[Scroller, Deck, VerticalGrid]),
      workspaces: WorkspaceConfig(defaultCount: 4),
      tagRules: @[
        TagRule(tagId: 1, name: "term", defaultLayout: Scroller),
        TagRule(tagId: 2, name: "web", defaultLayout: Grid)
      ],
      windowRules: @[
        WindowRule(appIdMatch: "brave", keyboardShortcutsInhibit: true)
      ],
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
        minHeight: 90),
      screenLock: ScreenLockConfig(command: @["swaylock"]),
      windowMenu: WindowMenuConfig(command: @["bemenu"]),
      scratchpad: ScratchpadConfig(widthRatio: 0.7, heightRatio: 0.6),
      cursor: CursorConfig(theme: "Bibata", size: 32),
      presentationMode: PresentationAsync,
      allowExitSession: true,
      protocolSurfaces: ProtocolSurfacesConfig(enabled: true),
      keyBindings: @[
        KeyBindingConfig(
          key: "r",
          modifiers: 12'u32,
          command: "triad-reload",
          bypassShortcutsInhibit: true)
      ],
      pointerBindings: @[
        PointerBindingConfig(button: 0x110'u32, modifiers: 64'u32, op: OpMove)
      ])

    check state.applyObservedRuntimeConfig(config).ok
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 24
    check state.model.innerGaps == 12
    check state.model.borderWidth == 4
    check state.model.defaultWorkspaceCount == 4
    check state.model.layoutCycle == @[Scroller, Deck, VerticalGrid]
    check state.model.terminal.command == @["kitty"]
    check state.model.keyBindings.len == 1

    let snapshot = state.model.dodShellSnapshot()
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

  test "Config reload debouncer coalesces file watcher events":
    var debouncer: ConfigReloadDebouncer
    debouncer.schedule(1000, debounceMs = 200)
    debouncer.schedule(1050, debounceMs = 200)

    check not debouncer.takeDue(1249)
    check debouncer.takeDue(1250)
    check not debouncer.takeDue(1300)

  test "Parser reads layout, workspace, binding, and command settings":
    let path = getCurrentDir() / "test_config_dod.kdl"
    writeFile(path, """
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
}
spawn-at-startup "notify-send" "triad"
quickshell {
  command "qs"
  theme "noctalia"
  args "--verbose"
}
terminal { command "kitty" }
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
bindings {
  bind "Super+Return" "spawn-terminal"
  pointer-bind "Super+left" "move"
}
""")
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.gaps == 32
    check config.layout.borderWidth == 3
    check config.layout.centerFocusedColumn == "always"
    check config.layout.layoutCycle == @[Scroller, Deck, VerticalGrid]
    check config.workspaces.defaultCount == 4
    check config.tagRules.len == 1
    check config.tagRules[0].tagId == 2
    check config.tagRules[0].defaultLayout == Grid
    check config.windowRules.len == 1
    check config.windowRules[0].defaultTag == 3
    check config.windowRules[0].openFloating
    check config.startupCommands == @[@["notify-send", "triad"]]
    check config.quickshell.theme == "noctalia"
    check config.terminal.command.len > 0
    check config.screenLock.command == @["swaylock"]
    check config.windowMenu.command == @["bemenu"]
    check config.scratchpad.widthRatio == 0.7'f32
    check config.cursor.theme == "Bibata"
    check config.presentationMode == PresentationAsync
    check config.allowExitSession
    check config.protocolSurfaces.enabled
    check config.keyBindings.len > 0
    check config.pointerBindings.len > 0

  test "DOD config defaults clamp invalid runtime values":
    var model = DodModel()
    model.applyConfig(Config(
      layout: LayoutConfig(
        gaps: -9,
        centerFocusedColumn: "sideways",
        defaultColumnWidth: 4.0,
        defaultWindowWidth: -1.0,
        defaultWindowHeight: 0.0,
        defaultMasterCount: 0,
        defaultMasterRatio: 2.0,
        animationSpeed: 5.0),
      workspaces: WorkspaceConfig(defaultCount: 0),
      overview: OverviewConfig(outerGap: -1),
      scratchpad: ScratchpadConfig(widthRatio: 4.0, heightRatio: 0.0)))

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
