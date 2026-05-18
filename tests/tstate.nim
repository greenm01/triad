import std/[json, options, os, sequtils, strutils, tables, unittest]
from posix import TPollfd, close, pipe, read, write
import ../src/config/defaults
import ../src/config/parser
import
  ../src/core/[effects, layout_selection_codec, msg, native_layout_codec, restore_state]
import ../src/daemon/hotkey_overlay_render
import ../src/daemon/exit_session_dialog_render
import ../src/daemon/frame_tab_bar_render
import ../src/daemon/layout_switch_toast_render
import ../src/daemon/overlay_text_render
import ../src/daemon/overview_overlay_render
import ../src/daemon/recent_windows_overlay_render
import ../src/state/engine except WindowId
import ../src/state/[entity_manager, invariants, live_restore, snapshot]
import
  ../src/systems/[
    daemon_view, layout_projection, overview_geometry, recent_windows, runtime_facade,
    update, window_lifecycle,
  ]
import ../src/types/janet_layouts
import ../src/types/core as tc
import ../src/types/[model, runtime_values]
import ../src/types/projection_values as pv
import ../src/utils/event_poll

const DeletedRuntimeModules = [
  "src/types/legacy_model.nim", "src/core/model.nim", "src/core/model_utils.nim",
  "src/core/update.nim", "src/core/shell_state.nim", "src/config/legacy_apply.nim",
  "src/systems/layout_state.nim", "src/state/dod_adapter.nim",
  "src/systems/runtime_update_sync.nim", "src/systems/layout_projection_sync.nim",
  "src/systems/state_application_sync.nim", "src/systems/projection_read_sync.nim",
  "src/systems/dod_shadow_runtime.nim", "src/systems/dod_shadow_health.nim",
  "src/types/dod_shadow_health.nim",
]

const OverviewEmptyWorkspaceFill = 0xcc000000'u32
const OverviewHiddenBadgeFill = 0xdd000000'u32
const OverviewScrollIndicatorColor = 0x55ffffff'u32

proc baseConfig(): Config =
  Config(
    layout: LayoutConfig(
      gaps: 12,
      defaultColumnWidth: 0.6,
      defaultWindowWidth: 0.8,
      defaultWindowHeight: 0.7,
      defaultMasterCount: 2,
      defaultMasterRatio: 0.55,
      layoutCycle: @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.Grid],
    ),
    workspaces: WorkspaceConfig(defaultCount: 3),
    tagRules:
      @[
        TagRule(tagId: 1, name: "main"),
        TagRule(
          tagId: 2, name: "web", defaultLayoutSet: true, defaultLayout: LayoutMode.Grid
        ),
      ],
    hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true),
    terminal: TerminalConfig(command: @["foot"]),
  )

proc instructionGeom(model: Model, id: uint32): pv.Rect =
  let projection = model.layoutProjection()
  for instr in projection.instructions:
    if uint32(instr.windowId) == id:
      return instr.geom
  pv.Rect()

proc applyMsg(model: var Model, msg: Msg) =
  let (nextModel, _) = model.update(msg)
  model = nextModel

proc focusedWindowId(model: Model): uint32 =
  for win in model.shellSnapshot().windows:
    if win.isFocused:
      return uint32(win.id)
  0'u32

proc sourceFiles(): seq[string] =
  for path in walkDirRec("src"):
    if path.endsWith(".nim"):
      result.add(path)

proc typeFiles(): seq[string] =
  for path in walkDirRec("src/types"):
    if path.endsWith(".nim"):
      result.add(path)

proc styleSourceFiles(): seq[string] =
  for root in ["src", "tests"]:
    for path in walkDirRec(root):
      if path.endsWith(".nim") and "/nimcache/" notin path and
          not path.startsWith("src/protocols/"):
        result.add(path)

proc sourceLineFailures(checkLine: proc(path, line: string): bool): seq[string] =
  for path in styleSourceFiles():
    var lineNo = 0
    for line in lines(path):
      inc lineNo
      if checkLine(path, line):
        result.add(path & ":" & $lineNo & ": " & line)

proc isAllowedTypeInterop(path, line: string): bool =
  if path != "src/types/core.nim":
    return false
  line.contains("{.borrow.}") or line.startsWith("proc hash*(")

proc testArgb(value: uint32): uint32 =
  let r = (value shr 24) and 0xff
  let g = (value shr 16) and 0xff
  let b = (value shr 8) and 0xff
  let a = value and 0xff
  (a shl 24) or (r shl 16) or (g shl 8) or b

