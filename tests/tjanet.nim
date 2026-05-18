import std/[json, options, os, strutils, tables, unittest]
import ../src/core/msg
import ../src/daemon/janet_script_runtime
from ../src/daemon/state import QueuedMsgOrigin, TriadDaemon, initTriadDaemon
import ../src/ipc/commands
import ../src/janet/[bundled_layouts, layout_api, runtime, snapshot_api]
import
  ../src/types/[
    ipc_commands, janet_layouts, janet_manifest, projection_values, runtime_values,
    shell_snapshot,
  ]
import ../src/utils/behavior_log

proc testConfig(dir: string): JanetConfig =
  JanetConfig(
    enabled: true, automationDir: dir, layoutDir: dir / "layouts", fuelLimit: 500000
  )

proc testConfigFuel(dir: string, fuelLimit: int32): JanetConfig =
  JanetConfig(
    enabled: true, automationDir: dir, layoutDir: dir / "layouts", fuelLimit: fuelLimit
  )

proc restoreEnv(name, value: string) =
  putEnv(name, value)

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
    outputs:
      @[
        ShellOutput(
          id: 1,
          name: "HDMI-A-1",
          w: 1920,
          h: 1080,
          refreshRate: 144000,
          isPrimary: true,
        )
      ],
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

proc baseUiHookState(): JanetUiHookState =
  JanetUiHookState(
    recentWindowsScope: RecentWindowScope.All,
    recentWindowsFilter: RecentWindowFilter.All,
    layoutSwitchToastLayout: LayoutMode.Scroller,
  )

