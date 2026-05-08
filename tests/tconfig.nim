import unittest
import ../src/config/parser
import ../src/core/model
import os, tables

suite "KDL Configuration Parser":
  test "Parser correctly reads layout settings":
    let path = getCurrentDir() / "test_layout.kdl"
    # KDL 2.0 requires #true/#false for booleans!
    let kdl = """
layout {
    gaps 32
    center-focused-column "always"
    default-column-width { proportion 0.75; }
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
    check config.layout.enableAnimations == false
    check config.layout.animationSpeed == 0.5
    check config.layout.smartGaps == true
    check config.layout.layoutCycle == @[Scroller, Deck, VerticalGrid]
    check config.scratchpad.widthRatio == 0.7'f32
    check config.scratchpad.heightRatio == 0.6'f32

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
    theme "DankMaterialShell"
    args "--debug" "--fast"
}
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.quickshell.enabled == true
    check config.quickshell.theme == "DankMaterialShell"
    check config.quickshell.args == @["--debug", "--fast"]

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
