import unittest
import ../src/config/parser
import ../src/config/defaults
import ../src/config/keysyms
import ../src/core/model
import ../src/core/model_utils
import ../src/utils/terminal
import os, strutils, tables

suite "KDL Configuration Parser":
  test "Applying config preserves live workspace and window state":
    var model = Model(activeTag: 1)
    model.tags[1] = initTagState(1, Scroller, "work")
    model.tags[1].focusedWindow = 7
    model.tags[1].columns.add(Column(windows: @[WindowId(7)], widthProportion: 0.85))
    model.windows[7] = WindowData(
      id: 7,
      appId: "brave",
      title: "Brave",
      widthProportion: 0.75,
      heightProportion: 0.6,
      isFloating: true,
      isFullscreen: true,
      isMaximized: true,
      fullscreenOutput: 42,
      floatingGeom: Rect(x: 11, y: 22, w: 333, h: 444))

    model.applyConfig(Config(layout: LayoutConfig(
      gaps: 20,
      centerFocusedColumn: "on-overflow",
      borderWidth: DefaultBorderWidth,
      focusedBorderColor: DefaultFocusedBorderColor,
      unfocusedBorderColor: DefaultUnfocusedBorderColor,
      animationSpeed: 0.2)))

    check model.outerGaps == 20
    check model.borderWidth == DefaultBorderWidth
    check model.focusedBorderColor == DefaultFocusedBorderColor
    check model.unfocusedBorderColor == DefaultUnfocusedBorderColor
    check model.activeTag == 1
    check model.tags[1].focusedWindow == 7
    check model.tags[1].columns[0].widthProportion == 0.85'f32
    check model.windows[7].widthProportion == 0.75'f32
    check model.windows[7].heightProportion == 0.6'f32
    check model.windows[7].isFloating
    check model.windows[7].isFullscreen
    check model.windows[7].isMaximized
    check model.windows[7].fullscreenOutput == 42
    check model.windows[7].floatingGeom == Rect(x: 11, y: 22, w: 333, h: 444)

  test "Parser correctly reads layout settings":
    let path = getCurrentDir() / "test_layout.kdl"
    # KDL 2.0 requires #true/#false for booleans!
    let kdl = """
layout {
    gaps 32
    center-focused-column "always"
    default-column-width { proportion 0.75; }
    default-window-width { proportion 0.8; }
    default-window-height { proportion 0.9; }
    master {
        count 2
        split-ratio 0.6
    }
    enable-animations #false
    animation-speed 0.5
    smart-gaps #true
    layout-cycle "scroller" "deck" "vertical-grid"
}
scratchpad {
    width-ratio 0.7
    height-ratio 0.6
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.layout.gaps == 32
    check config.layout.centerFocusedColumn == "always"
    check config.layout.defaultColumnWidth == 0.75
    check abs(config.layout.defaultWindowWidth - 0.8) < 0.001
    check abs(config.layout.defaultWindowHeight - 0.9) < 0.001
    check config.layout.defaultMasterCount == 2
    check abs(config.layout.defaultMasterRatio - 0.6) < 0.001
    check config.layout.enableAnimations == false
    check config.layout.animationSpeed == 0.5
    check config.layout.smartGaps == true
    check config.layout.layoutCycle == @[Scroller, Deck, VerticalGrid]
    check config.scratchpad.widthRatio == 0.7'f32
    check config.scratchpad.heightRatio == 0.6'f32

  test "Parser correctly reads border settings":
    let path = getCurrentDir() / "test_border.kdl"
    let kdl = """