proc testLayoutContext(): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  windows[10'u32] = ProjectedWindow(id: 10, title: "Terminal", appId: "kitty")
  windows[11'u32] = ProjectedWindow(id: 11, title: "Browser", appId: "firefox")
  JanetLayoutContext(
    layoutId: janetLayoutId("halves"),
    screen: Rect(x: 0, y: 0, w: 1000, h: 800),
    outerGap: 0,
    innerGap: 0,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 10,
      columns: @[ProjectedColumn(windows: @[10'u32, 11'u32])],
    ),
    windows: windows,
  )

proc spiralLayoutContext(
    count: int, ratio = 0.5'f32, mainPane = "left", clockwise = true
): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  var ids: seq[ProjectionWindowId] = @[]
  for i in 0 ..< count:
    let id = ProjectionWindowId(10'u32 + uint32(i))
    ids.add(id)
    windows[id] = ProjectedWindow(id: id, title: "Window " & $uint32(id), appId: "test")
  JanetLayoutContext(
    layoutId: janetLayoutId("spiral"),
    screen: Rect(x: 0, y: 0, w: 1000, h: 800),
    outerGap: 0,
    innerGap: 0,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 10,
      columns: @[ProjectedColumn(windows: ids)],
    ),
    windows: windows,
    spiral: SpiralLayoutConfig(
      ratio: ratio,
      mainPaneRatioSet: false,
      mainPaneRatio: ratio,
      mainPane: mainPane,
      clockwiseSet: true,
      clockwise: clockwise,
    ),
  )

proc testFrameLayoutContext(): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  windows[10'u32] = ProjectedWindow(id: 10, title: "Terminal", appId: "kitty")
  windows[11'u32] = ProjectedWindow(id: 11, title: "Browser", appId: "firefox")
  JanetLayoutContext(
    layoutId: janetLayoutId("frame-aware"),
    screen: Rect(x: 0, y: 0, w: 1000, h: 800),
    outerGap: 0,
    innerGap: 0,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 10,
      columns: @[ProjectedColumn(windows: @[10'u32, 11'u32])],
      frames:
        @[
          ProjectedFrame(
            id: 1,
            kind: FrameNodeKind.Split,
            firstChild: 2,
            secondChild: 3,
            orientation: FrameSplitOrientation.Horizontal,
            ratio: 0.5,
          ),
          ProjectedFrame(
            id: 2,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            windows: @[10'u32, 11'u32],
            activeWindow: 11,
            focused: true,
            rectSet: true,
            rect: Rect(x: 0, y: 0, w: 500, h: 800),
          ),
          ProjectedFrame(
            id: 3,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            rectSet: true,
            rect: Rect(x: 500, y: 0, w: 500, h: 800),
          ),
        ],
    ),
    windows: windows,
  )

proc notionTwoPaneContext(): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  windows[10'u32] = ProjectedWindow(id: 10, title: "Terminal", appId: "kitty")
  windows[11'u32] = ProjectedWindow(id: 11, title: "Browser", appId: "firefox")
  JanetLayoutContext(
    layoutId: janetLayoutId("notion"),
    screen: Rect(x: 0, y: 0, w: 1920, h: 1080),
    outerGap: 0,
    innerGap: 4,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 10,
      columns: @[ProjectedColumn(windows: @[10'u32, 11'u32])],
      frames:
        @[
          ProjectedFrame(
            id: 1,
            kind: FrameNodeKind.Split,
            firstChild: 2,
            secondChild: 3,
            orientation: FrameSplitOrientation.Horizontal,
            ratio: 0.5,
          ),
          ProjectedFrame(
            id: 2,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            windows: @[10'u32],
            activeWindow: 10,
          ),
          ProjectedFrame(
            id: 3,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            windows: @[11'u32],
            activeWindow: 11,
          ),
        ],
    ),
    windows: windows,
  )

proc bspTwoPaneContext(): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  windows[10'u32] = ProjectedWindow(id: 10, title: "Terminal", appId: "kitty")
  windows[11'u32] = ProjectedWindow(id: 11, title: "Browser", appId: "firefox")
  JanetLayoutContext(
    layoutId: janetLayoutId("bsp"),
    screen: Rect(x: 0, y: 0, w: 1000, h: 800),
    outerGap: 10,
    innerGap: 4,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 11,
      columns: @[ProjectedColumn(windows: @[10'u32, 11'u32])],
      bspNodes:
        @[
          ProjectedBspNode(
            id: 1,
            kind: FrameNodeKind.Split,
            firstChild: 2,
            secondChild: 3,
            orientation: FrameSplitOrientation.Horizontal,
            ratio: 0.5,
          ),
          ProjectedBspNode(id: 2, kind: FrameNodeKind.Leaf, parent: 1, window: 10),
          ProjectedBspNode(
            id: 3,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            window: 11,
            focused: true,
            hasPreselection: true,
            preselectDirection: Direction.DirDown,
            preselectRatio: 0.4'f32,
          ),
        ],
    ),
    windows: windows,
  )

proc notionNestedContext(): JanetLayoutContext =
  var windows = initTable[ProjectionWindowId, ProjectedWindow]()
  windows[10'u32] = ProjectedWindow(id: 10, title: "Editor", appId: "kitty")
  windows[11'u32] = ProjectedWindow(id: 11, title: "Browser", appId: "firefox")
  windows[12'u32] = ProjectedWindow(id: 12, title: "Logs", appId: "kitty")
  JanetLayoutContext(
    layoutId: janetLayoutId("notion"),
    screen: Rect(x: 0, y: 0, w: 1000, h: 800),
    outerGap: 0,
    innerGap: 10,
    tag: ProjectedTag(
      tagId: 1,
      name: "term",
      focusedWindow: 10,
      columns: @[ProjectedColumn(windows: @[10'u32, 11'u32, 12'u32])],
      frames:
        @[
          ProjectedFrame(
            id: 1,
            kind: FrameNodeKind.Split,
            firstChild: 2,
            secondChild: 3,
            orientation: FrameSplitOrientation.Horizontal,
            ratio: 0.6,
          ),
          ProjectedFrame(
            id: 2,
            kind: FrameNodeKind.Leaf,
            parent: 1,
            windows: @[10'u32],
            activeWindow: 10,
          ),
          ProjectedFrame(
            id: 3,
            kind: FrameNodeKind.Split,
            parent: 1,
            firstChild: 4,
            secondChild: 5,
            orientation: FrameSplitOrientation.Vertical,
            ratio: 0.25,
          ),
          ProjectedFrame(
            id: 4,
            kind: FrameNodeKind.Leaf,
            parent: 3,
            windows: @[11'u32],
            activeWindow: 11,
          ),
          ProjectedFrame(
            id: 5,
            kind: FrameNodeKind.Leaf,
            parent: 3,
            windows: @[12'u32],
            activeWindow: 12,
          ),
        ],
    ),
    windows: windows,
  )

proc hasInstruction(
    instructions: openArray[RenderInstruction], windowId: ProjectionWindowId, geom: Rect
): bool =
  for instruction in instructions:
    if instruction.windowId == windowId and instruction.geom == geom:
      return true
  false

proc expectUiHookFocusTag(
    daemon: var TriadDaemon, before, after: JanetUiHookState, expectedTag: uint32
) =
  let messages = daemon.collectJanetUiScriptMessages(before, after, testSnapshot())
  check messages.len == 1
  if messages.len > 0:
    check messages[0].origin == QueuedMsgOrigin.JanetHook
    check messages[0].msg.kind == MsgKind.CmdFocusTag
    check messages[0].msg.focusTag == expectedTag

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
    check evaluated.messages[1].kind == MsgKind.CmdSetCustomLayout
    check evaluated.messages[1].customLayout.layoutIdString() == "grid"
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

  test "custom Janet layout returns validated geometry":
    let dir = getTempDir() / ("triad-janet-layout-valid-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :halves
  (fn [ctx]
    [{:window-id 10 :x 0 :y 0 :w 500 :h 800}
     {:window-id 11 :x 500 :y 0 :w 500 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), testLayoutContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.fallbackReason.len == 0
    check evaluated.instructions.len == 2
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 0, y: 0, w: 500, h: 800)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 500, y: 0, w: 500, h: 800)

  test "bundled Janet layouts apply with user scripting disabled":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    var context = testLayoutContext()
    context.layoutId = janetLayoutId("grid")
    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), context)

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == bundledLayoutPath("grid")
    check evaluated.fallbackReason.len == 0
    check evaluated.instructions.len == 2
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 0, y: 0, w: 500, h: 800)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 500, y: 0, w: 500, h: 800)
    check runtime.scripts.hasKey(bundledLayoutPath("grid"))
    check not runtime.scripts.hasKey(bundledLayoutPath("tile"))

  test "bundled spiral Janet layout computes clockwise recursive geometry":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), spiralLayoutContext(5))

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == bundledLayoutPath("spiral")
    check evaluated.instructions.len == 5
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 0, y: 0, w: 500, h: 800)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 500, y: 0, w: 500, h: 400)
    check evaluated.instructions[2].windowId == 12'u32
    check evaluated.instructions[2].geom == Rect(x: 750, y: 400, w: 250, h: 400)
    check evaluated.instructions[3].windowId == 13'u32
    check evaluated.instructions[3].geom == Rect(x: 500, y: 600, w: 250, h: 200)
    check evaluated.instructions[4].windowId == 14'u32
    check evaluated.instructions[4].geom == Rect(x: 500, y: 400, w: 250, h: 200)

  test "bundled spiral Janet layout honors main pane and direction options":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    let top = runtime.evalLayoutDetailed(
      testSnapshot(), spiralLayoutContext(3, mainPane = "top")
    )
    check top.outcome == JanetLayoutOutcome.Applied
    check top.instructions[0].geom == Rect(x: 0, y: 0, w: 1000, h: 400)
    check top.instructions[1].geom == Rect(x: 500, y: 400, w: 500, h: 400)
    check top.instructions[2].geom == Rect(x: 0, y: 400, w: 500, h: 400)

    let anticlockwise = runtime.evalLayoutDetailed(
      testSnapshot(), spiralLayoutContext(3, clockwise = false)
    )
    check anticlockwise.outcome == JanetLayoutOutcome.Applied
    check anticlockwise.instructions[0].geom == Rect(x: 0, y: 0, w: 500, h: 800)
    check anticlockwise.instructions[1].geom == Rect(x: 500, y: 400, w: 500, h: 400)
    check anticlockwise.instructions[2].geom == Rect(x: 500, y: 0, w: 500, h: 400)

  test "bundled algorithmic Janet layouts do not expose movement hooks":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    proc movement(
        layoutId: string, direction: Direction
    ): JanetLayoutMovementEvalResult =
      var context = testLayoutContext()
      context.layoutId = janetLayoutId(layoutId)
      runtime.evalLayoutMovementDetailed(testSnapshot(), context, direction)

    proc checkNoHook(layoutId: string, direction: Direction) =
      let evaluated = movement(layoutId, direction)
      check not evaluated.handled
      check not evaluated.ok
      check evaluated.path == ""
      check evaluated.op == JanetLayoutMovementOp.None

    for layoutId in [
      "tile", "right-tile", "center-tile", "spiral", "vertical-grid", "vertical-tile",
      "grid",
    ]:
      checkNoHook(layoutId, Direction.DirUp)
      checkNoHook(layoutId, Direction.DirDown)
      checkNoHook(layoutId, Direction.DirLeft)
      checkNoHook(layoutId, Direction.DirRight)

  test "bundled non-flat Janet layouts do not expose movement hooks":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    for layoutId in [
      "deck", "vertical-deck", "monocle", "notion", "bsp", "dwindle", "tgmix"
    ]:
      var context = testLayoutContext()
      context.layoutId = janetLayoutId(layoutId)
      let evaluated =
        runtime.evalLayoutMovementDetailed(testSnapshot(), context, Direction.DirUp)
      check not evaluated.handled
      check not evaluated.ok
      check evaluated.op == JanetLayoutMovementOp.None

  test "Janet layout movement hook is optional":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    let evaluated = runtime.evalLayoutMovementDetailed(
      testSnapshot(), testLayoutContext(), Direction.DirUp
    )

    check not evaluated.handled
    check not evaluated.ok
    check evaluated.op == JanetLayoutMovementOp.None

  test "Janet layout movement rejects commands and invalid results":
    let dir =
      getTempDir() / ("triad-janet-layout-movement-bad-" & $getCurrentProcessId())
    let layoutDir = dir / "layouts"
    createDir(dir)
    createDir(layoutDir)
    writeFile(
      layoutDir / "bad-command.janet",
      """
(triad/def-layout :bad-command
  (fn [ctx]
    []))
(triad/def-layout-movement :bad-command
  (fn [ctx direction]
    (triad/command "layout-grid")
    {:op :noop}))
""",
    )
    writeFile(
      layoutDir / "bad-delta.janet",
      """
(triad/def-layout :bad-delta
  (fn [ctx]
    []))
(triad/def-layout-movement :bad-delta
  (fn [ctx direction]
    {:op :move-order :delta 2}))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(layoutDir / "bad-command.janet"):
        removeFile(layoutDir / "bad-command.janet")
      if fileExists(layoutDir / "bad-delta.janet"):
        removeFile(layoutDir / "bad-delta.janet")
      if dirExists(layoutDir):
        removeDir(layoutDir)
      if dirExists(dir):
        removeDir(dir)

    var commandContext = testLayoutContext()
    commandContext.layoutId = janetLayoutId("bad-command")
    let commandResult = runtime.evalLayoutMovementDetailed(
      testSnapshot(), commandContext, Direction.DirUp
    )
    check commandResult.handled
    check not commandResult.ok
    check commandResult.error.contains("emitted Triad commands")

    var deltaContext = testLayoutContext()
    deltaContext.layoutId = janetLayoutId("bad-delta")
    let deltaResult = runtime.evalLayoutMovementDetailed(
      testSnapshot(), deltaContext, Direction.DirDown
    )
    check deltaResult.handled
    check not deltaResult.ok
    check deltaResult.error.len > 0

  test "declared Janet layouts load from layout dir by id":
    let dir = getTempDir() / ("triad-janet-layout-dir-" & $getCurrentProcessId())
    let automationDir = dir / "automation"
    let layoutDir = dir / "layouts"
    createDir(dir)
    createDir(automationDir)
    createDir(layoutDir)
    writeFile(
      layoutDir / "halves.janet",
      """
(triad/def-layout :halves
  (fn [ctx]
    [{:window-id 10 :x 0 :y 0 :w 500 :h 800}
     {:window-id 11 :x 500 :y 0 :w 500 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: true,
        automationDir: automationDir,
        layoutDir: layoutDir,
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()
      if dirExists(dir):
        removeDir(dir)

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), testLayoutContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == layoutDir / "halves.janet"
    check evaluated.instructions.len == 2

  test "frame-aware Janet layout returns frame geometry":
    let dir = getTempDir() / ("triad-janet-layout-frame-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :frame-aware
  (fn [ctx]
    [{:frame-id 2 :x 10 :y 20 :w 300 :h 400}
     {:frame-id 3 :x 320 :y 20 :w 300 :h 400}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), testFrameLayoutContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.outputTargetKind == JanetLayoutTargetKind.Frame
    check evaluated.inputFrameCount == 2
    check evaluated.instructionCount == 2
    check evaluated.instructions.len == 1
    check evaluated.frameInstructions.len == 2
    check evaluated.instructions[0].windowId == 11'u32
    check evaluated.instructions[0].geom == Rect(x: 10, y: 20, w: 300, h: 400)

  test "bundled notion Janet layout computes horizontal frame split geometry":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), notionTwoPaneContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == bundledLayoutPath("notion")
    check evaluated.outputTargetKind == JanetLayoutTargetKind.Frame
    check evaluated.inputFrameCount == 2
    check evaluated.instructionCount == 2
    check evaluated.instructions.len == 2
    check evaluated.frameInstructions.len == 2
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 0, y: 0, w: 958, h: 1080)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 962, y: 0, w: 958, h: 1080)

  test "bundled notion Janet layout computes nested frame split geometry":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), notionNestedContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.outputTargetKind == JanetLayoutTargetKind.Frame
    check evaluated.inputFrameCount == 3
    check evaluated.instructionCount == 3
    check evaluated.instructions.len == 3
    check evaluated.frameInstructions.len == 3
    check evaluated.instructions.hasInstruction(
      10'u32, Rect(x: 0, y: 0, w: 594, h: 800)
    )
    check evaluated.instructions.hasInstruction(
      11'u32, Rect(x: 604, y: 0, w: 396, h: 197)
    )
    check evaluated.instructions.hasInstruction(
      12'u32, Rect(x: 604, y: 207, w: 396, h: 593)
    )

  test "bundled bsp Janet layout computes native BSP geometry":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), bspTwoPaneContext())

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == bundledLayoutPath("bsp")
    check evaluated.outputTargetKind == JanetLayoutTargetKind.BspNode
    check evaluated.inputBspNodeCount == 2
    check evaluated.instructionCount == 2
    check evaluated.instructions.len == 2
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 10, y: 10, w: 488, h: 780)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 502, y: 10, w: 488, h: 780)

  test "bundled dwindle Janet layout uses native BSP geometry":
    var runtime = initJanetRuntime(
      JanetConfig(
        enabled: false,
        automationDir: getTempDir() / "triad-unused-janet-dir",
        layoutDir: getTempDir() / "triad-unused-layout-dir",
        fuelLimit: 500000,
      )
    )
    defer:
      runtime.close()

    var context = bspTwoPaneContext()
    context.layoutId = janetLayoutId("dwindle")
    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), context)

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.path == bundledLayoutPath("dwindle")
    check evaluated.outputTargetKind == JanetLayoutTargetKind.BspNode
    check evaluated.inputBspNodeCount == 2
    check evaluated.instructionCount == 2
    check evaluated.instructions.len == 2
    check evaluated.instructions[0].windowId == 10'u32
    check evaluated.instructions[0].geom == Rect(x: 10, y: 10, w: 488, h: 780)
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 502, y: 10, w: 488, h: 780)

  test "Janet layout receives BSP preselection fields":
    let dir =
      getTempDir() / ("triad-janet-layout-bsp-preselect-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :bsp-probe
  (fn [ctx]
    (def node ((ctx :bsp-nodes) 2))
    (if (and (= (node :preselect-direction) :down)
             (= (node :preselect-ratio) 0.4))
      [{:bsp-node-id 2 :x 10 :y 10 :w 200 :h 400}
       {:bsp-node-id 3 :x 1 :y 2 :w 300 :h 400}]
      [])))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    var context = bspTwoPaneContext()
    context.layoutId = janetLayoutId("bsp-probe")
    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), context)

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.instructions.len == 2
    check evaluated.instructions[1].windowId == 11'u32
    check evaluated.instructions[1].geom == Rect(x: 1, y: 2, w: 300, h: 400)

  test "frame substrate window output validates active tabs only":
    let dir =
      getTempDir() / ("triad-janet-layout-frame-window-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :frame-aware
  (fn [ctx]
    [{:window-id 11 :x 0 :y 0 :w 1000 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    var evaluated = runtime.evalLayoutDetailed(testSnapshot(), testFrameLayoutContext())
    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.outputTargetKind == JanetLayoutTargetKind.Window
    check evaluated.instructions.len == 1
    check evaluated.instructions[0].windowId == 11'u32

  test "frame-aware Janet layout handles 25 frame workspace and logs evidence":
    let dir =
      getTempDir() / ("triad-janet-layout-frame-budget-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :frame-aware
  (fn [ctx]
    (def instructions @[])
    (each frame ((ctx :tag) :frames)
      (when (= (frame :kind) :leaf)
        (def rect (frame :rect))
        (array/push instructions
          {:frame-id (frame :id)
           :x (rect :x)
           :y (rect :y)
           :w (rect :w)
           :h (rect :h)})))
    instructions))
""",
    )
    var windows = initTable[ProjectionWindowId, ProjectedWindow]()
    var frames: seq[ProjectedFrame] = @[]
    for idx in 0 ..< 25:
      let winId = uint32(100 + idx)
      let frameId = uint32(idx + 1)
      windows[winId] = ProjectedWindow(id: winId, title: "win-" & $idx)
      frames.add(
        ProjectedFrame(
          id: frameId,
          kind: FrameNodeKind.Leaf,
          windows: @[winId],
          activeWindow: winId,
          rectSet: true,
          rect: Rect(x: int32(idx * 10), y: 0, w: 10, h: 20),
        )
      )
    let context = JanetLayoutContext(
      layoutId: janetLayoutId("frame-aware"),
      screen: Rect(x: 0, y: 0, w: 1000, h: 800),
      tag: ProjectedTag(tagId: 1, frames: frames),
      windows: windows,
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), context)

    check evaluated.outcome == JanetLayoutOutcome.Applied
    check evaluated.outputTargetKind == JanetLayoutTargetKind.Frame
    check evaluated.inputFrameCount == 25
    check evaluated.instructionCount == 25
    check evaluated.instructions.len == 25

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["input_frames"].getInt() == 25
    check event["substrate"].getStr() == "frames"
    check event["output_target"].getStr() == "Frame"

  test "frame instruction validation rejects invalid frame outputs":
    let context = testFrameLayoutContext()

    var validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Frame,
          targetId: 1,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        )
      ]
    )
    check not validation.ok
    check validation.error.contains("unknown leaf frame")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Frame,
          targetId: 2,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Window,
          targetId: 11,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
      ]
    )
    check not validation.ok
    check validation.error.contains("mixed")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Frame,
          targetId: 2,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        )
      ]
    )
    check not validation.ok
    check validation.error.contains("omitted frame")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Frame,
          targetId: 2,
          geom: Rect(x: 0, y: 0, w: 0, h: 100),
        ),
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Frame,
          targetId: 3,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
      ]
    )
    check not validation.ok
    check validation.error.contains("non-positive")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Window,
          targetId: 10,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        )
      ]
    )
    check not validation.ok
    check validation.error.contains("unknown tiled window")

  test "BSP instruction validation rejects invalid BSP outputs":
    let context = bspTwoPaneContext()

    var validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.BspNode,
          targetId: 1,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        )
      ]
    )
    check not validation.ok
    check validation.error.contains("unknown leaf BSP node")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.BspNode,
          targetId: 2,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        )
      ]
    )
    check not validation.ok
    check validation.error.contains("omitted BSP node")

    validation = context.validateLayoutInstructions(
      @[
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.BspNode,
          targetId: 2,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
        JanetLayoutInstruction(
          targetKind: JanetLayoutTargetKind.Window,
          targetId: 11,
          geom: Rect(x: 0, y: 0, w: 100, h: 100),
        ),
      ]
    )
    check not validation.ok
    check validation.error.contains("mixed")

  test "custom Janet layout validation rejects incomplete geometry":
    let dir = getTempDir() / ("triad-janet-layout-invalid-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :halves
  (fn [ctx]
    [{:window-id 10 :x 0 :y 0 :w 1000 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), testLayoutContext())

    check evaluated.outcome == JanetLayoutOutcome.Invalid
    check evaluated.instructions.len == 0
    check evaluated.fallbackReason.contains("omitted tiled window")

  test "custom Janet layout functions cannot emit commands":
    let dir = getTempDir() / ("triad-janet-layout-command-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :halves
  (fn [ctx]
    (triad/command "focus-tag" 2)
    [{:window-id 10 :x 0 :y 0 :w 500 :h 800}
     {:window-id 11 :x 500 :y 0 :w 500 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    let evaluated = runtime.evalLayoutDetailed(testSnapshot(), testLayoutContext())

    check evaluated.outcome == JanetLayoutOutcome.EvalFailed
    check evaluated.error.contains("emitted Triad commands")

  test "custom Janet layout evaluation records behavior evidence":
    let dir = getTempDir() / ("triad-janet-layout-log-" & $getCurrentProcessId())
    let oldEnabled = getEnv("TRIAD_BEHAVIOR_LOG", "")
    let oldDir = getEnv("TRIAD_BEHAVIOR_LOG_DIR", "")
    createDir(dir)
    writeFile(
      dir / "layout.janet",
      """
(triad/def-layout :halves
  (fn [ctx]
    [{:window-id 10 :x 0 :y 0 :w 500 :h 800}
     {:window-id 11 :x 500 :y 0 :w 500 :h 800}]))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      restoreEnv("TRIAD_BEHAVIOR_LOG", oldEnabled)
      restoreEnv("TRIAD_BEHAVIOR_LOG_DIR", oldDir)
      if fileExists(dir / "layout.janet"):
        removeFile(dir / "layout.janet")
      if dirExists(dir):
        removeDir(dir)

    putEnv("TRIAD_BEHAVIOR_LOG", "1")
    putEnv("TRIAD_BEHAVIOR_LOG_DIR", dir)
    discard runtime.evalLayoutDetailed(testSnapshot(), testLayoutContext())

    let lines = readFile(behaviorLogPath()).strip().splitLines()
    check lines.len == 1
    let event = parseJson(lines[0])
    check event["event"].getStr() == "janet_layout_eval"
    check event["layout_id"].getStr() == "halves"
    check event["outcome"].getStr() == "Applied"
    check event["input_windows"].getInt() == 2
    check event["input_frames"].getInt() == 0
    check event["substrate"].getStr() == "columns"
    check event["output_target"].getStr() == "Window"
    check event["instructions"].getInt() == 2

  test "snapshot query helpers expose current state":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()
    var snapshot = testSnapshot()
    snapshot.workspaces.add(
      ShellWorkspace(
        tagId: 3, workspaceIdx: 3, name: "empty", layoutMode: LayoutMode.Monocle
      )
    )

    let evaluated = runtime.evalSource(
      snapshot,
      """
(let [web (triad/find-tag-by-name "web")
      by-tag (triad/workspace-by-tag 2)
      empty (triad/workspace-by-index 3)
      current (triad/current-workspace)
      output (triad/output-by-name "HDMI-A-1")
      firefox (triad/windows-by-app-id "firefox")
      first-empty (triad/first-empty-workspace 0)]
  (when (and (= (web :tag-id) (by-tag :tag-id))
             (= (current :tag-id) 1)
             (= (output :name) "HDMI-A-1")
             (= (output :refresh-rate) 144000)
             (= (length firefox) 1)
             (not (triad/workspace-empty? current 0))
             (triad/workspace-empty? empty 0)
             (= (first-empty :tag-id) 3))
    (triad/command "focus-tag" (web :tag-id))
    (triad/command "move-to-tag" ((firefox 0) :tag-id))
    (triad/command "set-layout-for-workspace" (first-empty :tag-id) "grid")))
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 3
    check evaluated.messages[0].kind == MsgKind.CmdFocusTag
    check evaluated.messages[0].focusTag == 2
    check evaluated.messages[1].kind == MsgKind.CmdMoveToTag
    check evaluated.messages[1].targetTag == 2
    check evaluated.messages[2].kind == MsgKind.CmdSetCustomLayout
    check evaluated.messages[2].customLayoutTargetTag == 3
    check evaluated.messages[2].customLayout.layoutIdString() == "grid"

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

  test "script hooks keep state across events without top-level commands":
    let dir = getTempDir() / ("triad-persistent-hooks-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "counter.janet",
      """
(var seen 0)
(triad/command "focus-tag" 9)
(triad/on :window-opened
  (fn [_]
    (set seen (+ seen 1))
    (triad/command "focus-tag" seen)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "counter.janet"):
        removeFile(dir / "counter.janet")
      if dirExists(dir):
        removeDir(dir)

    let first = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    let second = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check first.len == 1
    check first[0].outcome == ScriptOutcome.Evaluated
    check first[0].messages.len == 1
    check first[0].messages[0].kind == MsgKind.CmdFocusTag
    check first[0].messages[0].focusTag == 1
    check second.len == 1
    check second[0].messages.len == 1
    check second[0].messages[0].kind == MsgKind.CmdFocusTag
    check second[0].messages[0].focusTag == 2

  test "script hooks reload on source changes and evict deleted scripts":
    let dir = getTempDir() / ("triad-persistent-reload-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "counter.janet",
      """
(var seen 0)
(triad/on :window-opened
  (fn [_]
    (set seen (+ seen 1))
    (triad/command "focus-tag" seen)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "counter.janet"):
        removeFile(dir / "counter.janet")
      if dirExists(dir):
        removeDir(dir)

    let first = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    sleep(1100)
    writeFile(
      dir / "counter.janet",
      """
(var seen 4)
(triad/on :window-opened
  (fn [_]
    (set seen (+ seen 1))
    (triad/command "focus-tag" seen)))
""",
    )
    let reloaded = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    removeFile(dir / "counter.janet")
    let deleted = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check first.len == 1
    check first[0].messages.len == 1
    check first[0].messages[0].focusTag == 1
    check reloaded.len == 1
    check reloaded[0].outcome == ScriptOutcome.Evaluated
    check reloaded[0].messages.len == 1
    check reloaded[0].messages[0].focusTag == 5
    check deleted.len == 0

  test "multiple handlers for one event run in registration order":
    let dir =
      getTempDir() / ("triad-persistent-handler-order-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "handlers.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/command "focus-tag" 2)))
(triad/on :window-opened
  (fn [_]
    (triad/command "focus-tag" 3)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "handlers.janet"):
        removeFile(dir / "handlers.janet")
      if dirExists(dir):
        removeDir(dir)

    let results = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check results.len == 1
    check results[0].outcome == ScriptOutcome.Evaluated
    check results[0].messages.len == 2
    check results[0].messages[0].focusTag == 2
    check results[0].messages[1].focusTag == 3

  test "hook fibers wait for future events and preserve local state":
    let dir = getTempDir() / ("triad-hook-fiber-wait-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "waiter.janet",
      """
(triad/on :window-opened
  (fn [opened]
    (let [ready (triad/wait-event :window-ready)]
      (triad/command "focus-window" (ready :window-id))
      (triad/command "focus-tag" (opened :window-id)))))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "waiter.janet"):
        removeFile(dir / "waiter.janet")
      if dirExists(dir):
        removeDir(dir)

    let opened = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened :window-id 2}", testSnapshot()
    )
    let ready = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 12, appId: "kitty")),
      testSnapshot(),
    )

    check opened.len == 1
    check opened[0].outcome == ScriptOutcome.Evaluated
    check opened[0].messages.len == 0
    check ready.len == 1
    check ready[0].outcome == ScriptOutcome.Evaluated
    check ready[0].messages.len == 2
    check ready[0].messages[0].kind == MsgKind.CmdFocusWindowById
    check ready[0].messages[0].focusWindowId == 12
    check ready[0].messages[1].kind == MsgKind.CmdFocusTag
    check ready[0].messages[1].focusTag == 2

  test "hook fibers emit before yield and resume before matching handlers":
    let dir = getTempDir() / ("triad-hook-fiber-order-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "order.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/command "focus-tag" 1)
    (triad/wait-event :window-ready)
    (triad/command "focus-tag" 2)))
