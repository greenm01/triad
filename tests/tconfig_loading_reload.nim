import tconfig_support

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
      axisBindings:
        @[
          AxisBindingConfig(
            direction: AxisBindingDirection.AxisUp,
            modifiers: 64'u32,
            command: "focus-left",
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
    check state.model.axisBindings.len == 1

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
