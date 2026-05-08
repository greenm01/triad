import unittest
import ../src/config/parser
import ../src/core/model
import os

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
"""
    writeFile(path, kdl)
    let config = loadConfig(path)
    removeFile(path)
    
    check config.windowRules.len == 2
    check config.windowRules[0].appIdMatch == "firefox"
    check config.windowRules[0].defaultTag == 2
    check config.windowRules[1].titleMatch == "Picture-in-Picture"
    check config.windowRules[1].openFloating == true

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
