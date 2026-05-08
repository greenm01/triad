import unittest, os, options
import ../src/core/app_identity

proc writeDesktop(root, name, body: string) =
  writeFile(root / name, body)

suite "App identity compatibility":
  setup:
    let root = getTempDir() / "triad-app-identity-test"
    if dirExists(root):
      removeDir(root)
    createDir(root)

  teardown:
    if dirExists(root):
      removeDir(root)

  test "parses desktop entry identity fields":
    writeDesktop(root, "foot.desktop", """
[Desktop Entry]
Name=Foot
Exec=foot --server %U
Icon=foot
StartupWMClass=foot
Categories=System;TerminalEmulator;
""")

    let parsed = parseDesktopEntry(root / "foot.desktop", root)
    check parsed.isSome
    check parsed.get().id == "foot.desktop"
    check parsed.get().name == "Foot"
    check parsed.get().execBase == "foot"
    check parsed.get().icon == "foot"
    check parsed.get().startupWmClass == "foot"
    check parsed.get().categories == @["System", "TerminalEmulator"]
    check parsed.get().isTerminalEntry

  test "maps exec basenames to desktop ids":
    writeDesktop(root, "kitty.desktop", """
[Desktop Entry]
Name=kitty
Exec=kitty --single-instance
Icon=kitty
""")

    let index = buildAppIdentityIndex([root])
    check compatAppId("kitty", index) == "kitty.desktop"

  test "maps startup wm class case-insensitively":
    writeDesktop(root, "Alacritty.desktop", """
[Desktop Entry]
Name=Alacritty
Exec=/usr/bin/alacritty
Icon=Alacritty
StartupWMClass=Alacritty
""")

    let index = buildAppIdentityIndex([root])
    check compatAppId("alacritty", index) == "alacritty.desktop"
    check compatAppId("Alacritty", index) == "alacritty.desktop"

  test "unknown app ids pass through unchanged":
    let index = buildAppIdentityIndex([root])
    check compatAppId("custom-tool", index) == "custom-tool"

  test "terminal aliases cover missing desktop scans":
    let index = buildAppIdentityIndex([root])
    check compatAppId("footclient", index) == "foot.desktop"
    check compatAppId("ghostty", index) == "com.mitchellh.ghostty.desktop"
