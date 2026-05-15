import std/[options, os, strutils, unittest]
import ../src/core/msg
import ../src/ipc/commands
import ../src/janet/runtime
import ../src/types/[ipc_commands, janet_manifest, runtime_values, shell_snapshot]

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

proc sampleCommandParts(spec: CommandSpec): seq[string] =
  result = @[spec.name]
  case spec.argShape
  of CommandArgShape.NoArgs:
    discard
  of CommandArgShape.OptionalWindowId, CommandArgShape.RequiredWindowId:
    result.add("42")
  of CommandArgShape.WindowTagFollow:
    result.add("42")
    result.add("3")
    result.add("true")
  of CommandArgShape.WindowWorkspaceFollow:
    result.add("42")
    result.add("2")
    result.add("true")
  of CommandArgShape.WindowBool:
    result.add("42")
    result.add("true")
  of CommandArgShape.TagLayout:
    result.add("3")
    result.add("grid")
  of CommandArgShape.RequiredTag:
    result.add("3")
  of CommandArgShape.RequiredWorkspaceIdx:
    result.add("2")
  of CommandArgShape.RequiredName:
    result.add("named scratch")
  of CommandArgShape.RequiredOutput:
    result.add("HDMI-A-1")
  of CommandArgShape.RequiredFloatDelta:
    result.add("-0.25")
  of CommandArgShape.RequiredFloatValue:
    result.add("0.75")
  of CommandArgShape.RequiredIntCount:
    result.add("2")
  of CommandArgShape.RequiredIntDelta:
    result.add("-1")
  of CommandArgShape.OptionalIntDelta:
    result.add("-1")
  of CommandArgShape.MoveDelta:
    result.add("12")
    result.add("-34")
  of CommandArgShape.ResizeDelta:
    result.add("12")
    result.add("-34")
  of CommandArgShape.RecentAdvance:
    result.add("--scope")
    result.add("output")
    result.add("--filter")
    result.add("app-id")
  of CommandArgShape.RecentScope:
    result.add("workspace")
  of CommandArgShape.SpawnArgv:
    result.add("sh")
    result.add("-lc")
    result.add("echo")
  of CommandArgShape.WarpPointer:
    result.add("12")
    result.add("34")
  of CommandArgShape.Screenshot:
    result.add("--path")
    result.add("/tmp/triad.png")
    result.add("--show-pointer")
    result.add("--clipboard-only")

proc janetStringLiteral(value: string): string =
  "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc janetCommandSource(parts: seq[string]): string =
  result = "(triad/command"
  for part in parts:
    result.add(" ")
    result.add(part.janetStringLiteral())
  result.add(")")

suite "embedded Janet runtime":
  test "generic command function emits reducer messages":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(triad/command "move-to-tag" 2)
