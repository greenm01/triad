import std/[options, os, strutils, unittest]
import ../src/core/msg
import ../src/ipc/commands
import ../src/janet/[runtime, snapshot_api]
import ../src/types/[ipc_commands, janet_manifest, runtime_values, shell_snapshot]

proc testConfig(dir: string): JanetConfig =
  JanetConfig(
    enabled: true,
    scriptDir: dir,
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

proc windowReadyEvent(window: ShellWindow): string =
  "{:kind :window-ready :window-id " & $window.id & " :window " &
    window.janetWindowExpr() & "}"

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

  test "prelude media helpers emit spawn commands":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(triad/spawn "foot" "-e" "htop")
(triad/spawn-sh "notify-send triad")
(triad/volume-up)
(triad/volume-down "10%")
(triad/volume-toggle-mute)
(triad/mic-toggle-mute)
(triad/media-play-pause)
(triad/media-next)
(triad/media-prev)
(triad/media-stop)
(triad/media-seek "+5")
(triad/record-screen "/tmp/triad-screen.mp4")
(triad/record-region "/tmp/triad-region.mp4")
(triad/record-stop)
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 14
    check evaluated.messages[0].kind == MsgKind.CmdSpawn
    check evaluated.messages[0].spawnCommand == @["foot", "-e", "htop"]
    check evaluated.messages[1].spawnCommand == @["sh", "-lc", "notify-send triad"]
    check evaluated.messages[2].spawnCommand ==
      @["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+"]
    check evaluated.messages[3].spawnCommand ==
      @["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "10%-"]
    check evaluated.messages[4].spawnCommand ==
      @["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]
    check evaluated.messages[5].spawnCommand ==
      @["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]
    check evaluated.messages[6].spawnCommand == @["playerctl", "play-pause"]
    check evaluated.messages[7].spawnCommand == @["playerctl", "next"]
    check evaluated.messages[8].spawnCommand == @["playerctl", "previous"]
    check evaluated.messages[9].spawnCommand == @["playerctl", "stop"]
    check evaluated.messages[10].spawnCommand == @["playerctl", "position", "+5"]
    check evaluated.messages[11].spawnCommand ==
      @["wf-recorder", "-f", "/tmp/triad-screen.mp4"]
    check evaluated.messages[12].spawnCommand ==
      @[
        "sh", "-c", "geom=$(slurp) && exec wf-recorder -g \"$geom\" -f \"$1\"",
        "triad-record-region", "/tmp/triad-region.mp4",
      ]
    check evaluated.messages[13].spawnCommand == @["pkill", "-INT", "wf-recorder"]

  test "prelude screenshot helpers emit screenshot commands":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(triad/screenshot "--clipboard-only")
(triad/screenshot-screen "--path" "/tmp/screen.png" "--show-pointer")
(triad/screenshot-window "--no-clipboard")
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 3
    check evaluated.messages[0].kind == MsgKind.CmdScreenshot
    check evaluated.messages[0].screenshotKind == ScreenshotKind.ShotRegion
    check not evaluated.messages[0].screenshotWriteToDisk
    check evaluated.messages[0].screenshotCopyToClipboard
    check evaluated.messages[1].screenshotKind == ScreenshotKind.ShotScreen
    check evaluated.messages[1].screenshotPath == "/tmp/screen.png"
    check evaluated.messages[1].screenshotPointerMode ==
      ScreenshotPointerMode.PointerShow
    check evaluated.messages[2].screenshotKind == ScreenshotKind.ShotWindow
    check evaluated.messages[2].screenshotWriteToDisk
    check not evaluated.messages[2].screenshotCopyToClipboard

  test "prelude does not reopen direct process execution":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(testSnapshot(), """(os/spawn ["foot"])""")

    check not evaluated.ok

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

  test "script files dispatch matching current events in sorted order":
    let dir = getTempDir() / ("triad-janet-scripts-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "b.janet",
      """
(triad/on :window-opened
  (fn [ev]
    (triad/command "move-to-tag" (ev :target-tag))))
""",
    )
    writeFile(
      dir / "a.janet",
      """
(triad/on :window-opened
  (fn [ev]
    (triad/command "focus-window" (ev :window-id))))
(triad/on :window-closed
  (fn [_]
    (triad/command "move-to-tag" 9)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "a.janet"):
        removeFile(dir / "a.janet")
      if fileExists(dir / "b.janet"):
        removeFile(dir / "b.janet")
      if dirExists(dir):
        removeDir(dir)

    let results = runtime.evalScriptsDetailed(
      "window-opened",
      "{:kind :window-opened :window-id 12 :target-tag 2}",
      testSnapshot(),
      some(ShellWindow(id: 12, appId: "gimp")),
    )

    check results.len == 2
    check results[0].path.endsWith("a.janet")
    check results[0].outcome == ScriptOutcome.Evaluated
    check results[0].messages.len == 1
    check results[0].messages[0].kind == MsgKind.CmdFocusWindowById
    check results[0].messages[0].focusWindowId == 12
    check results[1].path.endsWith("b.janet")
    check results[1].messages.len == 1
    check results[1].messages[0].kind == MsgKind.CmdMoveToTag
    check results[1].messages[0].targetTag == 2

  test "missing script directory skips evaluation":
    var runtime = initJanetRuntime(testConfig(getTempDir() / "triad-missing-scripts"))
    defer:
      runtime.close()

    let results = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check results.len == 0

  test "script eval failures are reported and cached until source changes":
    let dir = getTempDir() / ("triad-janet-script-failure-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / "broken.janet", "(undefined-script-call)")
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "broken.janet"):
        removeFile(dir / "broken.janet")
      if dirExists(dir):
        removeDir(dir)

    let failed = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    let cached = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check failed.len == 1
    check failed[0].outcome == ScriptOutcome.EvalFailed
    check failed[0].error.len > 0
    check cached.len == 1
    check cached[0].outcome == ScriptOutcome.CachedFailed

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

  test "bundled GIMP script targets first empty workspace":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()
    let script = readFile("examples/janet/gimp.janet")
    var snapshot = testSnapshot()
    snapshot.workspaces[0].occupied = true
    snapshot.workspaces[1].occupied = true
    snapshot.workspaces.add(
      ShellWorkspace(
        tagId: 3, workspaceIdx: 3, name: "scratch", layoutMode: LayoutMode.Scroller
      )
    )

    let firstPalette = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 12, title: "Toolbox", appId: "gimp", identifier: "toolbox")
        ),
    )

    check firstPalette.ok
    check firstPalette.messages.len == 3
    check firstPalette.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check firstPalette.messages[0].moveTargetTag == 3
    check firstPalette.messages[0].moveFollowWindow
    check firstPalette.messages[1].kind == MsgKind.CmdSetLayout
    check firstPalette.messages[1].layoutTargetTag == 3
    check firstPalette.messages[1].newLayout == LayoutMode.Scroller
    check firstPalette.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check firstPalette.messages[2].floatingWindowId == 12
    check firstPalette.messages[2].windowFloating

    var currentOccupiesTargetSnapshot = snapshot
    currentOccupiesTargetSnapshot.workspaces[2].occupied = true
    currentOccupiesTargetSnapshot.windows.add(
      ShellWindow(
        id: 18,
        title: "GNU Image Manipulation Program",
        appId: "gimp",
        tagId: some(3'u32),
        workspaceIdx: 3,
      )
    )
    let currentOccupiesTarget = runtime.evalSource(
      currentOccupiesTargetSnapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 18, title: "GNU Image Manipulation Program", appId: "gimp")
        ),
    )

    check currentOccupiesTarget.ok
    check currentOccupiesTarget.messages.len == 4
    check currentOccupiesTarget.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check currentOccupiesTarget.messages[0].moveTargetTag == 3

    let mainWindow = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 13, title: "GNU Image Manipulation Program", appId: "gimp-3.2")
        ),
    )

    check mainWindow.ok
    check mainWindow.messages.len == 4
    check mainWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check mainWindow.messages[0].moveTargetTag == 3
    check mainWindow.messages[0].moveFollowWindow
    check mainWindow.messages[1].kind == MsgKind.CmdSetLayout
    check mainWindow.messages[1].layoutTargetTag == 3
    check mainWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check mainWindow.messages[2].floatingWindowId == 13
    check not mainWindow.messages[2].windowFloating
    check mainWindow.messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check mainWindow.messages[3].maximizedWindowId == 13
    check mainWindow.messages[3].windowMaximized

    let laterPalette = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 14, title: "Tool Options", appId: "org.gimp.GIMP")
        ),
    )

    check laterPalette.ok
    check laterPalette.messages.len == 3
    check laterPalette.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check laterPalette.messages[0].moveTargetTag == 3
    check not laterPalette.messages[0].moveFollowWindow
    check laterPalette.messages[1].kind == MsgKind.CmdSetLayout
    check laterPalette.messages[1].layoutTargetTag == 3
    check laterPalette.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check laterPalette.messages[2].floatingWindowId == 14
    check laterPalette.messages[2].windowFloating

    var existingGimpSnapshot = snapshot
    existingGimpSnapshot.workspaces.add(
      ShellWorkspace(
        tagId: 4, workspaceIdx: 4, name: "gimp", layoutMode: LayoutMode.Scroller
      )
    )
    existingGimpSnapshot.workspaces.add(
      ShellWorkspace(
        tagId: 5, workspaceIdx: 5, name: "empty", layoutMode: LayoutMode.Scroller
      )
    )
    existingGimpSnapshot.windows.add(
      ShellWindow(
        id: 19,
        title: "GNU Image Manipulation Program",
        appId: "gimp",
        tagId: some(4'u32),
        workspaceIdx: 4,
      )
    )
    let welcomeWindow = runtime.evalSource(
      existingGimpSnapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 20, title: "Welcome to GIMP", appId: "gimp-3.2")
        ),
    )

    check welcomeWindow.ok
    check welcomeWindow.messages.len == 3
    check welcomeWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check welcomeWindow.messages[0].moveTargetTag == 4

    let dialogWindow = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(ShellWindow(id: 15, title: "Preferences", appId: "gimp")),
    )

    check dialogWindow.ok
    check dialogWindow.messages.len == 3
    check dialogWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check dialogWindow.messages[0].moveTargetTag == 3
    check dialogWindow.messages[0].moveFollowWindow
    check dialogWindow.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check dialogWindow.messages[2].floatingWindowId == 15
    check dialogWindow.messages[2].windowFloating

    let parentedDialog = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(
          ShellWindow(id: 16, parentId: 13, title: "Untitled", appId: "gimp")
        ),
    )

    check parentedDialog.ok
    check parentedDialog.messages.len == 3
    check parentedDialog.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check parentedDialog.messages[0].moveTargetTag == 3
    check parentedDialog.messages[0].moveFollowWindow
    check parentedDialog.messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check parentedDialog.messages[2].floatingWindowId == 16
    check parentedDialog.messages[2].windowFloating

    let ignored = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent =
        windowReadyEvent(ShellWindow(id: 17, title: "Terminal", appId: "kitty")),
    )

    check ignored.ok
    check ignored.messages.len == 0

  test "bundled Vesktop script targets chat workspace":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()
    let script = readFile("examples/janet/vesktop.janet")

    let mainWindow = runtime.evalSource(
      testSnapshot(),
      script,
      "examples/janet/vesktop.janet",
      currentEvent =
        windowReadyEvent(ShellWindow(id: 18, title: "Discord", appId: "vesktop")),
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
      script,
      "examples/janet/vesktop.janet",
      currentEvent =
        windowReadyEvent(
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
      script,
      "examples/janet/vesktop.janet",
      currentEvent =
        windowReadyEvent(ShellWindow(id: 20, title: "Terminal", appId: "kitty")),
    )

    check ignored.ok
    check ignored.messages.len == 0

  test "bundled Telegram script targets chat workspace":
    let dir = getTempDir() / ("triad-telegram-script-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(dir / "telegram.janet", readFile("examples/janet/telegram.janet"))
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "telegram.janet"):
        removeFile(dir / "telegram.janet")
      removeDir(dir)

    let results = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 21, title: "Telegram", appId: "org.telegram.desktop")),
      testSnapshot(),
      some(ShellWindow(id: 21, title: "Telegram", appId: "org.telegram.desktop")),
    )

    check results.len == 1
    check results[0].outcome == ScriptOutcome.Evaluated
    check results[0].messages.len == 4
    check results[0].messages[0].kind == MsgKind.CmdMoveWindowToTag
    check results[0].messages[0].moveWindowId == 21
    check results[0].messages[0].moveTargetTag == 4
    check results[0].messages[0].moveFollowWindow
    check results[0].messages[1].kind == MsgKind.CmdSetLayout
    check results[0].messages[1].layoutTargetTag == 4
    check results[0].messages[1].newLayout == LayoutMode.Deck
    check results[0].messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check results[0].messages[2].floatingWindowId == 21
    check not results[0].messages[2].windowFloating
    check results[0].messages[3].kind == MsgKind.CmdSetWindowMaximizedById
    check results[0].messages[3].maximizedWindowId == 21
    check results[0].messages[3].windowMaximized

    let dialogResults = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(
        ShellWindow(id: 22, parentId: 21, title: "Open File", appId: "TelegramDesktop")
      ),
      testSnapshot(),
      some(
        ShellWindow(id: 22, parentId: 21, title: "Open File", appId: "TelegramDesktop")
      ),
    )

    check dialogResults.len == 1
    check dialogResults[0].outcome == ScriptOutcome.Evaluated
    check dialogResults[0].messages.len == 3
    check dialogResults[0].messages[0].kind == MsgKind.CmdMoveWindowToTag
    check dialogResults[0].messages[0].moveWindowId == 22
    check dialogResults[0].messages[0].moveTargetTag == 4
    check dialogResults[0].messages[1].kind == MsgKind.CmdSetLayout
    check dialogResults[0].messages[2].kind == MsgKind.CmdSetWindowFloatingById
    check dialogResults[0].messages[2].floatingWindowId == 22
    check dialogResults[0].messages[2].windowFloating

    let missedResults = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 23, title: "Terminal", appId: "kitty")),
      testSnapshot(),
      some(ShellWindow(id: 23, title: "Terminal", appId: "kitty")),
    )

    check missedResults.len == 1
    check missedResults[0].outcome == ScriptOutcome.Evaluated
    check missedResults[0].messages.len == 0

  test "window-ready event fires once via evalScriptsDetailed":
    let dir = getTempDir() / ("triad-window-ready-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "placer.janet",
      """
(triad/on :window-ready
  (fn [ev]
    (triad/command "focus-window" ((ev :window) :id))))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "placer.janet"):
        removeFile(dir / "placer.janet")
      if dirExists(dir):
        removeDir(dir)

    let win = ShellWindow(id: 42, title: "App", appId: "myapp")
    let results = runtime.evalScriptsDetailed(
      "window-ready", windowReadyEvent(win), testSnapshot(), some(win)
    )

    check results.len == 1
    check results[0].outcome == ScriptOutcome.Evaluated
    check results[0].messages.len == 1
    check results[0].messages[0].kind == MsgKind.CmdFocusWindowById
    check results[0].messages[0].focusWindowId == 42

    let closedResults = runtime.evalScriptsDetailed(
      "window-closed",
      "{:kind :window-closed :window-id 42 :window " & win.janetWindowExpr() & "}",
      testSnapshot(),
      some(win),
    )

    check closedResults.len == 1
    check closedResults[0].outcome == ScriptOutcome.Evaluated
    check closedResults[0].messages.len == 0

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