(triad/on :window-ready
  (fn [_]
    (triad/command "focus-tag" 3)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "order.janet"):
        removeFile(dir / "order.janet")
      if dirExists(dir):
        removeDir(dir)

    let opened = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    let ready = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 3, appId: "kitty")),
      testSnapshot(),
    )

    check opened.len == 1
    check opened[0].messages.len == 1
    check opened[0].messages[0].focusTag == 1
    check ready.len == 1
    check ready[0].messages.len == 2
    check ready[0].messages[0].focusTag == 2
    check ready[0].messages[1].focusTag == 3

  test "hook fibers can re-yield for another event":
    let dir = getTempDir() / ("triad-hook-fiber-reyield-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "relay.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/wait-event :window-ready)
    (triad/command "focus-tag" 4)
    (triad/wait-event :window-closed)
    (triad/command "focus-tag" 5)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "relay.janet"):
        removeFile(dir / "relay.janet")
      if dirExists(dir):
        removeDir(dir)

    discard runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    let ready = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 4, appId: "kitty")),
      testSnapshot(),
    )
    let closed = runtime.evalScriptsDetailed(
      "window-closed", "{:kind :window-closed :window-id 4 :window nil}", testSnapshot()
    )

    check ready.len == 1
    check ready[0].messages.len == 1
    check ready[0].messages[0].focusTag == 4
    check closed.len == 1
    check closed[0].messages.len == 1
    check closed[0].messages[0].focusTag == 5

  test "deleted scripts discard waiting hook fibers":
    let dir = getTempDir() / ("triad-hook-fiber-delete-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "waiter.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/wait-event :window-ready)
    (triad/command "focus-tag" 6)))