(triad/command "layout-grid")
(triad/command "toggle-floating")
(triad/command "move-window-to-tag" 12 8 true)
(triad/command "move-window-to-workspace" 12 2 false)
(triad/command "set-window-floating" 12 true)
(triad/command "set-window-maximized" 12 true)
(triad/command "set-layout-for-workspace" 8 "scroller")
(triad/command "focus-window" 12)
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 9
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
    check evaluated.messages[6].kind == MsgKind.CmdSetWindowMaximizedById
    check evaluated.messages[6].maximizedWindowId == 12
    check evaluated.messages[6].windowMaximized
    check evaluated.messages[7].kind == MsgKind.CmdSetLayout
    check evaluated.messages[7].layoutTargetTag == 8
    check evaluated.messages[7].newLayout == LayoutMode.Scroller
    check evaluated.messages[8].kind == MsgKind.CmdFocusWindowById
    check evaluated.messages[8].focusWindowId == 12

  test "generic command dispatcher mirrors every registered command":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    for spec in CommandSpecs:
      let parts = sampleCommandParts(spec)
      let expected = parseCommandParts(parts)
      check expected.isSome
      let evaluated = runtime.evalSource(testSnapshot(), janetCommandSource(parts))
      check evaluated.ok
      check evaluated.messages.len == 1
      check repr(evaluated.messages[0]) == repr(expected.get())

      if spec.aliases.len > 0:
        for alias in spec.aliases.split('|'):
          var aliasParts = parts
          aliasParts[0] = alias
          let aliasExpected = parseCommandParts(aliasParts)
          check aliasExpected.isSome
          let aliasEvaluated =
            runtime.evalSource(testSnapshot(), janetCommandSource(aliasParts))
          check aliasEvaluated.ok
          check aliasEvaluated.messages.len == 1
          check repr(aliasEvaluated.messages[0]) == repr(aliasExpected.get())

  test "generic command dispatcher accepts numeric args and rejects bad commands":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let highId = 4278190142'u32
    let numeric = runtime.evalSource(
      testSnapshot(),
      """
(triad/command "focus-window" 4278190142)
(triad/command "set-column-width" 0.75)
(triad/command "move-window-to-tag" 4278190142 8 true)
(triad/command "set-window-maximized" 4278190142 true)
""",
    )

    check numeric.ok
    check numeric.messages.len == 4
    check numeric.messages[0].kind == MsgKind.CmdFocusWindowById
    check numeric.messages[0].focusWindowId == highId
    check numeric.messages[1].kind == MsgKind.CmdSetColumnWidth
    check numeric.messages[1].targetWidth == 0.75'f32
    check numeric.messages[2].kind == MsgKind.CmdMoveWindowToTag
    check numeric.messages[2].moveWindowId == highId
    check numeric.messages[2].moveTargetTag == 8
    check numeric.messages[2].moveFollowWindow
    check numeric.messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check numeric.messages[3].maximizedWindowId == highId
    check numeric.messages[3].windowMaximized

    let invalid = runtime.evalSource(
      testSnapshot(),
      """
(triad/command "not-a-command")
(triad/command "focus-window" "bad")
""",
    )

    check invalid.ok
    check invalid.messages.len == 0

  test "snapshot query helpers expose current state":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(let [tag (triad/find-tag-by-name "web")]
  (triad/command "focus-tag" (tag :tag-id)))
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
  (triad/command "move-window-to-tag" (triad/current-window :id) 8))
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

  test "targeted window commands accept compositor ids above signed int32":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let highId = 4278190142'u32
    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(triad/command "move-window-to-tag" (triad/current-window :id) 8 true)
