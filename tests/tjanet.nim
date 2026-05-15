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
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 3
    check evaluated.messages[0].kind == MsgKind.CmdMoveToTag
    check evaluated.messages[0].targetTag == 2
    check evaluated.messages[1].kind == MsgKind.CmdSetLayout
    check evaluated.messages[1].newLayout == LayoutMode.Grid
    check evaluated.messages[2].kind == MsgKind.CmdToggleFloating

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
