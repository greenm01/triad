import std/[json, options, os, sequtils, strutils, tables, unittest]
import ../src/config/parser
import ../src/core/[effects, msg, restore_state]
import ../src/daemon/hotkey_overlay_render
import ../src/daemon/exit_session_dialog_render
import ../src/daemon/layout_switch_toast_render
import ../src/daemon/overlay_text_render
import ../src/daemon/overview_overlay_render
import ../src/daemon/recent_windows_overlay_render
import ../src/state/engine except WindowId
import ../src/state/[invariants, snapshot]
import
  ../src/systems/
    [layout_projection, overview_geometry, recent_windows, runtime_facade, update]
import ../src/types/[model, runtime_values]

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
    tagRules: @[
      TagRule(tagId: 1, name: "main"),
      TagRule(
        tagId: 2, name: "web", defaultLayoutSet: true, defaultLayout: LayoutMode.Grid
      ),
    ],
    hotkeyOverlay: HotkeyOverlayConfig(skipAtStartup: true),
    terminal: TerminalConfig(command: @["foot"]),
  )

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

  test "triad entrypoint stays thin":
    let source = readFile("src/triad.nim")
    check source.splitLines().len <= 30
    check not source.contains("var daemon")
    check not source.contains("template ")
    check source.contains("import daemon/app")

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
    let rows = @[
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
      tagRules: @[
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
      columns: @[
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
    check restoredSnapshot.workspaces[1].layoutMode == LayoutMode.Deck
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
    check snapshot.workspaces[1].layoutMode == LayoutMode.Deck
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
    check tag.layoutMode == LayoutMode.Deck
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
      LayoutMode.Monocle

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