(triad/command "set-window-floating" (triad/current-window :id) true)
(triad/command "set-window-maximized" (triad/current-window :id) true)
(triad/command "focus-window" (triad/current-window :id))
""",
      currentWindow = some(ShellWindow(id: highId, title: "GIMP", appId: "gimp")),
    )

    check evaluated.ok
    check evaluated.messages.len == 4
    check evaluated.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check evaluated.messages[0].moveWindowId == highId
    check evaluated.messages[1].kind == MsgKind.CmdSetWindowFloatingById
    check evaluated.messages[1].floatingWindowId == highId
    check evaluated.messages[2].kind == MsgKind.CmdSetWindowMaximizedById
    check evaluated.messages[2].maximizedWindowId == highId
    check evaluated.messages[3].kind == MsgKind.CmdFocusWindowById
    check evaluated.messages[3].focusWindowId == highId

  test "bundled GIMP manifest targets graphics workspace":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()
    let manifest = readFile("manifests/gimp.janet")

    let firstPalette = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(ShellWindow(id: 12, title: "Toolbox", appId: "gimp", identifier: "toolbox")),
    )

    check firstPalette.ok
    check firstPalette.messages.len == 3
    check firstPalette.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check firstPalette.messages[0].moveTargetTag == 8
    check firstPalette.messages[0].moveFollowWindow
    check firstPalette.messages[1].kind == MsgKind.CmdSetLayout
    check firstPalette.messages[1].layoutTargetTag == 8
    check firstPalette.messages[1].newLayout == LayoutMode.Scroller
    check firstPalette.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check firstPalette.messages[2].floatingWindowId == 12
    check firstPalette.messages[2].windowFloating

    let mainWindow = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(
        ShellWindow(id: 13, title: "GNU Image Manipulation Program", appId: "gimp-3.2")
      ),
    )

    check mainWindow.ok
    check mainWindow.messages.len == 4
    check mainWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check mainWindow.messages[0].moveTargetTag == 8
    check mainWindow.messages[0].moveFollowWindow
    check mainWindow.messages[1].kind == MsgKind.CmdSetLayout
    check mainWindow.messages[1].layoutTargetTag == 8
    check mainWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check mainWindow.messages[2].floatingWindowId == 13
    check not mainWindow.messages[2].windowFloating
    check mainWindow.messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check mainWindow.messages[3].maximizedWindowId == 13
    check mainWindow.messages[3].windowMaximized

    let laterPalette = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(ShellWindow(id: 14, title: "Tool Options", appId: "org.gimp.GIMP")),
    )

    check laterPalette.ok
    check laterPalette.messages.len == 3
    check laterPalette.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check laterPalette.messages[0].moveTargetTag == 8
    check not laterPalette.messages[0].moveFollowWindow
    check laterPalette.messages[1].kind == MsgKind.CmdSetLayout
    check laterPalette.messages[1].layoutTargetTag == 8
    check laterPalette.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check laterPalette.messages[2].floatingWindowId == 14
    check laterPalette.messages[2].windowFloating

    let dialogWindow = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(ShellWindow(id: 15, title: "Preferences", appId: "gimp")),
    )

    check dialogWindow.ok
    check dialogWindow.messages.len == 3
    check dialogWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check dialogWindow.messages[0].moveTargetTag == 8
    check dialogWindow.messages[0].moveFollowWindow
    check dialogWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check dialogWindow.messages[2].floatingWindowId == 15
    check dialogWindow.messages[2].windowFloating

    let parentedDialog = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(ShellWindow(id: 16, parentId: 13, title: "Untitled", appId: "gimp")),
    )

    check parentedDialog.ok
    check parentedDialog.messages.len == 3
    check parentedDialog.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check parentedDialog.messages[0].moveTargetTag == 8
    check parentedDialog.messages[0].moveFollowWindow
    check parentedDialog.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check parentedDialog.messages[2].floatingWindowId == 16
    check parentedDialog.messages[2].windowFloating

    let ignored = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/gimp.janet",
      some(ShellWindow(id: 17, title: "Terminal", appId: "kitty")),
    )

    check ignored.ok
    check ignored.messages.len == 0

  test "bundled Vesktop manifest targets chat workspace":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()
    let manifest = readFile("manifests/vesktop.janet")

    let mainWindow = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/vesktop.janet",
      some(ShellWindow(id: 18, title: "Discord", appId: "vesktop")),
    )

    check mainWindow.ok
    check mainWindow.messages.len == 4
    check mainWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check mainWindow.messages[0].moveWindowId == 18
    check mainWindow.messages[0].moveTargetTag == 4
    check mainWindow.messages[0].moveFollowWindow
    check mainWindow.messages[1].kind == MsgKind.CmdSetLayout
    check mainWindow.messages[1].layoutTargetTag == 4
    check mainWindow.messages[1].newLayout == LayoutMode.Deck
    check mainWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check mainWindow.messages[2].floatingWindowId == 18
    check not mainWindow.messages[2].windowFloating
    check mainWindow.messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check mainWindow.messages[3].maximizedWindowId == 18
    check mainWindow.messages[3].windowMaximized

    let parentedDialog = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/vesktop.janet",
      some(
        ShellWindow(
          id: 19, parentId: 18, title: "Open File", appId: "dev.vencord.Vesktop"
        )
      ),
    )

    check parentedDialog.ok
    check parentedDialog.messages.len == 3
    check parentedDialog.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check parentedDialog.messages[0].moveWindowId == 19
    check parentedDialog.messages[0].moveTargetTag == 4
    check parentedDialog.messages[0].moveFollowWindow
    check parentedDialog.messages[1].kind == MsgKind.CmdSetLayout
    check parentedDialog.messages[1].layoutTargetTag == 4
    check parentedDialog.messages[1].newLayout == LayoutMode.Deck
    check parentedDialog.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check parentedDialog.messages[2].floatingWindowId == 19
    check parentedDialog.messages[2].windowFloating

    let ignored = runtime.evalSource(
      testSnapshot(),
      manifest,
      "manifests/vesktop.janet",
      some(ShellWindow(id: 20, title: "Terminal", appId: "kitty")),
    )

    check ignored.ok
    check ignored.messages.len == 0

  test "bundled Telegram manifest targets chat workspace":
    let dir = getTempDir() / ("triad-telegram-manifest-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / "telegram.janet", readFile("manifests/telegram.janet"))
    var config = testConfig(dir)
    config.manifestAliases.add(
      JanetManifestAlias(appId: "org.telegram.desktop", manifest: "telegram")
    )
    config.manifestAliases.add(
      JanetManifestAlias(appId: "TelegramDesktop", manifest: "telegram")
    )

    var runtime = initJanetRuntime(config)
    defer:
      runtime.close()
      if fileExists(dir / "telegram.janet"):
        removeFile(dir / "telegram.janet")
      removeDir(dir)

    let mainWindow = runtime.evalManifestDetailed(
      "org.telegram.desktop",
      testSnapshot(),
      some(ShellWindow(id: 21, title: "Telegram", appId: "org.telegram.desktop")),
    )

    check mainWindow.outcome == ManifestOutcome.Evaluated
    check mainWindow.path == dir / "telegram.janet"
    check mainWindow.messages.len == 4
    check mainWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check mainWindow.messages[0].moveWindowId == 21
    check mainWindow.messages[0].moveTargetTag == 4
    check mainWindow.messages[0].moveFollowWindow
    check mainWindow.messages[1].kind == MsgKind.CmdSetLayout
    check mainWindow.messages[1].layoutTargetTag == 4
    check mainWindow.messages[1].newLayout == LayoutMode.Deck
    check mainWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check mainWindow.messages[2].floatingWindowId == 21
    check not mainWindow.messages[2].windowFloating
    check mainWindow.messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check mainWindow.messages[3].maximizedWindowId == 21
    check mainWindow.messages[3].windowMaximized

    let parentedDialog = runtime.evalManifestDetailed(
      "TelegramDesktop",
      testSnapshot(),
      some(
        ShellWindow(id: 22, parentId: 21, title: "Open File", appId: "TelegramDesktop")
      ),
    )

    check parentedDialog.outcome == ManifestOutcome.Evaluated
    check parentedDialog.path == dir / "telegram.janet"
    check parentedDialog.messages.len == 3
    check parentedDialog.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check parentedDialog.messages[0].moveWindowId == 22
    check parentedDialog.messages[0].moveTargetTag == 4
    check parentedDialog.messages[0].moveFollowWindow
    check parentedDialog.messages[1].kind == MsgKind.CmdSetLayout
    check parentedDialog.messages[1].layoutTargetTag == 4
    check parentedDialog.messages[1].newLayout == LayoutMode.Deck
    check parentedDialog.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check parentedDialog.messages[2].floatingWindowId == 22
    check parentedDialog.messages[2].windowFloating

    let missing = runtime.evalManifestDetailed("kitty", testSnapshot())

    check missing.outcome == ManifestOutcome.Missing
    check missing.messages.len == 0

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
    writeFile(dir / "firefox.janet", """(triad/command "move-to-workspace" 2)""")

    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      removeFile(dir / "firefox.janet")
      removeDir(dir)

    let messages = runtime.evalManifest("firefox", testSnapshot())

    check messages.len == 1
    check messages[0].kind == MsgKind.CmdMoveToWorkspaceIndex
    check messages[0].workspaceIndex == 2

  test "manifest aliases map app ids without overriding exact matches":
    let dir = getTempDir() / ("triad-janet-alias-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "telegram.janet", """(triad/command "move-window-to-tag" 12 4 true)"""
    )
    writeFile(
      dir / "org.telegram.desktop.janet",
      """(triad/command "move-window-to-tag" 12 9 true)""",
    )

    var config = testConfig(dir)
    config.manifestAliases.add(
      JanetManifestAlias(appId: "org.telegram.desktop", manifest: "telegram")
    )
    config.manifestAliases.add(
      JanetManifestAlias(appId: "bad-app", manifest: "../telegram")
    )

    var runtime = initJanetRuntime(config)
    defer:
      runtime.close()
      if fileExists(dir / "telegram.janet"):
        removeFile(dir / "telegram.janet")
      if fileExists(dir / "org.telegram.desktop.janet"):
        removeFile(dir / "org.telegram.desktop.janet")
      removeDir(dir)

    let exact = runtime.evalManifestDetailed("org.telegram.desktop", testSnapshot())
    check exact.outcome == ManifestOutcome.Evaluated
    check exact.path == dir / "org.telegram.desktop.janet"
    check exact.candidatePaths[0] == dir / "org.telegram.desktop.janet"
    check exact.candidatePaths[1] == dir / "telegram.janet"
    check exact.messages.len == 1
    check exact.messages[0].moveTargetTag == 9

    removeFile(dir / "org.telegram.desktop.janet")
    runtime.configure(config)

    let alias = runtime.evalManifestDetailed("org.telegram.desktop", testSnapshot())
    check alias.outcome == ManifestOutcome.Evaluated
    check alias.path == dir / "telegram.janet"
    check alias.messages.len == 1
    check alias.messages[0].moveTargetTag == 4

    let invalidAlias = runtime.evalManifestDetailed("bad-app", testSnapshot())
    check invalidAlias.outcome == ManifestOutcome.Missing
    check invalidAlias.candidatePaths.len == 2

  test "manifest detailed result records lookup outcomes":
    let dir = getTempDir() / ("triad-janet-detail-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / "gimp.janet", """(triad/command "move-window-to-tag" 12 8 true)""")

    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "gimp.janet"):
        removeFile(dir / "gimp.janet")
      removeDir(dir)

    let missing = runtime.evalManifestDetailed("missing", testSnapshot())
    check missing.outcome == ManifestOutcome.Missing
    check missing.candidatePaths.len == 2
    check missing.messages.len == 0

    let invalid = runtime.evalManifestDetailed("../bad", testSnapshot())
    check invalid.outcome == ManifestOutcome.InvalidAppId
    check invalid.candidatePaths.len == 0

    let evaluated = runtime.evalManifestDetailed(
      "gimp", testSnapshot(), some(ShellWindow(id: 12, title: "Toolbox", appId: "gimp"))
    )
    check evaluated.outcome == ManifestOutcome.Evaluated
    check evaluated.path == dir / "gimp.janet"
    check evaluated.currentWindow.isSome
    check evaluated.messages.len == 1
    check evaluated.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check evaluated.messages[0].moveTargetTag == 8

  test "manifest detailed result records eval failures":
    let dir = getTempDir() / ("triad-janet-failure-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / "broken.janet", """(undefined-triad-call)""")

    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "broken.janet"):
        removeFile(dir / "broken.janet")
      removeDir(dir)

    let failed = runtime.evalManifestDetailed("broken", testSnapshot())
    check failed.outcome == ManifestOutcome.EvalFailed
    check failed.error.len > 0
    check failed.messages.len == 0

    let cached = runtime.evalManifestDetailed("broken", testSnapshot())
    check cached.outcome == ManifestOutcome.CachedFailed
    check cached.error.len > 0