proc premultiplyArgb(value: uint32): uint32 =
  let
    alpha = (value shr 24) and 0xff
    red = (value shr 16) and 0xff
    green = (value shr 8) and 0xff
    blue = value and 0xff
  (alpha shl 24) or (((red * alpha + 127'u32) div 255'u32) shl 16) or
    (((green * alpha + 127'u32) div 255'u32) shl 8) or
    ((blue * alpha + 127'u32) div 255'u32)

proc pixelAt(buf: PixelBuffer, x, y: int32): uint32 =
  if x < 0 or y < 0 or x >= buf.width or y >= buf.height:
    return 0
  buf.pixels[int(y * buf.width + x)]

proc isTopLevelBehavior(line: string): bool =
  for prefix in ["proc ", "func ", "iterator ", "template ", "macro ", "converter "]:
    if line.startsWith(prefix):
      return true
  false

proc isIdentChar(ch: char): bool =
  ch.isAlphaNumeric() or ch == '_'

proc containsFieldRead(line, field: string): bool =
  let idx = line.find(field)
  if idx == -1:
    return false
  let next = idx + field.len
  next >= line.len or not line[next].isIdentChar()

suite "Runtime state primitives":
  test "deleted legacy and shadow modules are gone":
    for path in DeletedRuntimeModules:
      check not fileExists(path)

  test "production source has no imports of deleted runtime modules":
    let blocked = [
      "legacy_model", "core/model", "core/model_utils", "core/update",
      "core/shell_state", "legacy_apply", "layout_state", "dod_adapter",
      "runtime_update_sync", "layout_projection_sync", "state_application_sync",
      "projection_read_sync", "dod_shadow_runtime", "dod_shadow_health",
      "dod_shadow_health",
    ]
    for path in sourceFiles():
      let source = readFile(path)
      for pattern in blocked:
        check not source.contains(pattern)
      check not source.contains("runtimeState.legacyModel")
      check not source.contains("runtimeState.shadowModel")
      check not source.contains("logShadowObservation")
      check not source.contains("applyObservedRuntimeShadowOnly")

  test "daemon click focus uses command focus path":
    let source = readFile("src/triad.nim")
    check not source.contains("MsgKind.WlFocusChanged")

  test "empty frame focus is click-only":
    let source = readFile("src/daemon/bindings_runtime.nim")
    let enterStart = source.find("proc onWlPointerEnter")
    let enterEnd = source.find("proc onWlPointerLeave")
    let buttonStart = source.find("proc onWlPointerButton")
    let axisStart = source.find("proc ignoreWlPointerAxis")
    check enterStart != -1
    check enterEnd > enterStart
    check buttonStart != -1
    check axisStart > buttonStart
    let enterBody = source[enterStart ..< enterEnd]
    let buttonBody = source[buttonStart ..< axisStart]
    check not enterBody.contains("dispatchFrameEmptyFocus")
    check buttonBody.contains("dispatchFrameEmptyFocus")

  test "triad entrypoint stays thin":
    let source = readFile("src/triad.nim")
    check source.splitLines().len <= 30
    check not source.contains("var daemon")
    check not source.contains("template ")
    check source.contains("import daemon/app")

  test "daemon main loop does not sleep before Wayland event service":
    let source = readFile("src/daemon/app.nim")
    check source.contains("asyncdispatch.poll(0)")
    check not source.contains("asyncdispatch.poll(pollInterval)")
    check not source.contains("asyncdispatch.poll(frameInterval)")
    check source.contains("IdleWakeIntervalMs = 50")
    check source.contains("waitForRuntimeEventFds")
    check source.contains("\"idle_wake_interval_ms\"")
    check source.contains("\"current_wait_timeout_ms\"")
    check source.contains("\"wait_backend\"")
    check source.contains("\"skipped_render_starts\"")
    check source.contains("\"render_layout_projections\"")

  test "runtime event poll reports descriptor readiness":
    var pipeFds: array[2, cint]
    check pipe(pipeFds) == 0
    defer:
      discard close(pipeFds[0])
      discard close(pipeFds[1])

    var fds: seq[TPollfd]
    var marker = 'x'
    check write(pipeFds[1], addr marker, 1) == 1
    let asyncReady = fds.waitForRuntimeEventFds(-1, int(pipeFds[0]), [], 10)
    check asyncReady.asyncReady
    check not asyncReady.waylandReady
    check not asyncReady.switchReady

    var drained: char
    discard read(pipeFds[0], addr drained, 1)
    check write(pipeFds[1], addr marker, 1) == 1
    let switchReady = fds.waitForRuntimeEventFds(-1, -1, [int32(pipeFds[0])], 10)
    check switchReady.switchReady
    check not switchReady.asyncReady
    check not switchReady.waylandReady

  test "types modules stay data-only":
    for path in typeFiles():
      let lines = readFile(path).splitLines()
      for lineNo in 0 ..< lines.len:
        let line = lines[lineNo]
        if line.isTopLevelBehavior():
          if not path.isAllowedTypeInterop(line):
            checkpoint path & ":" & $(lineNo + 1) & ": " & line
          check path.isAllowedTypeInterop(line)

  test "audited exported data contracts stay in types modules":
    let movedTypes = [
      (path: "src/config/parser.nim", pattern: "Config* = object"),
      (path: "src/config/parser.nim", pattern: "LayoutConfig* = object"),
      (path: "src/config/parser.nim", pattern: "ConfigLoadResult* = object"),
      (path: "src/config/parser.nim", pattern: "ConfigDocument* = object"),
      (path: "src/core/msg.nim", pattern: "MsgKind* {.pure.} = enum"),
      (path: "src/core/msg.nim", pattern: "Msg* = object"),
      (path: "src/core/effects.nim", pattern: "EffectKind* {.pure.} = enum"),
      (path: "src/core/effects.nim", pattern: "Effect* = object"),
      (path: "src/core/restore_state.nim", pattern: "LiveRestoreState* = object"),
      (path: "src/core/restore_state.nim", pattern: "LiveRestoreWriteResult* = object"),
      (path: "src/ipc/command_registry.nim", pattern: "CommandId* {.pure.} = enum"),
      (
        path: "src/ipc/command_registry.nim",
        pattern: "CommandArgShape* {.pure.} = enum",
      ),
      (path: "src/ipc/command_registry.nim", pattern: "CommandSpec* = object"),
      (path: "src/systems/recent_windows.nim", pattern: "RecentWindowPreview* = object"),
      (
        path: "src/systems/window_policy.nim",
        pattern: "ParentedWindowIntent* {.pure.} = enum",
      ),
      (path: "src/systems/window_policy.nim", pattern: "LeadFloatingAnchor* = object"),
      (path: "src/systems/update_effects.nim", pattern: "UpdateStep* = object"),
      (
        path: "src/systems/overview_geometry.nim",
        pattern: "OverviewStyle* {.pure.} = enum",
      ),
      (
        path: "src/systems/overview_geometry.nim",
        pattern: "OverviewDropKind* {.pure.} = enum",
      ),
      (
        path: "src/systems/overview_geometry.nim",
        pattern: "OverviewDropTarget* = object",
      ),
    ]
    for item in movedTypes:
      let source = readFile(item.path)
      checkpoint item.path & " still defines " & item.pattern
      check not source.contains(item.pattern)

  test "runtime values does not reintroduce duplicate model or projection types":
    let runtimeValues = readFile("src/types/runtime_values.nim")
    let blockedRuntimeTypes = [
      "WindowId* =", "Rect* = object", "WindowData* = object", "OutputData* = object",
      "TagState* = object", "Column* = object", "GroupState* = object",
      "RenderInstruction* = object", "RestoredWindowState* = object",
      "RestoredColumnState* = object", "RestoredTagState* = object",
    ]
    for pattern in blockedRuntimeTypes:
      checkpoint "runtime_values still contains " & pattern
      check not runtimeValues.contains(pattern)

    let blockedImports = sourceLineFailures(
      proc(path, line: string): bool =
        for symbol in [
          "WindowId", "Rect", "WindowData", "OutputData", "TagState", "Column",
          "GroupState", "RenderInstruction", "RestoredWindowState",
          "RestoredColumnState", "RestoredTagState",
        ]:
          if line.contains("runtime_values." & symbol):
            return true
          if ("import" in line or "from" in line) and "runtime_values" in line and
              symbol in line:
            return true
        false
    )
    check blockedImports.len == 0

  test "source follows enforceable style rules":
    let tabFailures = sourceLineFailures(
      proc(path, line: string): bool =
        line.contains("\t")
    )
    check tabFailures.len == 0

    let enumFailures = sourceLineFailures(
      proc(path, line: string): bool =
        line.contains("= enum") and "{.pure.}" notin line
    )
    check enumFailures.len == 0

    let getterFailures = sourceLineFailures(
      proc(path, line: string): bool =
        let trimmed = line.strip()
        result = trimmed.startsWith("proc get") or trimmed.startsWith("func get")
    )
    check getterFailures.len == 0

    let entityStorageFailures = sourceLineFailures(
      proc(path, line: string): bool =
        path != "src/state/entity_manager.nim" and path != "tests/tstate.nim" and
          (".data" in line or ".index" in line)
    )
    check entityStorageFailures.len == 0

  test "systems read state through facade queries":
    let blockedStateImports = sourceLineFailures(
      proc(path, line: string): bool =
        path.startsWith("src/systems/") and
          (line.contains("import ../state/") or line.contains("from ../state/")) and
          not line.contains("../state/engine")
    )
    check blockedStateImports.len == 0

    let blockedRelationReads = [
      "model.scratchpadWindows", "model.namedScratchpads", "model.visibleScratchpad",
      "model.scratchpadRestoreTags", "model.isScratchpadVisible", "model.focusHistory",
      "model.workspaceHistory", "model.restoreActiveSlot", "model.restoreFocusedWindow",
      "model.restoreTagByWindow", "model.restoreWindows", "model.restoreTags",
      "model.restoreOutputTags", "model.restoreScratchpadWindows",
      "model.restoreNamedScratchpads", "model.restoreScratchpadSlots",
      "model.restoreVisibleScratchpad", "model.restoreIsScratchpadVisible",
      "model.restoreFocusHistory", "model.restoreWorkspaceHistory",
    ]
    let directRelationReads = sourceLineFailures(
      proc(path, line: string): bool =
        if not path.startsWith("src/systems/"):
          return false
        for field in blockedRelationReads:
          if line.containsFieldRead(field):
            return true
        false
    )
    check directRelationReads.len == 0

    let allocatingQueryReads = sourceLineFailures(
      proc(path, line: string): bool =
        path.startsWith("src/systems/") and (
          line.contains(".columnsForTag(") or line.contains(".windowsForColumn(") or
          line.contains(".windowsForTag(")
        )
    )
    check allocatingQueryReads.len == 0

  test "state query helpers cover indexed relation reads":
    var model = Model()
    let tagId = model.addTag(slot = 1, layoutMode = LayoutMode.Scroller)
    let columnId = model.addColumn(tagId, 0.6'f32)
    let winId = model.addWindow(ExternalWindowId(100), appId = "term")
    discard model.moveWindowToColumn(tagId, winId, columnId, 0)

    check model.columnCountForTag(tagId) == 1
    check model.columnAt(tagId, 0) == columnId
    check model.columnAt(tagId, 1) == NullColumnId
    check model.windowCountForColumn(columnId) == 1
    check model.windowAt(columnId, 0) == winId
    check model.windowAt(columnId, 1) == NullWindowId
    check model.placementForWindowOnTag(tagId, winId).isSome

    discard model.addScratchpadRef(winId)
    discard model.recordScratchpadRestoreTags(winId, model.windowTagMask(winId))
    discard model.setNamedScratchpadRef("term", winId)
    discard model.showScratchpadRef(winId)
    check model.scratchpadVisible()
    check model.latestScratchpadWindow() == winId
    check model.activeScratchpadWindow() == winId
    check model.namedScratchpadWindow("term") == winId
    check model.scratchpadRestoreSlots(winId) == @[1'u32]

    discard model.recordFocus(winId)
    discard model.recordWorkspace(tagId)
    check toSeq(model.focusHistoryIds()) == @[winId]
    check toSeq(model.focusHistoryIdsReverse()) == @[winId]
    check toSeq(model.workspaceHistoryIds()) == @[tagId]

    discard model.loadRestoreState(
      PendingRestoreState(
        focusedWindow: ExternalWindowId(100),
        focusHistory: @[ExternalWindowId(100)],
        workspaceHistory: @[1'u32],
        scratchpadWindows: @[ExternalWindowId(100)],
      )
    )
    check model.restoreFocusedWindowPending()
    check model.restoreFocusedWindowId() == ExternalWindowId(100)
    check model.restoredScratchpadContains(ExternalWindowId(100))
    check toSeq(model.restoreFocusHistoryIds()) == @[ExternalWindowId(100)]
    check toSeq(model.restoreWorkspaceHistorySlots()) == @[1'u32]

  test "runtime init builds a valid model from config":
    let initialized = initRuntimeStateFromConfig(baseConfig())
    let snapshot = initialized.readRuntimeSnapshot()

    check initialized.model.validateInvariants().ok
    check initialized.model.defaultWorkspaceCount == 3
    check initialized.model.outerGaps == 12
    check initialized.model.layoutCycle ==
      @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.Grid]
    check snapshot.activeTag == 1
    check snapshot.workspaces.len == 3
    check snapshot.workspaces[0].name == "main"
    check snapshot.workspaces[1].layoutMode == LayoutMode.Grid

  test "runtime init keeps hotkey overlay hidden by default":
    let hidden = initRuntimeStateFromConfig(baseConfig())
    var shownConfig = baseConfig()
    shownConfig.hotkeyOverlay.skipAtStartup = false
    let shown = initRuntimeStateFromConfig(shownConfig)

    check not hidden.model.hotkeyOverlayOpen
    check not hidden.model.hotkeyOverlayShownOnce
    check shown.model.hotkeyOverlayOpen
    check shown.model.hotkeyOverlayShownOnce

  test "hotkey overlay renderer produces bounded ARGB buffers":
    let screen = Rect(x: 0, y: 0, w: 800, h: 600)
    let rows =
      @[
        HotkeyOverlayRow(key: "Super+1", label: "Workspace 1"),
        HotkeyOverlayRow(key: "Super+Shift+/", label: "Show hotkeys"),
      ]
    let rendered = renderHotkeyOverlayBuffer(rows, screen, 2)
    let bytes = argbBytes(rendered.pixels)

    check rendered.width >= 360
    check rendered.width <= int32(float(screen.w) * 0.9)
    check rendered.height > 0
    check bytes.len == rendered.pixels.len * 4

  test "hotkey overlay renderer wraps rows into configured columns":
    let screen = Rect(x: 0, y: 0, w: 800, h: 300)
    var rows: seq[HotkeyOverlayRow] = @[]
    for idx in 1 .. 12:
      rows.add(HotkeyOverlayRow(key: "Super+" & $idx, label: "Action " & $idx))

    let singleColumn = renderHotkeyOverlayBuffer(rows, screen, 1)
    let twoColumns = renderHotkeyOverlayBuffer(rows, screen, 2)

    check twoColumns.width > singleColumn.width
    check twoColumns.height == singleColumn.height
    check twoColumns.width <= int32(float(screen.w) * 0.9)

  test "hotkey overlay uses laptop height before wrapping columns":
    let screen = Rect(x: 0, y: 0, w: 1536, h: 960)
    var rows: seq[HotkeyOverlayRow] = @[]
    for idx in 1 .. 26:
      rows.add(
        HotkeyOverlayRow(key: "Super+Ctrl+" & $idx, label: "Configured action " & $idx)
      )

    let singleColumn = renderHotkeyOverlayBuffer(rows, screen, 1)
    let configuredColumns = renderHotkeyOverlayBuffer(rows, screen, 2)

    check configuredColumns.width == singleColumn.width
    check configuredColumns.height == singleColumn.height
    check configuredColumns.height <= screen.h - 96

  test "hotkey overlay placement honors configured position":
    let screen = Rect(x: 10, y: 20, w: 800, h: 600)

    let top = hotkeyOverlayPlacement(screen, 300, 200, HotkeyOverlayPosition.Top)
    let center = hotkeyOverlayPlacement(screen, 300, 200, HotkeyOverlayPosition.Center)
    let bottom = hotkeyOverlayPlacement(screen, 300, 200, HotkeyOverlayPosition.Bottom)

    check top == Rect(x: 260, y: 68, w: 300, h: 200)
    check center == Rect(x: 260, y: 220, w: 300, h: 200)
    check bottom == Rect(x: 260, y: 372, w: 300, h: 200)

  test "exit-session dialog renderer is centered with red ring":
    let screen = Rect(x: 10, y: 20, w: 800, h: 600)
    let rendered = renderExitSessionDialogBuffer(screen)
    let placement = exitSessionDialogPlacement(screen, rendered.width, rendered.height)

    check rendered.width >= 420
    check rendered.width <= screen.w - 96
    check rendered.height > 0
    check placement.x == screen.x + (screen.w - rendered.width) div 2
    check placement.y == screen.y + (screen.h - rendered.height) div 2
    check pixelAt(rendered, 0, 0) == 0xffff3b30'u32
    check pixelAt(rendered, rendered.width - 1, 0) == 0xffff3b30'u32

  test "layout switch toast renderer is compact and uses configured ring":
    let screen = Rect(x: 10, y: 20, w: 800, h: 600)
    let rendered =
      renderLayoutSwitchToastBuffer(screen, LayoutMode.Grid, 4, 0x00ff00ff'u32)
    let placement = layoutSwitchToastPlacement(screen, rendered.width, rendered.height)

    check rendered.width >= 260
    check rendered.width <= screen.w - 96
    check rendered.height < renderExitSessionDialogBuffer(screen).height
    check placement.x == screen.x + (screen.w - rendered.width) div 2
    check placement.y == screen.y + (screen.h - rendered.height) div 2
    check pixelAt(rendered, 0, 0) == 0xff00ff00'u32
    check pixelAt(rendered, rendered.width - 1, 0) == 0xff00ff00'u32

  test "overlay text renderer measures clips and draws text":
    let style = OverlayTextStyle(sizePx: 14.0, color: 0xffffffff'u32)
    let metrics = "Triad".textMetrics(style)
    var rendered = initPixelBuffer(120, 40, 0x00000000'u32)
    rendered.drawText(4, 4, 112, "Triad", style)
    let clipped = "A very long title that must fit".ellipsizeText(60, style)

    check metrics.width > 0
    check metrics.height > 0
    check clipped.len < "A very long title that must fit".len
    check clipped.textWidth(style) <= 60
    check rendered.pixels.anyIt(it != 0)
    if overlayTextAvailable():
      check rendered.pixels.anyIt(
        ((it shr 24) and 0xff) > 0 and ((it shr 24) and 0xff) < 0xff
      )
      var premulEdgeFound = false
      for pixel in rendered.pixels:
        let
          alpha = (pixel shr 24) and 0xff
          red = (pixel shr 16) and 0xff
          green = (pixel shr 8) and 0xff
          blue = pixel and 0xff
        if alpha > 0 and alpha < 0xff and red <= alpha and green <= alpha and
            blue <= alpha:
          premulEdgeFound = true
      check premulEdgeFound

  test "frame tab bar renderer draws tabs and hit tests":
    let bar = pv.ProjectedFrameTabBar(
      frameId: 7,
      windowId: 11,
      geom: pv.Rect(x: 0, y: 0, w: 120, h: 24),
      focused: true,
      frameTabs: FrameTabsConfig(
        activeColor: 0x010203ff'u32,
        activeUnfocusedColor: 0x040506ff'u32,
        inactiveColor: 0x07080980'u32,
        activeLineColor: 0x0a0b0cff'u32,
        activeUnfocusedLineColor: 0x0d0e0fff'u32,
      ),
      ringWidth: 2,
      ringColor: 0x101112ff'u32,
      tabs:
        @[
          pv.ProjectedFrameTab(windowId: 10, title: "Term", appId: "foot"),
          pv.ProjectedFrameTab(
            windowId: 11, title: "Browser", appId: "firefox", active: true
          ),
        ],
    )
    let rendered = renderFrameTabBarBuffer(bar)
    check rendered.width == 120
    check rendered.height == 26
    check rendered.pixels.anyIt(it != 0)
    check rendered.pixelAt(4, 4) == testArgb(0x07080980'u32)
    check rendered.pixelAt(64, 4) == testArgb(0x010203ff'u32)
    check rendered.pixelAt(64, 25) == testArgb(0x0a0b0cff'u32)
    check rendered.pixelAt(0, 10) == testArgb(0x101112ff'u32)
    check rendered.pixelAt(119, 10) == testArgb(0x101112ff'u32)
    check rendered.pixelAt(40, 0) == testArgb(0x101112ff'u32)
    check bar.frameTabIndexAt(5) == 0
    check bar.frameTabIndexAt(75) == 1
    check bar.frameTabIndexAt(1) == -1
    check bar.frameTabIndexAt(119) == -1

  test "empty frame chrome renderer keeps an input-capable interior":
    let frame = pv.ProjectedFrameEmptyChrome(
      frameId: 8,
      geom: pv.Rect(x: 0, y: 0, w: 120, h: 80),
      focused: false,
      ringWidth: 2,
      ringColor: 0x101112ff'u32,
      backgroundColor: 0x00000001'u32,
    )
    let rendered = renderFrameEmptyChromeBuffer(frame)
    check rendered.width == 120
    check rendered.height == 80
    check rendered.pixelAt(10, 10) == 0x01000000'u32
    check rendered.pixelAt(0, 10) == testArgb(0x101112ff'u32)
    check rendered.pixelAt(119, 10) == testArgb(0x101112ff'u32)

    let tinted = renderFrameEmptyChromeBuffer(
      pv.ProjectedFrameEmptyChrome(
        frameId: 9,
        geom: pv.Rect(x: 0, y: 0, w: 120, h: 80),
        ringWidth: 1,
        ringColor: 0x101112ff'u32,
        backgroundColor: 0x01020340'u32,
      )
    )
    check tinted.pixelAt(10, 10) == testArgb(0x01020340'u32)

  test "recent windows chrome converts RGBA config colors to ARGB pixels":
    var config = baseConfig()
    config.recentWindows.enabled = true
    config.recentWindows.openDelayMs = 0
    config.recentWindows.highlight.activeColor = 0x112233ff'u32
    config.recentWindows.highlight.padding = 12
    config.recentWindows.previews.maxHeight = 480
    config.recentWindows.previews.maxScale = 0.5
    var model = initRuntimeStateFromConfig(config).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.CmdRecentWindowNext),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let selected = model.recentWindowPreviews(screen).filterIt(it.selected)[0]
    let rendered = model.renderRecentWindowsChromeBuffer(screen)

    check rendered.pixelAt(
      selected.geom.x - screen.x - config.recentWindows.highlight.padding,
      selected.geom.y - screen.y - config.recentWindows.highlight.padding,
    ) == testArgb(config.recentWindows.highlight.activeColor)
    check rendered.pixelAt(
      selected.geom.x - screen.x + selected.geom.w div 2,
      selected.geom.y - screen.y + selected.geom.h + 1,
    ) ==
      premultiplyArgb(
        testArgb(
          (config.recentWindows.highlight.activeColor and 0xffffff00'u32) or 0x55'u32
        )
      )

  test "overview overlay frames empty workspace previews":
    var config = baseConfig()
    config.layout.borderWidth = 4
    config.layout.focusedBorderColor = 0x112233ff'u32
    config.layout.unfocusedBorderColor = 0x445566ff'u32
    var model = initRuntimeStateFromConfig(config).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 800, height: 600),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.CmdOpenOverview),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let occupiedPreview = model.workspacePreviewRect(screen, slots, slots.find(1'u32))
    let emptyPreview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let rendered = model.renderOverviewOverlayBuffer(screen)

    check rendered.pixelAt(occupiedPreview.x, occupiedPreview.y) == 0
    check rendered.pixelAt(occupiedPreview.x + 10, occupiedPreview.y + 10) == 0
    check rendered.pixelAt(emptyPreview.x + 10, emptyPreview.y + 10) ==
      OverviewEmptyWorkspaceFill
    check rendered.pixelAt(emptyPreview.x, emptyPreview.y) ==
      testArgb(config.layout.unfocusedBorderColor)

  test "overview overlay frames trailing dynamic empty workspace":
    var config = baseConfig()
    config.layout.borderWidth = 4
    config.layout.unfocusedBorderColor = 0x667788ff'u32
    var model = initRuntimeStateFromConfig(config).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 800, height: 600),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 3),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
      Msg(kind: MsgKind.CmdOpenOverview),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let trailingPreview = model.workspacePreviewRect(screen, slots, slots.find(4'u32))
    let rendered = model.renderOverviewOverlayBuffer(screen)

    check slots.find(4'u32) != -1
    check rendered.pixelAt(trailingPreview.x + 10, trailingPreview.y + 10) ==
      OverviewEmptyWorkspaceFill
    check rendered.pixelAt(trailingPreview.x, trailingPreview.y) ==
      testArgb(config.layout.unfocusedBorderColor)

  test "overview overlay uses focused color for active empty workspace":
    var config = baseConfig()
    config.layout.borderWidth = 4
    config.layout.focusedBorderColor = 0x99aabbff'u32
    var model = initRuntimeStateFromConfig(config).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 800, height: 600),
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2),
      Msg(kind: MsgKind.CmdOpenOverview),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let activePreview = model.workspacePreviewRect(screen, slots, slots.find(2'u32))
    let rendered = model.renderOverviewOverlayBuffer(screen)

    check rendered.pixelAt(activePreview.x + 10, activePreview.y + 10) ==
      OverviewEmptyWorkspaceFill
    check rendered.pixelAt(activePreview.x, activePreview.y) ==
      testArgb(config.layout.focusedBorderColor)

  test "overview overlay badges hidden deck stack windows":
    var config = baseConfig()
    config.layout.defaultMasterCount = 2
    config.layout.defaultMasterRatio = 0.55
    var model = initRuntimeStateFromConfig(config).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Deck),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 4, appId: "app", title: "Four"),
      Msg(kind: MsgKind.CmdOpenOverview),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let badge = model.overviewHiddenCountBadge(screen, slots, slots.find(1'u32))
    let rendered = model.renderOverviewOverlayBuffer(screen)

    check badge.count == 1
    check badge.rect.w > 0
    check rendered.pixels.anyIt(it == OverviewHiddenBadgeFill)

  test "overview overlay badges hidden monocle windows":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Monocle),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
      Msg(kind: MsgKind.CmdOpenOverview),
    ]:
      let (next, _) = model.update(msg)
      model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let badge = model.overviewHiddenCountBadge(screen, slots, slots.find(1'u32))

    check badge.count == 2
    check badge.rect.w > 0

  test "overview overlay renders horizontal scroller overflow indicators":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.overviewScrollerIndicators = true
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
    ]:
      let (next, _) = model.update(msg)
      model = next
    discard model.setTagViewportCurrent(model.activeTag, 100.0'f32, 0.0'f32)
    let (next, _) = model.update(Msg(kind: MsgKind.CmdOpenOverview))
    model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let indicator = model.overviewScrollIndicator(screen, slots, slots.find(1'u32))
    let rendered = model.renderOverviewOverlayBuffer(screen)

    check indicator.axis == OverviewScrollAxis.Horizontal
    check indicator.before
    check indicator.after
    check rendered.pixels.anyIt(it == OverviewScrollIndicatorColor)
    check rendered.pixelAt(
      indicator.rect.x + 2, indicator.rect.y + indicator.rect.h div 2
    ) == 0

  test "overview overlay hides scroller overflow indicators by default":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
    ]:
      let (next, _) = model.update(msg)
      model = next
    discard model.setTagViewportCurrent(model.activeTag, 100.0'f32, 0.0'f32)
    let (next, _) = model.update(Msg(kind: MsgKind.CmdOpenOverview))
    model = next

    let rendered = model.renderOverviewOverlayBuffer(model.primaryScreen())

    check not model.overviewScrollerIndicators
    check not rendered.pixels.anyIt(it == OverviewScrollIndicatorColor)

  test "overview overlay renders vertical scroller overflow indicators":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    for msg in [
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700),
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.VerticalScroller),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "app", title: "One"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "app", title: "Two"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 3, appId: "app", title: "Three"),
    ]:
      let (next, _) = model.update(msg)
      model = next
    discard model.setTagViewportCurrent(model.activeTag, 100.0'f32, 100.0'f32)
    let (next, _) = model.update(Msg(kind: MsgKind.CmdOpenOverview))
    model = next

    let screen = model.primaryScreen()
    let slots = model.previewSlots()
    let indicator = model.overviewScrollIndicator(screen, slots, slots.find(1'u32))

    check indicator.axis == OverviewScrollAxis.Vertical
    check indicator.before
    check indicator.after

  test "runtime update mutates model and returns effects":
    var state = initRuntimeStateFromConfig(baseConfig())
    let effects = state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 42, appId: "term", title: "Terminal")
    )
    let snapshot = state.readRuntimeSnapshot()

    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
        it.jsonPayload.contains("WindowOpenedOrChanged")
    )
    check state.model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].focusedWindow == 42

  test "switch-layout opens and expires layout switch toast":
    var config = baseConfig()
    config.layoutSwitchToast.enabled = true
    config.layoutSwitchToast.timeoutMs = 16
    config.layoutSwitchToast.ringColor = 0xff3b30ff'u32
    var model = initRuntimeStateFromConfig(config).model

    let (switched, _) = model.update(Msg(kind: MsgKind.CmdSwitchLayout))
    model = switched

    check model.layoutSwitchToastOpen
    check model.layoutSwitchToastLayout == LayoutMode.Deck
    check model.layoutSwitchToastElapsedMs == 0

    let (ticked, _) = model.update(Msg(kind: MsgKind.CmdTick))
    model = ticked

    check not model.layoutSwitchToastOpen

  test "custom layout command stores custom selection with fallback":
    var config = baseConfig()
    config.janet.layouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("spiral"), fallback: builtinSelection(LayoutMode.Grid)
        )
      ]
    config.layout.layoutSelections =
      @[
        builtinSelection(LayoutMode.Scroller),
        customSelection(janetLayoutId("spiral"), LayoutMode.Grid),
      ]
    config.layout.layoutCycle = @[LayoutMode.Scroller, LayoutMode.Grid]
    var model = initRuntimeStateFromConfig(config).model

    let (customSet, _) = model.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("spiral"))
    )
    model = customSet
    let active = model.tagData(model.activeTag).get()

    check active.layoutMode == LayoutMode.Grid
    check active.customLayoutId.layoutIdString() == "spiral"

    let snapshot = model.shellSnapshot()
    check snapshot.workspaces[0].layoutId == "spiral"
    check snapshot.workspaces[0].layoutKind == "custom"
    check snapshot.workspaces[0].fallbackLayout == "grid"

    let (builtinSet, _) =
      model.update(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Monocle))
    model = builtinSet
    check model.tagData(model.activeTag).get().customLayoutId.layoutIdString() == ""

  test "custom layout projection uses Janet geometry callback":
    var config = baseConfig()
    config.janet.layouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("spiral"), fallback: builtinSelection(LayoutMode.Grid)
        )
      ]
    var model = initRuntimeStateFromConfig(config).model
    let (withFirst, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model = withFirst
    let (withSecond, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model = withSecond
    let (customSet, _) = model.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("spiral"))
    )
    model = customSet

    proc customEval(context: JanetLayoutContext): JanetLayoutEvalResult =
      check context.layoutId.layoutIdString() == "spiral"
      JanetLayoutEvalResult(
        layoutId: context.layoutId,
        outcome: JanetLayoutOutcome.Applied,
        outputTargetKind: JanetLayoutTargetKind.Frame,
        instructions:
          @[
            pv.RenderInstruction(
              windowId: pv.ProjectionWindowId(10),
              geom: pv.Rect(x: 1, y: 2, w: 300, h: 400),
            ),
            pv.RenderInstruction(
              windowId: pv.ProjectionWindowId(11),
              geom: pv.Rect(x: 301, y: 2, w: 300, h: 400),
            ),
          ],
      )

    let projection = model.layoutProjection(customEval)

    check projection.instructions.len == 2
    check projection.instructions[0].geom == pv.Rect(x: 1, y: 2, w: 300, h: 400)
    check projection.instructions[1].geom == pv.Rect(x: 301, y: 2, w: 300, h: 400)

  test "native BSP splits focused leaf and projects all leaf windows":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    var updated = model.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model = updated[0]
    updated = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model = updated[0]
    updated = model.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model = updated[0]
    updated = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model = updated[0]
    updated = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))
    model = updated[0]

    let tagId = model.activeTag
    let active = model.tagData(tagId).get()
    check active.customLayoutId.layoutIdString() == "bsp"
    check active.nativeLayoutId.nativeLayoutIdString() == "bsp-tree"
    check model.bspRootForTag(tagId) != tc.NullBspNodeId
    check model.bspNodeForWindowOnTag(tagId, tc.WindowId(1)) != tc.NullBspNodeId
    check model.bspNodeForWindowOnTag(tagId, tc.WindowId(2)) != tc.NullBspNodeId
    check model.bspNodeForWindowOnTag(tagId, tc.WindowId(3)) != tc.NullBspNodeId
    check model.tagData(tagId).get().focusedWindow == tc.WindowId(3)

    let projection = model.layoutProjection()
    check projection.instructions.len == 3
    check projection.instructions.anyIt(it.windowId == 10'u32)
    check projection.instructions.anyIt(it.windowId == 11'u32)
    check projection.instructions.anyIt(it.windowId == 12'u32)

    updated = model.update(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 12))
    model = updated[0]
    check model.bspNodeForWindowOnTag(tagId, tc.WindowId(3)) == tc.NullBspNodeId
    let collapsed = model.layoutProjection()
    check collapsed.instructions.len == 2
    check collapsed.instructions.anyIt(it.windowId == 10'u32)
    check collapsed.instructions.anyIt(it.windowId == 11'u32)

  test "native BSP persists through live restore":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    var updated = model.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model = updated[0]
    updated = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model = updated[0]
    updated = model.update(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("bsp-tree"))
    )
    model = updated[0]
    updated = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model = updated[0]

    let restore = model.liveRestoreState()
    check restore.tags[1].nativeLayoutId.nativeLayoutIdString() == "bsp-tree"
    check restore.tags[1].bspNodes.len == 3

    var restored = initRuntimeStateFromConfig(baseConfig()).model
    restored.applyLiveRestore(restore.pendingRestoreState())
    updated = restored.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    restored = updated[0]
    updated = restored.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    restored = updated[0]

    let snapshot = restored.shellSnapshot()
    check snapshot.workspaces[0].layoutId == "bsp-tree"
    check snapshot.workspaces[0].bspNodes.len == 3
    let restoredProjection = restored.layoutProjection()
    check restoredProjection.instructions.len == 2
    check restoredProjection.instructions.anyIt(it.windowId == 10'u32)
    check restoredProjection.instructions.anyIt(it.windowId == 11'u32)

  test "BSP focus uses tree order and directional geometry":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusNext))
    check model.focusedWindowId() == 10
    model.applyMsg(Msg(kind: MsgKind.CmdFocusPrev))
    check model.focusedWindowId() == 12

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
    check model.focusedWindowId() == 10
    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown))
    check model.focusedWindowId() == 12

  test "BSP directional move swaps focused leaf window":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    let leftGeom = model.instructionGeom(10)
    let focusedGeom = model.instructionGeom(11)
    model.applyMsg(Msg(kind: MsgKind.CmdMoveWindowLeft))

    check model.focusedWindowId() == 11
    check model.instructionGeom(11) == leftGeom
    check model.instructionGeom(10) == focusedGeom

  test "BSP resize adjusts the focused split fence":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))

    let tagId = model.activeTag
    let focusedWin = model.windowForExternal(ExternalWindowId(11))
    let focusedNode = model.bspNodeForWindowOnTag(tagId, focusedWin)
    let parent = model.bspNodeData(focusedNode).get().parent
    let before = model.bspNodeData(parent).get().ratio

    model.applyMsg(Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 11))
    model.applyMsg(Msg(kind: MsgKind.CmdResizeHeight, deltaH: 0.1'f32))

    check model.bspNodeData(parent).get().ratio > before

  test "BSP balance and equalize update split ratios":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))

    let root = model.bspRootForTag(model.activeTag)
    model.applyMsg(Msg(kind: MsgKind.CmdBspBalance))
    check abs(model.bspNodeData(root).get().ratio - (1.0'f32 / 3.0'f32)) < 0.001'f32

    model.applyMsg(Msg(kind: MsgKind.CmdBspEqualize))
    check abs(model.bspNodeData(root).get().ratio - 0.5'f32) < 0.001'f32

  test "BSP removal adjusts promoted split by longest side":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    model.applyMsg(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model.applyMsg(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("bsp"))
    )
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))
    model.applyMsg(Msg(kind: MsgKind.WlWindowCreated, windowId: 13))

    model.applyMsg(Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 10))

    let root = model.bspRootForTag(model.activeTag)
    let rootData = model.bspNodeData(root).get()
    check rootData.kind == FrameNodeKind.Split
    check rootData.orientation == FrameSplitOrientation.Horizontal

  test "native frame-tree stores tabs and projects active frame windows":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    let (withOutput, _) = model.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model = withOutput
    let (withFirst, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model = withFirst
    let (withSecond, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model = withSecond
    let (nativeSet, _) = model.update(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    model = nativeSet

    let active = model.tagData(model.activeTag).get()
    check active.nativeLayoutId.nativeLayoutIdString() == "frame-tree"
    check model.windowsForFrame(active.focusedFrame) == @[
      tc.WindowId(1), tc.WindowId(2)
    ]
    let initialFrame = active.focusedFrame

    var projection = model.layoutProjection()
    check projection.instructions.len == 1
    check projection.instructions[0].windowId == 11'u32
    check projection.frameTabBars.len == 1
    check projection.frameTabBars[0].windowId == 11'u32
    check projection.frameTabBars[0].frameTabs.activeColor == DefaultFrameTabActiveColor
    check projection.frameTabBars[0].frameTabs.inactiveColor ==
      DefaultFrameTabInactiveColor
    check projection.frameTabBars[0].ringWidth == model.borderWidth
    check projection.frameTabBars[0].ringColor == model.focusedBorderColor
    check projection.frameTabBars[0].tabs.len == 2
    check projection.instructions[0].geom.y ==
      projection.frameTabBars[0].geom.y + projection.frameTabBars[0].geom.h

    let (split, _) = model.update(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    model = split
    let splitParent = model.frameData(initialFrame).get().parent
    check splitParent != tc.NullFrameId
    check model.frameData(splitParent).get().firstChild == initialFrame
    check model.windowsForFrame(initialFrame) == @[tc.WindowId(1)]
    check model.tagData(model.activeTag).get().focusedFrame != initialFrame
    let (withThird, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))
    model = withThird
    projection = model.layoutProjection()

    check projection.instructions.len == 2
    check projection.frameTabBars.len == 2
    check projection.instructions.anyIt(it.windowId == 10'u32)
    check projection.instructions.anyIt(it.windowId == 12'u32)
    check projection.instructions[0].geom.x < projection.instructions[1].geom.x

    var clickedFrame = tc.NullFrameId
    for frameId, _ in model.framesOnTagWithId(model.activeTag):
      if model.windowsForFrame(frameId) == @[tc.WindowId(2), tc.WindowId(3)]:
        clickedFrame = frameId
    let (tabClick, _) = model.update(
      Msg(
        kind: MsgKind.WlFrameTabClicked,
        frameClickFrameId: uint32(clickedFrame),
        frameClickTabIndex: 0,
      )
    )
    model = tabClick
    check model.tagData(model.activeTag).get().focusedWindow == tc.WindowId(2)
    let (tabNext, _) = model.update(Msg(kind: MsgKind.CmdFrameTabNext))
    model = tabNext
    check model.tagData(model.activeTag).get().focusedWindow == tc.WindowId(3)

    block:
      var parityConfig = baseConfig()
      parityConfig.layout.gaps = 4
      parityConfig.layout.borderWidth = 2
      parityConfig.layout.focusedBorderColor = 0x9b8ec4ff'u32
      parityConfig.layout.unfocusedBorderColor = 0x2a2636ff'u32
      var parityModel = initRuntimeStateFromConfig(parityConfig).model
      let (parityOutput, _) = parityModel.update(
        Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1920, height: 1080)
      )
      parityModel = parityOutput
      for externalId in [60'u32, 61'u32]:
        let (withWindow, _) =
          parityModel.update(Msg(kind: MsgKind.WlWindowCreated, windowId: externalId))
        parityModel = withWindow
      let (parityNative, _) = parityModel.update(
        Msg(
          kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree")
        )
      )
      parityModel = parityNative
      let (paritySplit, _) =
        parityModel.update(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
      parityModel = paritySplit

      let parityRects = parityModel.frameTreeLayoutRects(
        parityModel.activeTag, pv.Rect(x: 0, y: 0, w: 1920, h: 1080), 99, 4
      )
      check parityRects.anyIt(it.rect == pv.Rect(x: 0, y: 0, w: 958, h: 1080))
      check parityRects.anyIt(it.rect == pv.Rect(x: 962, y: 0, w: 958, h: 1080))

      let parityInstructions = parityModel.layoutFrameTree(
        parityModel.activeTag, pv.Rect(x: 0, y: 0, w: 1920, h: 1080), 99, 4
      )
      let parityBars = parityModel.frameTreeTabBars(
        parityModel.activeTag, pv.Rect(x: 0, y: 0, w: 1920, h: 1080), 99, 4
      )
      let parityEmpty = parityModel.frameTreeEmptyChrome(
        parityModel.activeTag, pv.Rect(x: 0, y: 0, w: 1920, h: 1080), 99, 4
      )
      check parityEmpty.len == 0
      check parityBars.anyIt(it.geom == pv.Rect(x: 0, y: 0, w: 958, h: 24))
      check parityBars.anyIt(it.geom == pv.Rect(x: 962, y: 0, w: 958, h: 24))
      check parityInstructions.anyIt(
        it.windowId == 60'u32 and it.geom == pv.Rect(x: 2, y: 26, w: 954, h: 1052)
      )
      check parityInstructions.anyIt(
        it.windowId == 61'u32 and it.geom == pv.Rect(x: 964, y: 26, w: 954, h: 1052)
      )

    block:
      var moveModel = initRuntimeStateFromConfig(baseConfig()).model
      let (moveOutput, _) = moveModel.update(
        Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
      )
      moveModel = moveOutput
      for externalId in [30'u32, 31'u32]:
        let (withWindow, _) =
          moveModel.update(Msg(kind: MsgKind.WlWindowCreated, windowId: externalId))
        moveModel = withWindow
      let (moveNative, _) = moveModel.update(
        Msg(
          kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree")
        )
      )
      moveModel = moveNative
      let (movedToNonFrame, _) =
        moveModel.update(Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2))
      moveModel = movedToNonFrame
      var movedProjection = moveModel.layoutProjection()
      check movedProjection.frameTabBars.len == 0
      let (backToFrameTree, _) =
        moveModel.update(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 1))
      moveModel = backToFrameTree
      movedProjection = moveModel.layoutProjection()
      check movedProjection.frameTabBars.allIt(it.windowId != 31'u32)

    var singleFrame = initRuntimeStateFromConfig(baseConfig()).model
    let (singleOutput, _) = singleFrame.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    singleFrame = singleOutput
    for externalId in [20'u32, 21'u32, 22'u32, 23'u32]:
      let (withWindow, _) =
        singleFrame.update(Msg(kind: MsgKind.WlWindowCreated, windowId: externalId))
      singleFrame = withWindow
    let (singleNative, _) = singleFrame.update(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    singleFrame = singleNative
    let singleFrameInitialFocus =
      singleFrame.tagData(singleFrame.activeTag).get().focusedWindow
    let (singleFocusLeft, _) = singleFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft)
    )
    singleFrame = singleFocusLeft
    check singleFrame.tagData(singleFrame.activeTag).get().focusedWindow ==
      singleFrameInitialFocus
    let (singleFocusRight, _) = singleFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
    )
    singleFrame = singleFocusRight
    check singleFrame.tagData(singleFrame.activeTag).get().focusedWindow ==
      singleFrameInitialFocus
    for direction in [Direction.DirUp, Direction.DirDown]:
      let (afterFocus, _) =
        singleFrame.update(Msg(kind: MsgKind.CmdFocusDirection, direction: direction))
      singleFrame = afterFocus
      check singleFrame.tagData(singleFrame.activeTag).get().focusedWindow ==
        singleFrameInitialFocus
    let (tabPrev, _) = singleFrame.update(Msg(kind: MsgKind.CmdFrameTabPrev))
    singleFrame = tabPrev
    check singleFrame.tagData(singleFrame.activeTag).get().focusedWindow !=
      singleFrameInitialFocus
    let (singleTabNext, _) = singleFrame.update(Msg(kind: MsgKind.CmdFrameTabNext))
    singleFrame = singleTabNext
    check singleFrame.tagData(singleFrame.activeTag).get().focusedWindow ==
      singleFrameInitialFocus

    var notionFrame = initRuntimeStateFromConfig(
      block:
        var config = baseConfig()
        config.janet.layouts =
          @[
            JanetLayoutConfig(
              id: janetLayoutId("notion"),
              fallback:
                nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
            )
          ]
        config
    ).model
    let (notionOutput, _) = notionFrame.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    notionFrame = notionOutput
    for externalId in [50'u32, 51'u32, 52'u32, 53'u32]:
      let (withWindow, _) =
        notionFrame.update(Msg(kind: MsgKind.WlWindowCreated, windowId: externalId))
      notionFrame = withWindow
    let (notionSet, _) = notionFrame.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("notion"))
    )
    notionFrame = notionSet
    let notionInitialTag = notionFrame.tagData(notionFrame.activeTag).get()
    let notionInitialFocus = notionInitialTag.focusedWindow
    let notionInitialFrame = notionInitialTag.focusedFrame
    check notionInitialTag.nativeLayoutId.nativeLayoutIdString() == "frame-tree"
    check notionFrame.windowsForFrame(notionInitialFrame) ==
      @[tc.WindowId(1), tc.WindowId(2), tc.WindowId(3), tc.WindowId(4)]
    check notionFrame.frameData(notionInitialFrame).get().activeWindow ==
      notionInitialFocus
    let (notionFocusLeft, _) = notionFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft)
    )
    notionFrame = notionFocusLeft
    check notionFrame.tagData(notionFrame.activeTag).get().focusedWindow ==
      notionInitialFocus
    let (notionFocusRight, _) = notionFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirRight)
    )
    notionFrame = notionFocusRight
    check notionFrame.tagData(notionFrame.activeTag).get().focusedWindow ==
      notionInitialFocus
    check notionFrame.frameData(notionInitialFrame).get().activeWindow ==
      notionInitialFocus
    for direction in [Direction.DirUp, Direction.DirDown]:
      let (afterFocus, _) =
        notionFrame.update(Msg(kind: MsgKind.CmdFocusDirection, direction: direction))
      notionFrame = afterFocus
      let tag = notionFrame.tagData(notionFrame.activeTag).get()
      check tag.focusedWindow == notionInitialFocus
      check tag.focusedFrame == notionInitialFrame
      check notionFrame.frameData(notionInitialFrame).get().activeWindow ==
        notionInitialFocus
    let (notionTabPrev, _) = notionFrame.update(Msg(kind: MsgKind.CmdFrameTabPrev))
    notionFrame = notionTabPrev
    check notionFrame.tagData(notionFrame.activeTag).get().focusedWindow !=
      notionInitialFocus

    var twoFrame = initRuntimeStateFromConfig(baseConfig()).model
    let (twoOutput, _) = twoFrame.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    twoFrame = twoOutput
    let (twoFirst, _) =
      twoFrame.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 30))
    twoFrame = twoFirst
    let (twoNative, _) = twoFrame.update(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    twoFrame = twoNative
    for externalId in [31'u32, 32'u32, 33'u32]:
      let (withWindow, _) =
        twoFrame.update(Msg(kind: MsgKind.WlWindowCreated, windowId: externalId))
      twoFrame = withWindow
      if externalId == 31'u32:
        let (twoSplit, _) = twoFrame.update(Msg(kind: MsgKind.CmdFrameSplitVertical))
        twoFrame = twoSplit
    let rightFrameFocus = twoFrame.tagData(twoFrame.activeTag).get().focusedWindow
    let (focusUp, _) =
      twoFrame.update(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp))
    twoFrame = focusUp
    check twoFrame.tagData(twoFrame.activeTag).get().focusedWindow == tc.WindowId(1)
    let (focusDown, _) = twoFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)
    )
    twoFrame = focusDown
    check twoFrame.tagData(twoFrame.activeTag).get().focusedWindow == rightFrameFocus

    block:
      var staleFrameFocus = twoFrame
      let focusedBefore = staleFrameFocus.tagData(staleFrameFocus.activeTag).get()
      var firstSplit = tc.NullFrameId
      for frameId, frame in staleFrameFocus.framesOnTagWithId(staleFrameFocus.activeTag):
        if frame.kind == FrameNodeKind.Split:
          firstSplit = frameId
          break
      check firstSplit != tc.NullFrameId
      staleFrameFocus.tags.mEntity(staleFrameFocus.activeTag).focusedFrame = firstSplit
      let (repairedFocus, _) = staleFrameFocus.update(
        Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)
      )
      staleFrameFocus = repairedFocus
      check staleFrameFocus.tagData(staleFrameFocus.activeTag).get().focusedWindow ==
        tc.WindowId(1)
      check staleFrameFocus.tagData(staleFrameFocus.activeTag).get().focusedFrame !=
        firstSplit
      check staleFrameFocus.tagData(staleFrameFocus.activeTag).get().focusedFrame !=
        focusedBefore.focusedFrame

    block:
      var mismatchedFrameFocus = twoFrame
      let wrongOccupiedFrame = mismatchedFrameFocus.frameForWindowOnTag(
        mismatchedFrameFocus.activeTag, tc.WindowId(1)
      )
      check wrongOccupiedFrame != tc.NullFrameId
      check mismatchedFrameFocus
      .tagData(mismatchedFrameFocus.activeTag)
      .get().focusedWindow == rightFrameFocus
      mismatchedFrameFocus.tags.mEntity(mismatchedFrameFocus.activeTag).focusedFrame =
        wrongOccupiedFrame
      let (repairedFocus, _) = mismatchedFrameFocus.update(
        Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)
      )
      mismatchedFrameFocus = repairedFocus
      check mismatchedFrameFocus
      .tagData(mismatchedFrameFocus.activeTag)
      .get().focusedWindow == tc.WindowId(1)

    var emptyFrame = initRuntimeStateFromConfig(baseConfig()).model
    let (emptyOutput, _) = emptyFrame.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    emptyFrame = emptyOutput
    let (emptyFirst, _) =
      emptyFrame.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 40))
    emptyFrame = emptyFirst
    let (emptyNative, _) = emptyFrame.update(
      Msg(kind: MsgKind.CmdSetNativeLayout, nativeLayout: nativeLayoutId("frame-tree"))
    )
    emptyFrame = emptyNative
    let initialEmptyModelFrame =
      emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame
    let (emptySplit, _) = emptyFrame.update(Msg(kind: MsgKind.CmdFrameSplitVertical))
    emptyFrame = emptySplit
    let emptyProjection = emptyFrame.layoutProjection()
    check emptyProjection.frameEmptyChrome.len == 1
    let emptyTag = emptyFrame.tagData(emptyFrame.activeTag).get()
    let occupiedLeaf = emptyTag.focusedFrame
    check occupiedLeaf == initialEmptyModelFrame
    var emptyLeaf = tc.NullFrameId
    for frameId, frame in emptyFrame.framesOnTagWithId(emptyFrame.activeTag):
      if frame.kind == FrameNodeKind.Leaf and
          emptyFrame.windowsForFrame(frameId).len == 0:
        emptyLeaf = frameId
    check emptyLeaf != tc.NullFrameId
    check occupiedLeaf != tc.NullFrameId
    check emptyLeaf != occupiedLeaf
    check emptyFrame.windowsForFrame(occupiedLeaf) == @[tc.WindowId(1)]
    block:
      var targetedEmpty = emptyFrame
      let focusedWindowBeforePointer =
        targetedEmpty.tagData(targetedEmpty.activeTag).get().focusedWindow
      let (focusedByPointer, _) = targetedEmpty.update(
        Msg(kind: MsgKind.WlFrameEmptyFocused, frameFocusFrameId: uint32(emptyLeaf))
      )
      targetedEmpty = focusedByPointer
      check targetedEmpty.tagData(targetedEmpty.activeTag).get().focusedFrame ==
        emptyLeaf
      check targetedEmpty.tagData(targetedEmpty.activeTag).get().focusedWindow ==
        focusedWindowBeforePointer
      let (placedInEmpty, _) =
        targetedEmpty.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 41))
      targetedEmpty = placedInEmpty
      check targetedEmpty.windowsForFrame(emptyLeaf) == @[tc.WindowId(2)]
      check targetedEmpty.tagData(targetedEmpty.activeTag).get().focusedWindow ==
        tc.WindowId(2)
    let (emptyFocusDown, _) = emptyFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)
    )
    emptyFrame = emptyFocusDown
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame == emptyLeaf
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedWindow == tc.WindowId(1)
    check not emptyFrame.windowRenderFocused(40'u32)
    block:
      var emptyOverview = emptyFrame
      let (emptyOverviewOpen, _) =
        emptyOverview.update(Msg(kind: MsgKind.CmdOpenOverview))
      emptyOverview = emptyOverviewOpen
      check emptyOverview.overviewActive
      check emptyOverview.selectedOverviewWindow() == tc.NullWindowId
      check not emptyOverview.windowRenderFocused(40'u32)
    var emptyFrameCountBeforeEmptySplit = 0
    for _, _ in emptyFrame.framesOnTagWithId(emptyFrame.activeTag):
      inc emptyFrameCountBeforeEmptySplit
    let originalEmptyLeaf = emptyLeaf
    let (emptyNestedSplit, _) =
      emptyFrame.update(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    emptyFrame = emptyNestedSplit
    var emptyFrameCountAfterEmptySplit = 0
    for _, _ in emptyFrame.framesOnTagWithId(emptyFrame.activeTag):
      inc emptyFrameCountAfterEmptySplit
    check emptyFrameCountAfterEmptySplit == emptyFrameCountBeforeEmptySplit + 2
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame ==
      originalEmptyLeaf
    check emptyFrame.layoutProjection().frameEmptyChrome.len == 2
    let (emptyNestedUnsplit, _) = emptyFrame.update(Msg(kind: MsgKind.CmdFrameUnsplit))
    emptyFrame = emptyNestedUnsplit
    var emptyFrameCountAfterNestedUnsplit = 0
    for _, _ in emptyFrame.framesOnTagWithId(emptyFrame.activeTag):
      inc emptyFrameCountAfterNestedUnsplit
    check emptyFrameCountAfterNestedUnsplit == emptyFrameCountBeforeEmptySplit
    emptyLeaf = emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame
    check emptyLeaf != tc.NullFrameId
    check emptyLeaf != originalEmptyLeaf
    check emptyFrame.windowsForFrame(emptyLeaf).len == 0
    let (emptyFocusUpAgain, _) = emptyFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirUp)
    )
    emptyFrame = emptyFocusUpAgain
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame == occupiedLeaf
    check emptyFrame.windowRenderFocused(40'u32)
    let (emptyFocusDownAgain, _) = emptyFrame.update(
      Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirDown)
    )
    emptyFrame = emptyFocusDownAgain
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame == emptyLeaf
    let (emptyUnsplit, _) = emptyFrame.update(Msg(kind: MsgKind.CmdFrameUnsplit))
    emptyFrame = emptyUnsplit
    var emptyFrameCountAfterUnsplit = 0
    for _, _ in emptyFrame.framesOnTagWithId(emptyFrame.activeTag):
      inc emptyFrameCountAfterUnsplit
    check emptyFrameCountAfterUnsplit == emptyFrameCountBeforeEmptySplit - 2
    check emptyFrame.tagData(emptyFrame.activeTag).get().focusedFrame == occupiedLeaf
    check emptyFrame.windowsForFrame(occupiedLeaf) == @[tc.WindowId(1)]
    check emptyFrame.layoutProjection().frameEmptyChrome.len == 0

    let snapshot = model.shellSnapshot()
    check snapshot.workspaces[0].layoutId == "frame-tree"
    check snapshot.workspaces[0].layoutKind == "native"
    check snapshot.workspaces[0].fallbackLayout == "scroller"
    check snapshot.workspaces[0].frames.len == 3

    let restore = model.liveRestoreState()
    check restore.tags[1].nativeLayoutId.nativeLayoutIdString() == "frame-tree"
    check restore.tags[1].frames.len == 3

    var restored = initRuntimeStateFromConfig(baseConfig())
    check restored.applyRuntimeLiveRestore(restore)
    for externalId in [10'u32, 11'u32, 12'u32]:
      discard restored.applyRuntimeUpdate(
        Msg(kind: MsgKind.WlWindowCreated, windowId: externalId)
      )
    let restoredSnapshot = restored.readRuntimeSnapshot()
    check restoredSnapshot.workspaces[0].layoutId == "frame-tree"
    check restoredSnapshot.workspaces[0].layoutKind == "native"
    check restoredSnapshot.workspaces[0].frames.len == 3
    check restoredSnapshot.workspaces[0].frames.anyIt(
      it.windows == @[10'u32] and it.activeWindow == 10'u32
    )
    check restoredSnapshot.workspaces[0].frames.anyIt(
      it.windows == @[11'u32, 12'u32] and it.activeWindow == 12'u32
    )

    let restoredProjection = restored.applyRuntimeLayoutProjection()
    check restoredProjection.instructions.len == 2
    check restoredProjection.instructions.anyIt(it.windowId == 10'u32)
    check restoredProjection.instructions.anyIt(it.windowId == 12'u32)

  test "custom layout with frame-tree fallback receives frame rects and falls back native":
    var config = baseConfig()
    config.janet.layouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("frame-custom"),
          fallback: nativeSelection(nativeLayoutId("frame-tree"), LayoutMode.Scroller),
        )
      ]
    var model = initRuntimeStateFromConfig(config).model
    let (withOutput, _) = model.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 0, width: 1000, height: 700)
    )
    model = withOutput
    let (withFirst, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 10))
    model = withFirst
    let (withSecond, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 11))
    model = withSecond
    let (customSet, _) = model.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("frame-custom"))
    )
    model = customSet
    let (split, _) = model.update(Msg(kind: MsgKind.CmdFrameSplitHorizontal))
    model = split
    let (withThird, _) = model.update(Msg(kind: MsgKind.WlWindowCreated, windowId: 12))
    model = withThird

    proc customEval(context: JanetLayoutContext): JanetLayoutEvalResult =
      check context.layoutId.layoutIdString() == "frame-custom"
      check context.tag.frames.len == 3
      check context.tag.frames.anyIt(it.kind == FrameNodeKind.Leaf and it.rectSet)
      JanetLayoutEvalResult(
        layoutId: context.layoutId,
        outcome: JanetLayoutOutcome.Applied,
        outputTargetKind: JanetLayoutTargetKind.Frame,
        instructions:
          @[
            pv.RenderInstruction(
              windowId: pv.ProjectionWindowId(10),
              geom: pv.Rect(x: 5, y: 6, w: 300, h: 400),
            ),
            pv.RenderInstruction(
              windowId: pv.ProjectionWindowId(12),
              geom: pv.Rect(x: 305, y: 6, w: 300, h: 400),
            ),
          ],
      )

    var projection = model.layoutProjection(customEval)
    check projection.instructions.len == 2
    check projection.instructions.anyIt(
      it.windowId == 10'u32 and it.geom == pv.Rect(x: 5, y: 30, w: 300, h: 376)
    )
    check projection.instructions.anyIt(
      it.windowId == 12'u32 and it.geom == pv.Rect(x: 305, y: 30, w: 300, h: 376)
    )
    check projection.frameTabBars.len == 2
    check projection.frameTabBars.anyIt(
      it.windowId == 10'u32 and it.geom == pv.Rect(x: 5, y: 6, w: 300, h: 24) and
        it.tabs.len == 1
    )
    let customInitialFocus = model.tagData(model.activeTag).get().focusedWindow
    let (customFocusLeft, _) =
      model.update(Msg(kind: MsgKind.CmdFocusDirection, direction: Direction.DirLeft))
    model = customFocusLeft
    check model.tagData(model.activeTag).get().focusedWindow != customInitialFocus

    proc invalidEval(context: JanetLayoutContext): JanetLayoutEvalResult =
      JanetLayoutEvalResult(
        layoutId: context.layoutId, outcome: JanetLayoutOutcome.Invalid
      )

    projection = model.layoutProjection(invalidEval)
    check projection.instructions.len == 2
    check projection.instructions.anyIt(it.windowId == 10'u32)
    check projection.instructions.anyIt(it.windowId == 12'u32)
    check projection.instructions[0].geom.x < projection.instructions[1].geom.x

  test "explicit active layout command opens layout switch toast":
    var config = baseConfig()
    config.layoutSwitchToast.enabled = true
    config.layoutSwitchToast.timeoutMs = 900
    var model = initRuntimeStateFromConfig(config).model

    let (setGrid, _) =
      model.update(Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid))
    model = setGrid

    check model.layoutSwitchToastOpen
    check model.layoutSwitchToastLayout == LayoutMode.Grid
    check model.layoutSwitchToastCustomLayout.layoutIdString() == ""

  test "custom layout command opens toast with custom layout id":
    var config = baseConfig()
    config.layoutSwitchToast.enabled = true
    config.layoutSwitchToast.timeoutMs = 900
    config.janet.layouts =
      @[
        JanetLayoutConfig(
          id: janetLayoutId("notion"),
          fallback:
            nativeSelection(nativeLayoutId(FrameTreeLayoutId), LayoutMode.Scroller),
        )
      ]
    var model = initRuntimeStateFromConfig(config).model

    let (setNotion, _) = model.update(
      Msg(kind: MsgKind.CmdSetCustomLayout, customLayout: janetLayoutId("notion"))
    )
    model = setNotion

    check model.layoutSwitchToastOpen
    check model.layoutSwitchToastLayout == LayoutMode.Scroller
    check model.layoutSwitchToastCustomLayout.layoutIdString() == "notion"

  test "layout switch toast ignores targeted layout command and disabled config":
    var config = baseConfig()
    config.layoutSwitchToast.enabled = true
    config.layoutSwitchToast.timeoutMs = 900
    var model = initRuntimeStateFromConfig(config).model

    let (setTarget, _) = model.update(
      Msg(kind: MsgKind.CmdSetLayout, newLayout: LayoutMode.Grid, layoutTargetTag: 2)
    )
    model = setTarget

    check not model.layoutSwitchToastOpen

    config.layoutSwitchToast.enabled = false
    model = initRuntimeStateFromConfig(config).model
    let (disabledSwitch, _) = model.update(Msg(kind: MsgKind.CmdSwitchLayout))
    model = disabledSwitch

    check not model.layoutSwitchToastOpen

  test "runtime config reload preserves live state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 42, appId: "term", title: "Terminal")
    )

    let reloaded = Config(
      layout:
        LayoutConfig(gaps: 30, layoutCycle: @[LayoutMode.Monocle, LayoutMode.Deck]),
      workspaces: WorkspaceConfig(defaultCount: 4),
      tagRules:
        @[
          TagRule(
            tagId: 1,
            name: "renamed",
            defaultLayoutSet: true,
            defaultLayout: LayoutMode.Monocle,
          )
        ],
    )
    check state.applyRuntimeConfig(reloaded)

    let snapshot = state.readRuntimeSnapshot()
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 30
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].name == "renamed"
    check snapshot.workspaces[0].layoutMode == LayoutMode.Scroller

  test "runtime live restore applies to model":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    var restore = LiveRestoreState(activeTag: 2, focusedWindow: 50)
    restore.outputTags[1] = 1
    restore.tags[2] = RestoredTagState(
      tagId: 2,
      name: "restored-web",
      layoutMode: LayoutMode.Deck,
      focusedWindow: 50,
      targetViewportXOffset: 320.0,
      currentViewportXOffset: 280.0,
      targetViewportYOffset: 40.0,
      currentViewportYOffset: 20.0,
      columns:
        @[
          RestoredColumnState(
            windows: @[50'u32],
            widthProportion: 0.75,
            scrollerSingleProportion: 0.55,
            isFullWidth: true,
          )
        ],
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    restore.windows[50] = RestoredWindowState(
      tagId: 2,
      appId: "browser",
      title: "Browser",
      widthProportion: 0.75,
      heightProportion: 0.8,
      isFloating: true,
      floatingGeom: Rect(x: 100, y: 80, w: 640, h: 480),
      manualFloatingPosition: true,
    )
    restore.tagByWindow[50] = 2

    check state.applyRuntimeLiveRestore(restore)
    let restoredSnapshot = state.readRuntimeSnapshot()
    check state.model.outputTags[state.model.primaryOutput] == state.model.activeTag
    check restoredSnapshot.activeTag == 2
    check restoredSnapshot.activeWorkspaceIdx == 2
    check restoredSnapshot.workspaces[1].isActive
    check restoredSnapshot.workspaces[1].layoutMode == LayoutMode.Scroller
    check restoredSnapshot.workspaces[1].layoutId == "deck"
    check restoredSnapshot.workspaces[1].layoutSource == "bundled-janet"
    check restoredSnapshot.workspaces[1].targetViewportXOffset == 320.0'f32
    check restoredSnapshot.workspaces[1].currentViewportXOffset == 280.0'f32
    check restoredSnapshot.workspaces[1].targetViewportYOffset == 40.0'f32
    check restoredSnapshot.workspaces[1].currentViewportYOffset == 20.0'f32

    discard state.applyRuntimeUpdate(
      Msg(
        kind: MsgKind.WlWindowCreated, windowId: 50, appId: "browser", title: "Browser"
      )
    )
    discard state.applyRuntimeLayoutProjection()

    let snapshot = state.readRuntimeSnapshot()
    check snapshot.activeTag == 2
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 50
    check snapshot.windows[0].workspaceIdx == 2
    check snapshot.workspaces[1].layoutMode == LayoutMode.Scroller
    check snapshot.workspaces[1].layoutId == "deck"
    check snapshot.workspaces[1].layoutSource == "bundled-janet"
    check snapshot.workspaces[1].targetViewportXOffset == 320.0'f32
    check snapshot.workspaces[1].currentViewportXOffset == 280.0'f32
    check snapshot.workspaces[1].targetViewportYOffset == 40.0'f32
    check snapshot.workspaces[1].currentViewportYOffset == 20.0'f32
    check snapshot.workspaces[1].columns.len == 0
    check snapshot.windows[0].isFloating
    check snapshot.windows[0].floatingGeom == Rect(x: 100, y: 80, w: 640, h: 480)
    let restoredWinId = state.model.windowForExternal(ExternalWindowId(50))
    check state.model.windowData(restoredWinId).get().manualFloatingPosition
    let restoredTagId = state.model.tagForSlot(2)
    let restoredColumnId = state.model.columnAt(restoredTagId, 0)
    check state.model.columnData(restoredColumnId).get().scrollerSingleProportion ==
      0.55'f32

  test "runtime live restore preserves persisted empty dynamic workspace":
    var state = initRuntimeStateFromConfig(baseConfig())
    var restore = LiveRestoreState(activeTag: 2)
    restore.tags[4] = RestoredTagState(
      tagId: 4,
      name: "chat",
      layoutMode: LayoutMode.Deck,
      masterCount: 1,
      masterSplitRatio: 0.5,
    )
    restore.workspaceHistory = @[4'u32, 2'u32]

    check state.applyRuntimeLiveRestore(restore)
    let tagId = state.model.tagForSlot(4)
    check tagId != NullTagId
    let tag = state.model.tagData(tagId).get()
    check tag.name == "chat"
    check tag.layoutMode == LayoutMode.Scroller
    check tag.customLayoutId.layoutIdString() == "deck"
    check state.readRuntimeLiveRestoreJson().contains("\"id\":4")

    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "term", title: "Term")
    )
    check state.model.tagForSlot(4) != NullTagId

  test "runtime live restore keeps active empty dynamic workspace":
    var state = initRuntimeStateFromConfig(baseConfig())
    var restore = LiveRestoreState(activeTag: 4)
    restore.tags[4] = RestoredTagState(
      tagId: 4,
      name: "chat",
      layoutMode: LayoutMode.Monocle,
      masterCount: 1,
      masterSplitRatio: 0.5,
    )

    check state.applyRuntimeLiveRestore(restore)
    let snapshot = state.readRuntimeSnapshot()
    check snapshot.activeTag == 4
    check state.model.activeSlot == 4
    check state.model.tagData(state.model.activeTag).get().name == "chat"
    check state.model.tagData(state.model.activeTag).get().layoutMode ==
      LayoutMode.Scroller
    check state.model.tagData(state.model.activeTag).get().customLayoutId.layoutIdString() ==
      "monocle"

  test "layout projection reads and applies directly from state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "term", title: "Terminal")
    )
    let projection = state.applyRuntimeLayoutProjection()

    check projection.instructions.len == 1
    check projection.instructions[0].windowId == 10
    check state.model.layoutInstructions().len == 1

  test "snapshot and live restore reads come from state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 10, appId: "term", title: "Terminal")
    )

    let snapshot = state.readRuntimeSnapshot()
    let restoreJson = parseJson(state.readRuntimeLiveRestoreJson())
    check snapshot.windows[0].id == 10
    check restoreJson["schema"].getStr() == LiveRestoreSchema
    check restoreJson["restore_status"].getStr() == LiveRestoreStatusPending
    check restoreJson["windows"][0]["id"].getInt() == 10

  test "direct reducer keeps invariants over a short lifecycle":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    for msg in [
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "a", title: "A"),
      Msg(kind: MsgKind.WlWindowCreated, windowId: 2, appId: "b", title: "B"),
      Msg(kind: MsgKind.CmdFocusWindowById, focusWindowId: 1),
      Msg(kind: MsgKind.CmdMoveToWorkspaceIndex, workspaceIndex: 2),
      Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2),
      Msg(kind: MsgKind.CmdToggleFloating),
      Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 1),
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok

    let snapshot = model.shellSnapshot()
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 2

  test "invariants reject focused window not placed on tag":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    let (next, _) = model.update(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "a", title: "A")
    )
    model = next

    let (focusedNext, _) =
      model.update(Msg(kind: MsgKind.CmdFocusWorkspaceIndex, workspaceIndex: 2))
    model = focusedNext

    let tagTwo = model.tagForSlot(2)
    discard model.setTagFocus(tagTwo, model.windowForExternal(ExternalWindowId(1)))

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(
      it.message.contains("tag focused window is not placed on tag")
    )

  test "invariants reject minimized focused window":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    let (next, _) = model.update(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "a", title: "A")
    )
    model = next

    let winId = model.windowForExternal(ExternalWindowId(1))
    discard model.setWindowMinimized(winId, true)

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(it.message.contains("tag focused window is minimized"))

  test "invariants reject active output tag drift":
    var model = initRuntimeStateFromConfig(baseConfig()).model
    let (outputModel, _) = model.update(
      Msg(kind: MsgKind.WlOutputDimensions, outputId: 1, width: 1000, height: 700)
    )
    model = outputModel
    let (next, _) = model.update(
      Msg(kind: MsgKind.WlWindowCreated, windowId: 1, appId: "a", title: "A")
    )
    model = next

    let activeOutput = model.activeOutput
    model.outputTags[activeOutput] = model.tagForSlot(2)

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(
      it.message.contains("active output tag does not match active tag")
    )
