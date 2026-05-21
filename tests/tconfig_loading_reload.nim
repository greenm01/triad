import tconfig_support
import ../src/daemon/reload_runtime
from ../src/daemon/state import initTriadDaemon

proc loadStrictConfigContent(content, name: string): ConfigLoadResult =
  let path =
    getTempDir() / ("triad-config-" & name & "-" & $getCurrentProcessId() & ".kdl")
  writeFile(path, content)
  result = loadConfigStrict(path)
  removeFile(path)

suite "KDL Configuration Parser: loading reload":
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
        frameTabs: FrameTabsConfig(
          activeColor: 0x010203ff'u32,
          activeUnfocusedColor: 0x040506ff'u32,
          inactiveColor: 0x07080980'u32,
          activeLineColor: 0x0a0b0cff'u32,
          activeUnfocusedLineColor: 0x0d0e0fff'u32,
          emptyBackgroundColor: 0x11121340'u32,
        ),
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
      environment:
        @[
          EnvironmentEntryConfig(name: "GTK_THEME", value: "Adwaita:dark"),
          EnvironmentEntryConfig(name: "SSH_AUTH_SOCK", unset: true),
        ],
      scratchpad: ScratchpadConfig(widthRatio: 0.7, heightRatio: 0.6),
      cursor: CursorConfig(theme: "Bibata", size: 32),
      configNotification:
        ConfigNotificationConfig(reloadSucceeded: @["notify-send", "reloaded"]),
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
      axisBindings:
        @[
          AxisBindingConfig(
            direction: AxisBindingDirection.AxisUp,
            modifiers: 64'u32,
            command: "focus-left",
          )
        ],
      gestureBindings:
        @[
          GestureBindingConfig(
            direction: GestureBindingDirection.GestureSwipeLeft,
            fingers: 3,
            modifiers: 64'u32,
            command: "focus-left",
          )
        ],
      switchEvents:
        @[
          SwitchEventConfig(
            kind: SwitchEventKind.SwitchLidClose, command: "lock-session"
          )
        ],
    )

    check state.applyRuntimeConfig(config)
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 24
    check state.model.innerGaps == 12
    check state.model.borderWidth == 4
    check state.model.frameTabs.activeColor == 0x010203ff'u32
    check state.model.frameTabs.activeUnfocusedColor == 0x040506ff'u32
    check state.model.frameTabs.inactiveColor == 0x07080980'u32
    check state.model.frameTabs.activeLineColor == 0x0a0b0cff'u32
    check state.model.frameTabs.activeUnfocusedLineColor == 0x0d0e0fff'u32
    check state.model.frameTabs.emptyBackgroundColor == 0x11121340'u32
    check state.model.defaultWorkspaceCount == 4
    check state.model.layoutCycle ==
      @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.VerticalGrid]
    check state.model.terminal.command == @["kitty"]
    check state.model.environment.len == 2
    check state.model.overviewZoom == 0.25'f32
    check state.model.configNotification.reloadSucceeded == @["notify-send", "reloaded"]
    check state.model.keyBindings.len == 1
    check state.model.axisBindings.len == 1
    check state.model.gestureBindings.len == 1
    check state.model.switchEvents.len == 1

    let snapshot = state.model.shellSnapshot()
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 7
    check snapshot.windows[0].appId == "brave"
    check snapshot.windows[0].actualW == 1200
    check snapshot.workspaces[0].name == "term"

  test "Default reload binding requests full Triad reload":
    let bindings = defaultKeyBindings()
    let reloads = bindings.filterIt(it.command == "triad-reload")
    check reloads.len == 1
    check reloads[0].key == "r"
    check reloads[0].modifiers == 12'u32
    check reloads[0].bypassShortcutsInhibit
    check bindings.allIt(it.command != "reload-config")

  test "Default parser bindings mirror Mango scratchpad chords":
    let bindings = defaultKeyBindings()

    check bindings.anyIt(
      it.key == "i" and it.modifiers == Super and it.command == "move-to-scratchpad"
    )
    check bindings.anyIt(
      it.key == "z" and it.modifiers == Super + Alt and it.command == "toggle-scratchpad"
    )
    check bindings.anyIt(
      it.key == "i" and it.modifiers == Super + Shift and
        it.command == "restore-scratchpad"
    )
    check bindings.anyIt(
      it.key == "b" and it.modifiers == Super + Shift and it.command == "minimize"
    )

  test "Strict config load rejects invalid KDL":
    let path = getCurrentDir() / "test_invalid_reload.kdl"
    writeFile(path, "layout { gaps ")
    let loaded = loadConfigStrict(path)
    removeFile(path)

    check not loaded.ok
    check loaded.error.len > 0

  test "Strict config load accepts supported output rule fields":
    let loaded = loadStrictConfigContent(
      """
output "DP-1" {
  focus-at-startup
  workspaces 1 2 2
  mode 2560 1440 120
  scale 1.25
  position -1920 0
  transform "flipped-90"
  adaptive-sync #true
}
output "desc:Dell U2720Q" {
  mode "highrr"
  scale "auto"
  position "auto-center-right"
  transform 5
  disabled #false
  vrr 2
  reserved_area top=10 right=20 bottom=30 left=40
}
output "" {
  mode "preferred"
  position "auto"
}
""",
      "valid-output",
    )

    check loaded.ok
    check loaded.config.outputRules.len == 3
    check loaded.config.outputRules[0].workspaceSlots == @[1'u32, 2'u32]
    check loaded.config.outputRules[1].modeKind == OutputModeKind.OutputModeHighRr
    check loaded.config.outputRules[1].scaleAuto
    check loaded.config.outputRules[1].positionKind ==
      OutputPositionKind.OutputPositionAutoCenterRight
    check loaded.config.outputRules[1].enabledSet
    check loaded.config.outputRules[1].enabled
    check loaded.config.outputRules[1].adaptiveSync
    check loaded.config.outputRules[1].reservedLeft == 40
    check loaded.config.outputRules[2].target.len == 0

  test "Strict config load rejects invalid output rule fields":
    let cases =
      @[
        (
          name: "missing-target",
          content:
            """
output {
  mode 1920 1080 60
}
""",
          needle: "output[0]: expected exactly one output target",
        ),
        (
          name: "bad-target-type",
          content:
            """
output 1 {
  mode 1920 1080 60
}
""",
          needle: "output[0]: output target must be a string",
        ),
        (
          name: "unsupported-field",
          content:
            """
output "DP-1" {
  mirror "eDP-1"
}
""",
          needle: "output \"DP-1\" mirror: field is not supported",
        ),
        (
          name: "unknown-field",
          content:
            """
output "DP-1" {
  mystery "right"
}
""",
          needle: "output \"DP-1\" mystery: unknown field",
        ),
        (
          name: "fallback-workspace",
          content:
            """
output "" {
  workspaces 1
}
""",
          needle: "output \"\" workspaces: fallback output rules cannot set",
        ),
        (
          name: "contradictory-enabled",
          content:
            """
output "DP-1" {
  enabled #true
  disabled #true
}
""",
          needle: "output \"DP-1\" enabled: enabled and disabled fields request",
        ),
        (
          name: "unsupported-hyprland-field",
          content:
            """
output "DP-1" {
  auto "right"
}
""",
          needle: "output \"DP-1\" auto: field is not supported",
        ),
        (
          name: "bad-mode",
          content:
            """
output "DP-1" {
  mode 1920 1080
}
""",
          needle: "output \"DP-1\" mode: expected 1 or 3 argument",
        ),
        (
          name: "bad-scale",
          content:
            """
output "DP-1" {
  scale "bogus"
}
""",
          needle: "output \"DP-1\" scale: expected a numeric scale or auto",
        ),
        (
          name: "bad-position",
          content:
            """
output "DP-1" {
  position "middle"
}
""",
          needle: "output \"DP-1\" position: expected XxY",
        ),
        (
          name: "bad-transform",
          content:
            """
output "DP-1" {
  transform "inverted"
}
""",
          needle: "output \"DP-1\" transform: expected one of",
        ),
        (
          name: "bad-adaptive-sync",
          content:
            """
output "DP-1" {
  adaptive-sync "true"
}
""",
          needle: "output \"DP-1\" adaptive-sync: expected a bool value",
        ),
        (
          name: "bad-workspace",
          content:
            """
output "DP-1" {
  workspaces 1 -2
}
""",
          needle: "output \"DP-1\" workspaces: workspace ids must be positive",
        ),
        (
          name: "bad-reserved-area",
          content:
            """
output "DP-1" {
  reserved_area top=-1
}
""",
          needle:
            "output \"DP-1\" reserved_area: reserved area values must be non-negative",
        ),
      ]

    for testCase in cases:
      let loaded = loadStrictConfigContent(testCase.content, testCase.name)
      check not loaded.ok
      check loaded.error.contains(testCase.needle)

  test "Configured reserved area is additive over live usable output area":
    var state = initRuntimeStateFromConfig(
      Config(
        outputRules:
          @[
            OutputRule(
              target: "HDMI-A-1",
              reservedAreaSet: true,
              reservedTop: 10,
              reservedRight: 20,
              reservedBottom: 30,
              reservedLeft: 40,
            )
          ]
      )
    )

    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "HDMI-A-1")
    )
    discard state.applyRuntimeUpdate(
      Msg(
        kind: MsgKind.WlOutputUsable,
        usableOutputId: 1,
        usableX: 0,
        usableY: 24,
        usableW: 1000,
        usableH: 676,
      )
    )

    var model = state.model
    let outputId = model.outputForExternal(ExternalOutputId(1))
    let output = model.outputData(outputId).get()
    check output.baseUsableY == 24
    check output.usableX == 40
    check output.usableY == 34
    check output.usableW == 940
    check output.usableH == 636

    model.applyConfig(Config())
    let restored = model.outputData(outputId).get()
    check restored.usableX == 0
    check restored.usableY == 24
    check restored.usableW == 1000
    check restored.usableH == 676

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

  test "Startup config load uses built-in fallback after strict validation failure":
    let path =
      getTempDir() / ("triad-startup-invalid-" & $getCurrentProcessId() & ".kdl")
    writeFile(
      path,
      """
terminal {
  command "custom-terminal"
}

bindings {
  bind "Super+t" "spawn custom-terminal"
}

window-rule {
  match app-id="["
  open-floating #true
}
""",
    )

    var daemon = initTriadDaemon()
    daemon.setupConfig(path)
    let loaded = daemon.loadStartupConfig()

    check loaded.usedFallback
    check loaded.error.contains("window-rule[0].match[0] app-id")
    check daemon.configWatchPaths == @[path.absoluteConfigPath()]
    check loaded.config.commandForBinding("t", Super) == "spawn-terminal"
    check loaded.config.terminal.command != @["custom-terminal"]

    removeFile(path)

  test "Startup config load falls back when required include is missing":
    let dir = getTempDir() / ("triad-startup-missing-include-" & $getCurrentProcessId())
    createDir(dir)
    let root = dir / "root.kdl"
    writeFile(root, "include \"missing.kdl\"\n")

    var daemon = initTriadDaemon()
    daemon.setupConfig(root)
    let loaded = daemon.loadStartupConfig()

    check loaded.usedFallback
    check loaded.error.contains("included config not found")
    check daemon.configWatchPaths == @[root.absoluteConfigPath()]
    check loaded.config.commandForBinding("Delete", Ctrl + Alt) == "exit-session"

    removeFile(root)
    removeDir(dir)

  test "Startup setup creates fallback config when path is absent":
    let dir = getTempDir() / ("triad-startup-absent-config-" & $getCurrentProcessId())
    createDir(dir)
    let configPath = dir / "config.kdl"

    var daemon = initTriadDaemon()
    daemon.setupConfig(configPath)
    let loaded = daemon.loadStartupConfig()

    check fileExists(configPath)
    check not loaded.usedFallback
    check daemon.configWatchPaths == @[configPath.absoluteConfigPath()]
    check loaded.config.commandForBinding("Delete", Ctrl + Alt) == "exit-session"

    removeFile(configPath)
    removeDir(dir)

  test "Startup setup preserves broken config symlink and falls back":
    let dir = getTempDir() / ("triad-startup-broken-link-" & $getCurrentProcessId())
    createDir(dir)
    let configPath = dir / "config.kdl"
    let missingTarget = dir / "missing" / "config.kdl"
    createSymlink(missingTarget, configPath)

    var daemon = initTriadDaemon()
    daemon.setupConfig(configPath)
    let loaded = daemon.loadStartupConfig()

    check symlinkExists(configPath)
    check not fileExists(configPath)
    check loaded.usedFallback
    check daemon.configWatchPaths == @[configPath.absoluteConfigPath()]
    check loaded.config.commandForBinding("r", Ctrl + Alt) == "triad-reload"

    removeFile(configPath)
    removeDir(dir)

  test "Config includes merge in place and root settings can override":
    let dir = getTempDir() / ("triad-config-include-" & $getCurrentProcessId())
    createDir(dir)
    let included = dir / "base.kdl"
    let root = dir / "root.kdl"
    writeFile(
      included,
      """
layout {
  gaps 8
}

workspaces {
  default-count 5
}
""",
    )
    writeFile(
      root,
      """
include "base.kdl"

layout {
  gaps 24
}
""",
    )

    let loaded = loadConfigStrict(root)
    check loaded.ok
    check loaded.config.layout.gaps == 24
    check loaded.config.workspaces.defaultCount == 5
    check loaded.configPaths ==
      @[root.absoluteConfigPath(), included.absoluteConfigPath()]

    removeFile(root)
    removeFile(included)
    removeDir(dir)

  test "Optional missing config include is accepted":
    let dir = getTempDir() / ("triad-config-optional-include-" & $getCurrentProcessId())
    createDir(dir)
    let root = dir / "root.kdl"
    writeFile(
      root,
      """
include "missing.kdl" optional=#true

layout {
  gaps 12
}
""",
    )

    let loaded = loadConfigStrict(root)
    check loaded.ok
    check loaded.config.layout.gaps == 12
    check loaded.configPaths == @[root.absoluteConfigPath()]

    removeFile(root)
    removeDir(dir)

  test "Required missing config include is rejected":
    let dir = getTempDir() / ("triad-config-missing-include-" & $getCurrentProcessId())
    createDir(dir)
    let root = dir / "root.kdl"
    writeFile(root, "include \"missing.kdl\"\n")

    let loaded = loadConfigStrict(root)
    check not loaded.ok
    check loaded.error.contains("included config not found")

    removeFile(root)
    removeDir(dir)

  test "Recursive config include is rejected":
    let dir =
      getTempDir() / ("triad-config-recursive-include-" & $getCurrentProcessId())
    createDir(dir)
    let root = dir / "root.kdl"
    let child = dir / "child.kdl"
    writeFile(root, "include \"child.kdl\"\n")
    writeFile(child, "include \"root.kdl\"\n")

    let loaded = loadConfigStrict(root)
    check not loaded.ok
    check loaded.error.contains("recursive config include")

    removeFile(root)
    removeFile(child)
    removeDir(dir)

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

  test "Text command parser accepts BSP preselection commands":
    let left = parseTextCommand("bsp-preselect-left")
    check left.isSome
    check left.get().kind == MsgKind.CmdBspPreselect
    check left.get().bspPreselectDirection == Direction.DirLeft

    let ratio = parseTextCommand("bsp-preselect-ratio 0.35")
    check ratio.isSome
    check ratio.get().kind == MsgKind.CmdBspPreselectRatio
    check abs(ratio.get().bspPreselectRatio - 0.35'f32) < 0.001'f32

    check parseTextCommand("bsp-preselect-ratio nope").isNone

    let dwindleHorizontal = parseTextCommand("dwindle-split-horizontal")
    check dwindleHorizontal.isSome
    check dwindleHorizontal.get().kind == MsgKind.CmdBspPreselect
    check dwindleHorizontal.get().bspPreselectDirection == Direction.DirRight

    let dwindleVertical = parseTextCommand("dwindle-split-vertical")
    check dwindleVertical.isSome
    check dwindleVertical.get().kind == MsgKind.CmdBspPreselect
    check dwindleVertical.get().bspPreselectDirection == Direction.DirDown

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