layout {
    border {
        width 3
        active-color "#7fc8ff"
        inactive-color "#505050"
    }
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.borderWidth == 3
    check config.layout.focusedBorderColor == 0x7fc8ffff'u32
    check config.layout.unfocusedBorderColor == 0x505050ff'u32

  test "Invalid border settings fall back safely":
    let path = getCurrentDir() / "test_border_invalid.kdl"
    let kdl = """
layout {
    border {
        width 999
        active-color "not-a-color"
        inactive-color "#12345678"
    }
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.layout.borderWidth == 64
    check config.layout.focusedBorderColor == DefaultFocusedBorderColor
    check config.layout.unfocusedBorderColor == 0x12345678'u32

  test "Parser correctly reads tag rules":
    let path = getCurrentDir() / "test_tags.kdl"
    let kdl = """
tag-rules {
    tag 1 default-layout="tile"
    tag 2 default-layout="grid"
    tag 3 default-layout="monocle"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.tagRules.len == 3
    check config.tagRules[0].tagId == 1
    check config.tagRules[0].defaultLayout == MasterStack
    check config.tagRules[1].defaultLayout == Grid
    check config.tagRules[2].defaultLayout == Monocle

  test "Parser correctly reads workspace defaults":
    let path = getCurrentDir() / "test_workspaces.kdl"
    let kdl = """
workspaces {
    default-count 5
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.workspaces.defaultCount == 5

  test "Workspace default count is hardened":
    let negativePath = getCurrentDir() / "test_workspaces_negative.kdl"
    writeFile(negativePath, """
workspaces {
    default-count -1
}
""")
    let negativeConfig = loadConfig(negativePath)
    removeFile(negativePath)

    let hugePath = getCurrentDir() / "test_workspaces_huge.kdl"
    writeFile(hugePath, """
workspaces {
    default-count 1000
}
""")
    let hugeConfig = loadConfig(hugePath)
    removeFile(hugePath)

    var zeroModel = Model(activeTag: 1)
    zeroModel.applyConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 0),
      layout: LayoutConfig(
        borderWidth: DefaultBorderWidth,
        focusedBorderColor: DefaultFocusedBorderColor,
        unfocusedBorderColor: DefaultUnfocusedBorderColor)))

    var hugeModel = Model(activeTag: 1)
    hugeModel.applyConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 1000),
      layout: LayoutConfig(
        borderWidth: DefaultBorderWidth,
        focusedBorderColor: DefaultFocusedBorderColor,
        unfocusedBorderColor: DefaultUnfocusedBorderColor)))

    check negativeConfig.workspaces.defaultCount == DefaultWorkspaceCount
    check hugeConfig.workspaces.defaultCount == MaxWorkspaceCount
    check zeroModel.workspaces.defaultCount == DefaultWorkspaceCount
    check hugeModel.workspaces.defaultCount == MaxWorkspaceCount

  test "Applying config treats tag rules as lazy workspace templates":
    var model = Model(activeTag: 1)
    model.applyConfig(Config(
      workspaces: WorkspaceConfig(defaultCount: 3),
      layout: LayoutConfig(
        borderWidth: DefaultBorderWidth,
        focusedBorderColor: DefaultFocusedBorderColor,
        unfocusedBorderColor: DefaultUnfocusedBorderColor),
      tagRules: @[
        TagRule(tagId: 1, name: "term", defaultLayout: Scroller),
        TagRule(tagId: 2, name: "web", defaultLayout: Grid),
        TagRule(tagId: 4, name: "chat", defaultLayout: Deck),
        TagRule(tagId: 9, name: "spare", defaultLayout: Monocle)
      ]))

    check model.tags.hasKey(1)
    check model.tags.hasKey(2)
    check model.tags.hasKey(3)
    check not model.tags.hasKey(4)
    check not model.tags.hasKey(9)
    check model.tags[1].name == "term"
    check model.tags[2].layoutMode == Grid

  test "Parser correctly reads window rules":
    let path = getCurrentDir() / "test_window.kdl"
    let kdl = """
window-rule {
    match app-id="firefox"
    default-tag 2
}
window-rule {
    match title="Picture-in-Picture"
    open-floating #true
}
window-rule {
    match app-id="discord"
    forced-layout "grid"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.windowRules.len == 3
    check config.windowRules[0].appIdMatch == "firefox"
    check config.windowRules[0].defaultTag == 2
    check config.windowRules[1].titleMatch == "Picture-in-Picture"
    check config.windowRules[1].openFloating == true
    check config.windowRules[2].appIdMatch == "discord"
    check config.windowRules[2].forcedLayout == ord(Grid) + 1

  test "Parser correctly reads quickshell config":
    let path = getCurrentDir() / "test_qs.kdl"
    let kdl = """
quickshell {
    enabled #true
    command "quickshell"
    theme "DankMaterialShell"
    args "--debug" "--fast"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.quickshell.enabled == true
    check config.quickshell.command == "quickshell"
    check config.quickshell.theme == "DankMaterialShell"
    check config.quickshell.args == @["--debug", "--fast"]

  test "Parser correctly reads terminal, overview, floating, and screenshot config":
    let path = getCurrentDir() / "test_shell_policy.kdl"
    let kdl = """
terminal {
    command "wezterm" "start"
}
overview {
    outer-gap 72
    inner-gap-multiplier 1.5
}
floating {
    x-ratio 0.1
    y-ratio 0.2
    width-ratio 0.7
    height-ratio 0.6
    min-width 120
    min-height 90
}
screenshot {
    directory "~/Shots"
    filename-prefix "shot"
    capture-command "grim"
    region-selector-command "slurp"
    show-pointer #true
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.terminal.command == @["wezterm", "start"]
    check config.overview.outerGap == 72
    check config.overview.innerGapMultiplier == 1.5
    check config.floating.xRatio == 0.1'f32
    check config.floating.yRatio == 0.2'f32
    check config.floating.widthRatio == 0.7'f32
    check config.floating.heightRatio == 0.6'f32
    check config.floating.minWidth == 120
    check config.floating.minHeight == 90
    check config.screenshot.directory == "~/Shots"
    check config.screenshot.filenamePrefix == "shot"
    check config.screenshot.captureCommand == "grim"
    check config.screenshot.regionSelectorCommand == "slurp"
    check config.screenshot.showPointer == true

  test "Parser correctly reads screen lock command":
    let path = getCurrentDir() / "test_lock.kdl"
    let kdl = """
screen-lock {
    command "lockme" "--dev-mode"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.screenLock.command == @["lockme", "--dev-mode"]

  test "Parser correctly reads River policy config":
    let path = getCurrentDir() / "test_river_policy.kdl"
    let kdl = """
window-menu-command "menu-tool" "--quiet"
presentation-mode "async"
allow-exit-session #true
protocol-surfaces {
    enabled #true
    visible-debug #true
}
cursor {
    theme "Bibata-Modern-Classic"
    size 32
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.windowMenu.command == @["menu-tool", "--quiet"]
    check config.presentationMode == PresentationAsync
    check config.allowExitSession == true
    check config.protocolSurfaces.enabled == true
    check config.protocolSurfaces.visibleDebug == true
    check config.cursor.theme == "Bibata-Modern-Classic"
    check config.cursor.size == 32'u32

  test "Parser reads configurable key and pointer bindings":
    let path = getCurrentDir() / "test_bindings.kdl"
    let kdl = """
bindings {
    bind "Super+Return" "spawn-terminal" layout=1
    bind "Super+Shift+q" "close-window" mode="normal"
    bind "Return" "select-window" mode="overview"
    pointer-bind "Super+left" "move"
    pointer-bind "Super+right" "resize"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)

    check config.keyBindings.len == 3
    check config.keyBindings[0].key == "Return"
    check config.keyBindings[0].modifiers == 64'u32
    check config.keyBindings[0].command == "spawn-terminal"
    check config.keyBindings[0].mode == BindAlways
    check config.keyBindings[0].hasLayoutOverride == true
    check config.keyBindings[0].layoutOverride == 1'u32
    check config.keyBindings[1].key == "q"
    check config.keyBindings[1].modifiers == 65'u32
    check config.keyBindings[1].mode == BindNormal
    check config.keyBindings[2].key == "Return"
    check config.keyBindings[2].modifiers == 0'u32
    check config.keyBindings[2].mode == BindOverview
    check config.pointerBindings.len == 2
    check config.pointerBindings[0].button == 0x110'u32
    check config.pointerBindings[0].modifiers == 64'u32
    check config.pointerBindings[0].op == OpMove

  test "Parser supplies default bindings when config omits bindings":
    let path = getCurrentDir() / "test_default_bindings.kdl"
    writeFile(path, "layout { gaps 8 }\n")
    let config = loadConfig(path)
    removeFile(path)

    check config.keyBindings.len > 0
    check config.pointerBindings.len > 0

  test "Embedded fallback config stays shell and app neutral":
    let path = getCurrentDir() / "test_fallback_defaults.kdl"
    writeFile(path, FallbackConfigContent)
    let config = loadConfig(path)
    removeFile(path)

    check config.quickshell.enabled == false
    check config.quickshell.command == DefaultQuickshellCommand
    check config.quickshell.theme == ""
    check config.startupCommands.len == 0
    check config.windowRules.len == 0
    check config.layout.borderWidth == DefaultBorderWidth
    check config.layout.centerFocusedColumn == DefaultCenterFocusedColumn
    check config.layout.defaultColumnWidth == defaults.DefaultColumnWidth
    check config.overview.outerGap == DefaultOverviewOuterGap

  test "Default config overview up down keys use Niri workspace stack navigation":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")
    var commandsByKey = initTable[string, string]()
    for binding in config.keyBindings:
      if binding.mode == BindOverview and binding.key in ["Down", "Up", "j", "k"]:
        commandsByKey[binding.key] = binding.command

    check commandsByKey["Down"] == "focus-window-or-workspace-down"
    check commandsByKey["j"] == "focus-window-or-workspace-down"
    check commandsByKey["Up"] == "focus-window-or-workspace-up"
    check commandsByKey["k"] == "focus-window-or-workspace-up"

  test "Default config does not grab Kitty Ctrl Shift T":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")
    for binding in config.keyBindings:
      check not (binding.key.toLowerAscii() == "t" and binding.modifiers == 5'u32)

    check keySymForBinding("t", 5'u32) == uint32(ord('T'))
    check keySymForBinding("t", 65'u32) == uint32(ord('T'))

  test "Default config app launch bindings match Niri profile":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")
    var commandsByBinding = initTable[string, string]()
    for binding in config.keyBindings:
      if binding.mode == BindAlways:
        commandsByBinding[$binding.modifiers & ":" & binding.key] = binding.command

    check commandsByBinding["64:Return"] == "spawn kitty"
    check commandsByBinding["64:Space"] == "spawn fuzzel"
    check commandsByBinding["64:b"] == "spawn brave-origin-nightly"
    check commandsByBinding["64:e"] == "spawn env GTK_THEME=Adwaita:dark thunar"
    check commandsByBinding["65:b"] == "minimize"
    check commandsByBinding["68:e"] == "toggle-named-scratchpad terminal"
    check commandsByBinding["69:e"] == "move-to-named-scratchpad terminal"

  test "Default config uses Niri border colors":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")

    check config.layout.borderWidth == 3
    check config.layout.focusedBorderColor == 0x7fc8ffff'u32
    check config.layout.unfocusedBorderColor == 0x505050ff'u32

  test "Default config advertises three initial workspaces":
    let config = loadConfig(getCurrentDir() / "config.default.kdl")

    check config.workspaces.defaultCount == 3

  test "Applying config installs runtime defaults without disturbing live state":
    var model = Model(activeTag: 1, screenWidth: 2000, screenHeight: 1000)
    model.tags[1] = initTagState(1, Scroller, "work")
    model.tags[1].focusedWindow = 9
    model.tags[1].columns.add(Column(windows: @[WindowId(9)], widthProportion: 0.9))
    model.windows[9] = WindowData(id: 9, appId: "term", title: "term", isMaximized: true)

    model.applyConfig(Config(
      layout: LayoutConfig(
        gaps: 10,
        centerFocusedColumn: "on-overflow",
        defaultColumnWidth: 0.7,
        defaultWindowWidth: 0.8,
        defaultWindowHeight: 0.6,
        defaultMasterCount: 3,
        defaultMasterRatio: 0.65,
        borderWidth: DefaultBorderWidth,
        focusedBorderColor: DefaultFocusedBorderColor,
        unfocusedBorderColor: DefaultUnfocusedBorderColor,
        animationSpeed: 0.2),
      floating: FloatingConfig(
        xRatio: 0.1,
        yRatio: 0.2,
        widthRatio: 0.4,
        heightRatio: 0.5,
        minWidth: 100,
        minHeight: 80)))

    check model.defaultColumnWidth == 0.7'f32
    check model.defaultWindowWidth == 0.8'f32
    check model.defaultWindowHeight == 0.6'f32
    check model.defaultMasterCount == 3
    check model.defaultMasterRatio == 0.65'f32
    check model.tags[1].focusedWindow == 9
    check model.tags[1].columns[0].widthProportion == 0.9'f32
    check model.windows[9].isMaximized
    check model.defaultFloatingGeom() == Rect(x: 200, y: 200, w: 800, h: 500)

  test "Terminal resolver prefers env then neutral helpers then common terminals":
    proc hasOnlyKitty(command: string): bool =
      command == "kitty"

    check resolveTerminalCommand("wezterm start", hasOnlyKitty) == @["kitty"]

    proc hasConfigured(command: string): bool =
      command in ["wezterm", "kitty"]

    check resolveTerminalCommand("wezterm start", hasConfigured) == @["wezterm", "start"]
    check resolveTerminalCommand(@["ghostty"], "", proc(command: string): bool = command == "ghostty") == @["ghostty"]

    proc hasNeutral(command: string): bool =
      command == "x-terminal-emulator"

    check resolveTerminalCommand("", hasNeutral) == @["x-terminal-emulator"]
