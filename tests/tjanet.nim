import std/[options, os, unittest]
import ../src/core/msg
import ../src/janet/runtime
import ../src/types/[runtime_values, shell_snapshot]

proc testConfig(dir: string): JanetConfig =
  JanetConfig(
    enabled: true,
    manifestDir: dir,
    systemManifestDir: dir / "system",
    fuelLimit: 500000,
  )

proc testSnapshot(): ShellSnapshot =
  ShellSnapshot(
    version: TriadIpcVersion,
    activeTag: 1,
    activeWorkspaceIdx: 1,
    workspaces:
      @[
        ShellWorkspace(
          tagId: 1, workspaceIdx: 1, name: "term", layoutMode: LayoutMode.Scroller
        ),
        ShellWorkspace(
          tagId: 2, workspaceIdx: 2, name: "web", layoutMode: LayoutMode.Grid
        ),
      ],
    windows:
      @[
        ShellWindow(id: 10, title: "Terminal", appId: "kitty", tagId: some(1'u32)),
        ShellWindow(id: 11, title: "Browser", appId: "firefox", tagId: some(2'u32)),
        ShellWindow(
          id: 12,
          title: "Toolbox",
          appId: "gimp",
          identifier: "toolbox",
          tagId: some(1'u32),
        ),
      ],
    outputs: @[ShellOutput(id: 1, name: "HDMI-A-1", w: 1920, h: 1080, isPrimary: true)],
  )

suite "embedded Janet runtime":
  test "command functions emit reducer messages":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(triad/move-to-tag 2)
(triad/set-layout "grid")
(triad/toggle-floating)
(triad/move-window-to-tag 12 8 true)
(triad/move-window-to-workspace 12 2 false)
(triad/set-window-floating 12 true)
(triad/set-layout-for-workspace 8 "scroller")
(triad/focus-window 12)
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 8
    check evaluated.messages[0].kind == MsgKind.CmdMoveToTag
    check evaluated.messages[0].targetTag == 2
    check evaluated.messages[1].kind == MsgKind.CmdSetLayout
    check evaluated.messages[1].newLayout == LayoutMode.Grid
    check evaluated.messages[2].kind == MsgKind.CmdToggleFloating
    check evaluated.messages[3].kind == MsgKind.CmdMoveWindowToTag
    check evaluated.messages[3].moveWindowId == 12
    check evaluated.messages[3].moveTargetTag == 8
    check evaluated.messages[3].moveFollowWindow
    check evaluated.messages[4].kind == MsgKind.CmdMoveWindowToWorkspaceIndex
    check evaluated.messages[4].moveWorkspaceWindowId == 12
    check evaluated.messages[4].moveWorkspaceIndex == 2
    check not evaluated.messages[4].moveWorkspaceFollowWindow
    check evaluated.messages[5].kind == MsgKind.CmdSetWindowFloatingById
    check evaluated.messages[5].floatingWindowId == 12
    check evaluated.messages[5].windowFloating
    check evaluated.messages[6].kind == MsgKind.CmdSetLayout
    check evaluated.messages[6].layoutTargetTag == 8
    check evaluated.messages[6].newLayout == LayoutMode.Scroller
    check evaluated.messages[7].kind == MsgKind.CmdFocusWindowById
    check evaluated.messages[7].focusWindowId == 12

  test "snapshot query helpers expose current state":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(let [tag (triad/find-tag-by-name "web")]
  (triad/focus-tag (tag :tag-id)))
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 1
    check evaluated.messages[0].kind == MsgKind.CmdFocusTag
    check evaluated.messages[0].focusTag == 2

  test "current window exposes opening metadata":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(when (= "toolbox" (triad/current-window :identifier))
  (triad/move-window-to-tag (triad/current-window :id) 8))
""",
      currentWindow = some(
        ShellWindow(id: 12, title: "Toolbox", appId: "gimp", identifier: "toolbox")
      ),
    )

    check evaluated.ok
    check evaluated.messages.len == 1
    check evaluated.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check evaluated.messages[0].moveWindowId == 12
    check evaluated.messages[0].moveTargetTag == 8

  test "bundled GIMP manifest targets graphics workspace":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      readFile("manifests/gimp.janet"),
      "manifests/gimp.janet",
      some(ShellWindow(id: 12, title: "Toolbox", appId: "gimp", identifier: "toolbox")),
    )

    check evaluated.ok
    check evaluated.messages.len == 3
    check evaluated.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check evaluated.messages[0].moveTargetTag == 8
    check evaluated.messages[0].moveFollowWindow
    check evaluated.messages[1].kind == MsgKind.CmdSetLayout
    check evaluated.messages[1].layoutTargetTag == 8
    check evaluated.messages[1].newLayout == LayoutMode.Scroller
    check evaluated.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check evaluated.messages[2].floatingWindowId == 12
    check evaluated.messages[2].windowFloating

  test "sandbox blocks host access":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(testSnapshot(), """(os/getenv "HOME")""")

    check not evaluated.ok
    check evaluated.messages.len == 0

  test "loop guard rejects obvious infinite loops":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(testSnapshot(), """(while true nil)""")

    check not evaluated.ok
    check evaluated.error.len > 0

  test "manifest lookup emits messages for matching app id":
    let dir = getTempDir() / "triad-janet-tests"
    createDir(dir)
    writeFile(dir / "firefox.janet", """(triad/move-to-workspace 2)""")

    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      removeFile(dir / "firefox.janet")
      removeDir(dir)

    let messages = runtime.evalManifest("firefox", testSnapshot())

    check messages.len == 1
    check messages[0].kind == MsgKind.CmdMoveToWorkspaceIndex
    check messages[0].workspaceIndex == 2