""",
    )
    var runtime = initJanetRuntime(testConfig(dir))
    defer:
      runtime.close()
      if fileExists(dir / "waiter.janet"):
        removeFile(dir / "waiter.janet")
      if dirExists(dir):
        removeDir(dir)

    let opened = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    removeFile(dir / "waiter.janet")
    let ready = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 6, appId: "kitty")),
      testSnapshot(),
    )

    check opened.len == 1
    check opened[0].outcome == ScriptOutcome.Evaluated
    check opened[0].messages.len == 0
    check ready.len == 0

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

  test "script handler failures are cached until source changes":
    let dir = getTempDir() / ("triad-handler-failure-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "broken.janet",
      """
(triad/on :window-opened
  (fn [_]
    (error "handler boom")))
""",
    )
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

  test "hook fiber invalid wait arguments are cached until source changes":
    let dir = getTempDir() / ("triad-hook-fiber-invalid-wait-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "broken.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/wait-event "window-ready")))
""",
    )
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

  test "hook fiber unsupported raw yields are cached until source changes":
    let dir = getTempDir() / ("triad-hook-fiber-raw-yield-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "broken.janet",
      """
(triad/on :window-opened
  (fn [_]
    (yield :manual)))
""",
    )
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
    check failed[0].error.contains("unsupported")
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
      currentEvent = windowReadyEvent(
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
      currentEvent = windowReadyEvent(
        ShellWindow(id: 18, title: "GNU Image Manipulation Program", appId: "gimp")
      ),
    )

    check currentOccupiesTarget.ok
    check currentOccupiesTarget.messages.len == 3
    check currentOccupiesTarget.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check currentOccupiesTarget.messages[0].moveTargetTag == 3
    check currentOccupiesTarget.messages[1].kind == MsgKind.CmdSetLayout
    check currentOccupiesTarget.messages[1].layoutTargetTag == 3
    check currentOccupiesTarget.messages[2].kind == MsgKind.CmdToggleFullscreenById
    check currentOccupiesTarget.messages[2].fullscreenWindowId == 18

    let mainWindow = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent = windowReadyEvent(
        ShellWindow(id: 13, title: "GNU Image Manipulation Program", appId: "gimp-3.2")
      ),
    )

    check mainWindow.ok
    check mainWindow.messages.len == 3
    check mainWindow.messages[0].kind == MsgKind.CmdMoveWindowToTag
    check mainWindow.messages[0].moveTargetTag == 3
    check mainWindow.messages[0].moveFollowWindow
    check mainWindow.messages[1].kind == MsgKind.CmdSetLayout
    check mainWindow.messages[1].layoutTargetTag == 3
    check mainWindow.messages[2].kind == MsgKind.CmdToggleFullscreenById
    check mainWindow.messages[2].fullscreenWindowId == 13

    let laterPalette = runtime.evalSource(
      snapshot,
      script,
      "examples/janet/gimp.janet",
      currentEvent = windowReadyEvent(
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
      currentEvent = windowReadyEvent(
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
      currentEvent = windowReadyEvent(
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
    check mainWindow.messages[1].kind == MsgKind.CmdSetCustomLayout
    check mainWindow.messages[1].customLayoutTargetTag == 4
    check mainWindow.messages[1].customLayout.layoutIdString() == "deck"
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
      currentEvent = windowReadyEvent(
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
    check parentedDialog.messages[1].kind == MsgKind.CmdSetCustomLayout
    check parentedDialog.messages[1].customLayoutTargetTag == 4
    check parentedDialog.messages[1].customLayout.layoutIdString() == "deck"
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
      windowReadyEvent(
        ShellWindow(id: 21, title: "Telegram", appId: "org.telegram.desktop")
      ),
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
    check results[0].messages[1].kind == MsgKind.CmdSetCustomLayout
    check results[0].messages[1].customLayoutTargetTag == 4
    check results[0].messages[1].customLayout.layoutIdString() == "deck"
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
    check dialogResults[0].messages[1].kind == MsgKind.CmdSetCustomLayout
    check dialogResults[0].messages[1].customLayoutTargetTag == 4
    check dialogResults[0].messages[1].customLayout.layoutIdString() == "deck"
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

  test "output lifecycle events dispatch from daemon snapshots":
    let dir = getTempDir() / ("triad-output-hooks-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "outputs.janet",
      """
(triad/on :output-added
  (fn [ev]
    (when (and (= (ev :output-id) 2)
               (= ((ev :output) :name) "DP-1")
               (= ((ev :output) :refresh-rate) 165000)
               (not (ev :old-output)))
      (triad/command "focus-tag" 2))))

(triad/on :output-changed
  (fn [ev]
    (when (and (= (ev :output-id) 1)
               (= ((ev :old-output) :name) "HDMI-A-1")
               (= ((ev :output) :name) "HDMI-A-2"))
      (triad/command "focus-tag" 3))))

(triad/on :output-removed
  (fn [ev]
    (when (and (= (ev :output-id) 3)
               (not (ev :output))
               (= ((ev :old-output) :name) "VGA-1"))
      (triad/command "focus-tag" 4))))

(triad/on :output-removed
  (fn [ev]
    (when (= (ev :output-id) 0)
      (triad/command "focus-tag" 9))))
""",
    )
    var daemon = initTriadDaemon()
    daemon.janetRuntime = initJanetRuntime(testConfig(dir))
    defer:
      daemon.janetRuntime.close()
      if fileExists(dir / "outputs.janet"):
        removeFile(dir / "outputs.janet")
      if dirExists(dir):
        removeDir(dir)

    let baseOutput =
      ShellOutput(id: 1, name: "HDMI-A-1", w: 1920, h: 1080, isPrimary: true)
    let addedOutput =
      ShellOutput(id: 2, name: "DP-1", w: 2560, h: 1440, refreshRate: 165000)
    let changedOutput =
      ShellOutput(id: 1, name: "HDMI-A-2", w: 1920, h: 1080, isPrimary: true)
    let removedOutput = ShellOutput(id: 3, name: "VGA-1", w: 1024, h: 768)

    var before = testSnapshot()
    before.outputs = @[baseOutput]
    var afterAdded = before
    afterAdded.outputs = @[baseOutput, addedOutput]
    let addedMessages = daemon.collectJanetScriptMessages(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 2, width: 2560, height: 1440),
      before,
      afterAdded,
    )

    check addedMessages.len == 1
    check addedMessages[0].origin == QueuedMsgOrigin.JanetHook
    check addedMessages[0].msg.kind == MsgKind.CmdFocusTag
    check addedMessages[0].msg.focusTag == 2

    var afterChanged = before
    afterChanged.outputs = @[changedOutput]
    let changedMessages = daemon.collectJanetScriptMessages(
      Msg(kind: MsgKind.WlOutputName, nameOutputId: 1, outputName: "HDMI-A-2"),
      before,
      afterChanged,
    )

    check changedMessages.len == 1
    check changedMessages[0].origin == QueuedMsgOrigin.JanetHook
    check changedMessages[0].msg.kind == MsgKind.CmdFocusTag
    check changedMessages[0].msg.focusTag == 3

    var beforeRemoved = before
    beforeRemoved.outputs = @[baseOutput, removedOutput]
    let removedMessages = daemon.collectJanetScriptMessages(
      Msg(kind: MsgKind.WlOutputRemoved, removedOutputId: 3), beforeRemoved, before
    )

    check removedMessages.len == 1
    check removedMessages[0].origin == QueuedMsgOrigin.JanetHook
    check removedMessages[0].msg.kind == MsgKind.CmdFocusTag
    check removedMessages[0].msg.focusTag == 4

    let unchangedMessages = daemon.collectJanetScriptMessages(
      Msg(kind: MsgKind.WlOutputRefreshRate, refreshOutputId: 1, outputRefreshRate: 0),
      before,
      before,
    )

    check unchangedMessages.len == 0

    var fallbackOnly = before
    fallbackOnly.outputs = @[ShellOutput(id: 0, name: "triad-0", w: 1920, h: 1080)]
    let fallbackReplacementMessages = daemon.collectJanetScriptMessages(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1920, height: 1080),
      fallbackOnly,
      before,
    )

    check fallbackReplacementMessages.len == 0

  test "ui lifecycle events dispatch from daemon state snapshots":
    let dir = getTempDir() / ("triad-ui-hooks-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "ui.janet",
      """
(triad/on :overview-opened
  (fn [ev]
    (when (and (ev :active) (= (ev :selected-window-id) 10))
      (triad/command "focus-tag" 1))))

(triad/on :overview-closed
  (fn [ev]
    (when (not (ev :active))
      (triad/command "focus-tag" 2))))

(triad/on :recent-windows-opened
  (fn [ev]
    (when (and (ev :active)
               (= (ev :selected-window-id) 11)
               (= (ev :scope) "workspace")
               (= (ev :filter) "app-id")
               (= (ev :app-id-filter) "firefox"))
      (triad/command "focus-tag" 3))))

(triad/on :recent-windows-closed
  (fn [ev]
    (when (not (ev :active))
      (triad/command "focus-tag" 4))))

(triad/on :hotkey-overlay-opened
  (fn [ev]
    (when (ev :active)
      (triad/command "focus-tag" 5))))

(triad/on :hotkey-overlay-closed
  (fn [ev]
    (when (not (ev :active))
      (triad/command "focus-tag" 6))))

(triad/on :exit-session-confirm-opened
  (fn [ev]
    (when (ev :active)
      (triad/command "focus-tag" 7))))

(triad/on :exit-session-confirm-closed
  (fn [ev]
    (when (not (ev :active))
      (triad/command "focus-tag" 8))))

(triad/on :layout-switch-toast-opened
  (fn [ev]
    (when (and (ev :active) (= (ev :layout) "grid"))
      (triad/command "focus-tag" 9))))

(triad/on :layout-switch-toast-closed
  (fn [ev]
    (when (and (not (ev :active)) (= (ev :layout) "grid"))
      (triad/command "focus-tag" 10))))
""",
    )
    var daemon = initTriadDaemon()
    daemon.janetRuntime = initJanetRuntime(testConfig(dir))
    defer:
      daemon.janetRuntime.close()
      if fileExists(dir / "ui.janet"):
        removeFile(dir / "ui.janet")
      if dirExists(dir):
        removeDir(dir)

    let base = baseUiHookState()
    var overviewOpen = base
    overviewOpen.overviewActive = true
    overviewOpen.overviewSelectedWindow = 10
    daemon.expectUiHookFocusTag(base, overviewOpen, 1)
    daemon.expectUiHookFocusTag(overviewOpen, base, 2)

    var recentOpen = base
    recentOpen.recentWindowsActive = true
    recentOpen.recentWindowsSelectedWindow = 11
    recentOpen.recentWindowsScope = RecentWindowScope.Workspace
    recentOpen.recentWindowsFilter = RecentWindowFilter.AppId
    recentOpen.recentWindowsAppIdFilter = "firefox"
    daemon.expectUiHookFocusTag(base, recentOpen, 3)
    daemon.expectUiHookFocusTag(recentOpen, base, 4)

    var hotkeyOpen = base
    hotkeyOpen.hotkeyOverlayOpen = true
    daemon.expectUiHookFocusTag(base, hotkeyOpen, 5)
    daemon.expectUiHookFocusTag(hotkeyOpen, base, 6)

    var exitOpen = base
    exitOpen.exitSessionConfirmOpen = true
    daemon.expectUiHookFocusTag(base, exitOpen, 7)
    daemon.expectUiHookFocusTag(exitOpen, base, 8)

    var toastOpen = base
    toastOpen.layoutSwitchToastOpen = true
    toastOpen.layoutSwitchToastLayout = LayoutMode.Grid
    var toastClosed = base
    toastClosed.layoutSwitchToastLayout = LayoutMode.Grid
    daemon.expectUiHookFocusTag(base, toastOpen, 9)
    daemon.expectUiHookFocusTag(toastOpen, toastClosed, 10)

    let unchangedMessages =
      daemon.collectJanetUiScriptMessages(base, base, testSnapshot())
    check unchangedMessages.len == 0

  test "ui hook wait-event resumes and hook origin is guarded":
    let dir = getTempDir() / ("triad-ui-hook-wait-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "wait-ui.janet",
      """
(triad/on :overview-opened
  (fn [ev]
    (let [closed (triad/wait-event :overview-closed)]
      (when (not (closed :active))
        (triad/command "focus-tag" 7)))))
""",
    )
    var daemon = initTriadDaemon()
    daemon.janetRuntime = initJanetRuntime(testConfig(dir))
    defer:
      daemon.janetRuntime.close()
      if fileExists(dir / "wait-ui.janet"):
        removeFile(dir / "wait-ui.janet")
      if dirExists(dir):
        removeDir(dir)

    let base = baseUiHookState()
    var overviewOpen = base
    overviewOpen.overviewActive = true

    let openMessages =
      daemon.collectJanetUiScriptMessages(base, overviewOpen, testSnapshot())
    check openMessages.len == 0

    daemon.expectUiHookFocusTag(overviewOpen, base, 7)
    check QueuedMsgOrigin.Normal.shouldDispatchJanetUiScripts()
    check not QueuedMsgOrigin.JanetHook.shouldDispatchJanetUiScripts()

  test "sandbox blocks host access":
    var runtime = initJanetRuntime(testConfig(getTempDir()))
    defer:
      runtime.close()

    for source in [
      """(os/getenv "HOME")""", """(file/open "/tmp/triad-janet-sandbox" :w)""",
      """(net/connect "127.0.0.1" "1")""", """(native/load "libc.so.6")""",
      """(eval "(+ 1 2)")""", """(compile '(+ 1 2))""",
      """(debug/stack (fiber/new (fn [] nil)))""",
    ]:
      let evaluated = runtime.evalSource(testSnapshot(), source)

      check not evaluated.ok
      check evaluated.messages.len == 0

  test "fuel limit allows finite loops":
    var runtime = initJanetRuntime(testConfigFuel(getTempDir(), 10000))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(
      testSnapshot(),
      """
(var count 0)
(while (< count 5)
  (set count (+ count 1)))
(triad/command "move-to-tag" count)
""",
    )

    check evaluated.ok
    check evaluated.messages.len == 1
    check evaluated.messages[0].kind == MsgKind.CmdMoveToTag
    check evaluated.messages[0].targetTag == 5

  test "fuel limit rejects non-terminating loops":
    var runtime = initJanetRuntime(testConfigFuel(getTempDir(), 1000))
    defer:
      runtime.close()

    let evaluated = runtime.evalSource(testSnapshot(), """(while true nil)""")

    check not evaluated.ok
    check evaluated.error.len > 0
    check evaluated.messages.len == 0

  test "fuel limit rejects non-terminating hook handlers":
    let dir = getTempDir() / ("triad-handler-fuel-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "loop.janet",
      """
(triad/on :window-opened
  (fn [_]
    (while true nil)))
""",
    )
    var runtime = initJanetRuntime(testConfigFuel(dir, 1000))
    defer:
      runtime.close()
      if fileExists(dir / "loop.janet"):
        removeFile(dir / "loop.janet")
      if dirExists(dir):
        removeDir(dir)

    let results = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )

    check results.len == 1
    check results[0].outcome == ScriptOutcome.EvalFailed
    check results[0].error.len > 0
    check results[0].messages.len == 0

  test "fuel limit rejects non-terminating resumed hook fibers":
    let dir = getTempDir() / ("triad-resumed-fiber-fuel-" & $getCurrentProcessId())
    createDir(dir)
    writeFile(
      dir / "loop.janet",
      """
(triad/on :window-opened
  (fn [_]
    (triad/wait-event :window-ready)
    (while true nil)))
""",
    )
    var runtime = initJanetRuntime(testConfigFuel(dir, 1000))
    defer:
      runtime.close()
      if fileExists(dir / "loop.janet"):
        removeFile(dir / "loop.janet")
      if dirExists(dir):
        removeDir(dir)

    let opened = runtime.evalScriptsDetailed(
      "window-opened", "{:kind :window-opened}", testSnapshot()
    )
    let ready = runtime.evalScriptsDetailed(
      "window-ready",
      windowReadyEvent(ShellWindow(id: 7, appId: "kitty")),
      testSnapshot(),
    )

    check opened.len == 1
    check opened[0].outcome == ScriptOutcome.Evaluated
    check opened[0].messages.len == 0
    check ready.len == 1
    check ready[0].outcome == ScriptOutcome.EvalFailed
    check ready[0].error.len > 0
    check ready[0].messages.len == 0
