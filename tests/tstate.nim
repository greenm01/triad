import json, options, os, sequtils, strutils, tables, unittest
import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/restore_state
import ../src/state/engine except WindowId
import ../src/state/invariants
import ../src/state/snapshot
import ../src/systems/layout_projection
import ../src/systems/runtime_facade
import ../src/systems/update
import ../src/types/model
import ../src/types/runtime_values

const DeletedRuntimeModules = [
  "src/types/legacy_model.nim",
  "src/core/model.nim",
  "src/core/model_utils.nim",
  "src/core/update.nim",
  "src/core/shell_state.nim",
  "src/config/legacy_apply.nim",
  "src/systems/layout_state.nim",
  "src/state/dod_adapter.nim",
  "src/systems/runtime_update_sync.nim",
  "src/systems/layout_projection_sync.nim",
  "src/systems/state_application_sync.nim",
  "src/systems/projection_read_sync.nim",
  "src/systems/dod_shadow_runtime.nim",
  "src/systems/dod_shadow_health.nim",
  "src/types/dod_shadow_health.nim"
]

const MaxKnownOverlongLines = 108

proc baseConfig(): Config =
  Config(
    layout: LayoutConfig(
      gaps: 12,
      defaultColumnWidth: 0.6,
      defaultWindowWidth: 0.8,
      defaultWindowHeight: 0.7,
      defaultMasterCount: 2,
      defaultMasterRatio: 0.55,
      layoutCycle: @[LayoutMode.Scroller, LayoutMode.Deck, LayoutMode.Grid]),
    workspaces: WorkspaceConfig(defaultCount: 3),
    tagRules: @[
      TagRule(tagId: 1, name: "main", defaultLayout: LayoutMode.Scroller),
      TagRule(tagId: 2, name: "web", defaultLayout: LayoutMode.Grid)
    ],
    terminal: TerminalConfig(command: @["foot"]))

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

proc sourceLineFailures(
    checkLine: proc(path, line: string): bool): seq[string] =
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

proc isTopLevelBehavior(line: string): bool =
  for prefix in [
    "proc ", "func ", "iterator ", "template ", "macro ", "converter "
  ]:
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
      "legacy_model",
      "core/model",
      "core/model_utils",
      "core/update",
      "core/shell_state",
      "legacy_apply",
      "layout_state",
      "dod_adapter",
      "runtime_update_sync",
      "layout_projection_sync",
      "state_application_sync",
      "projection_read_sync",
      "dod_shadow_runtime",
      "dod_shadow_health",
      "dod_shadow_health"
    ]
    for path in sourceFiles():
      let source = readFile(path)
      for pattern in blocked:
        check not source.contains(pattern)
      check not source.contains("runtimeState.legacyModel")
      check not source.contains("runtimeState.shadowModel")
      check not source.contains("logShadowObservation")
      check not source.contains("applyObservedRuntimeShadowOnly")

  test "types modules stay data-only":
    for path in typeFiles():
      let lines = readFile(path).splitLines()
      for lineNo in 0 ..< lines.len:
        let line = lines[lineNo]
        if line.isTopLevelBehavior():
          if not path.isAllowedTypeInterop(line):
            checkpoint path & ":" & $(lineNo + 1) & ": " & line
          check path.isAllowedTypeInterop(line)

  test "source follows enforceable style rules":
    let tabFailures = sourceLineFailures(
      proc(path, line: string): bool =
        line.contains("\t"))
    check tabFailures.len == 0

    let enumFailures = sourceLineFailures(
      proc(path, line: string): bool =
        line.contains("= enum") and "{.pure.}" notin line)
    check enumFailures.len == 0

    let getterFailures = sourceLineFailures(
      proc(path, line: string): bool =
        let trimmed = line.strip()
        result = trimmed.startsWith("proc get") or
          trimmed.startsWith("func get"))
    check getterFailures.len == 0

    let entityStorageFailures = sourceLineFailures(
      proc(path, line: string): bool =
        path != "src/state/entity_manager.nim" and
          path != "tests/tstate.nim" and
          (".data" in line or ".index" in line))
    check entityStorageFailures.len == 0

    let overlongFailures = sourceLineFailures(
      proc(path, line: string): bool =
        line.len > 80)
    check overlongFailures.len <= MaxKnownOverlongLines

  test "systems read state through facade queries":
    let blockedStateImports = sourceLineFailures(
      proc(path, line: string): bool =
        path.startsWith("src/systems/") and
          (line.contains("import ../state/") or
            line.contains("from ../state/")) and
          not line.contains("../state/engine"))
    check blockedStateImports.len == 0

    let blockedRelationReads = [
      "model.scratchpadWindows",
      "model.namedScratchpads",
      "model.visibleScratchpad",
      "model.isScratchpadVisible",
      "model.focusHistory",
      "model.workspaceHistory",
      "model.restoreActiveSlot",
      "model.restoreFocusedWindow",
      "model.restoreTagByWindow",
      "model.restoreWindows",
      "model.restoreTags",
      "model.restoreOutputTags",
      "model.restoreScratchpadWindows",
      "model.restoreNamedScratchpads",
      "model.restoreVisibleScratchpad",
      "model.restoreIsScratchpadVisible",
      "model.restoreFocusHistory",
      "model.restoreWorkspaceHistory"
    ]
    let directRelationReads = sourceLineFailures(
      proc(path, line: string): bool =
        if not path.startsWith("src/systems/"):
          return false
        for field in blockedRelationReads:
          if line.containsFieldRead(field):
            return true
        false)
    check directRelationReads.len == 0

    let allocatingQueryReads = sourceLineFailures(
      proc(path, line: string): bool =
        path.startsWith("src/systems/") and
          (line.contains(".columnsForTag(") or
            line.contains(".windowsForColumn(") or
            line.contains(".windowsForTag(")))
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
    discard model.setNamedScratchpadRef("term", winId)
    discard model.showScratchpadRef(winId)
    check model.scratchpadVisible()
    check model.latestScratchpadWindow() == winId
    check model.activeScratchpadWindow() == winId
    check model.namedScratchpadWindow("term") == winId

    discard model.recordFocus(winId)
    discard model.recordWorkspace(tagId)
    check toSeq(model.focusHistoryIds()) == @[winId]
    check toSeq(model.focusHistoryIdsReverse()) == @[winId]
    check toSeq(model.workspaceHistoryIds()) == @[tagId]

    discard model.loadRestoreState(PendingRestoreState(
      focusedWindow: ExternalWindowId(100),
      focusHistory: @[ExternalWindowId(100)],
      workspaceHistory: @[1'u32],
      scratchpadWindows: @[ExternalWindowId(100)]))
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
    check initialized.model.layoutCycle == @[LayoutMode.Scroller,
        LayoutMode.Deck, LayoutMode.Grid]
    check snapshot.activeTag == 1
    check snapshot.workspaces.len == 3
    check snapshot.workspaces[0].name == "main"
    check snapshot.workspaces[1].layoutMode == LayoutMode.Grid

  test "runtime update mutates model and returns effects":
    var state = initRuntimeStateFromConfig(baseConfig())
    let effects = state.applyRuntimeUpdate(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 42,
      appId: "term",
      title: "Terminal"))
    let snapshot = state.readRuntimeSnapshot()

    check effects.anyIt(it.kind == EffectKind.EffManageDirty)
    check effects.anyIt(
      it.kind == EffectKind.EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))
    check state.model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].focusedWindow == 42

  test "runtime config reload preserves live state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 42,
      appId: "term",
      title: "Terminal"))

    let reloaded = Config(
      layout: LayoutConfig(gaps: 30, layoutCycle: @[LayoutMode.Monocle,
          LayoutMode.Deck]),
      workspaces: WorkspaceConfig(defaultCount: 4),
      tagRules: @[
        TagRule(tagId: 1, name: "renamed", defaultLayout: LayoutMode.Monocle)
      ])
    check state.applyRuntimeConfig(reloaded)

    let snapshot = state.readRuntimeSnapshot()
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 30
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].name == "renamed"
    check snapshot.workspaces[0].layoutMode == LayoutMode.Monocle

  test "runtime live restore applies to model":
    var state = initRuntimeStateFromConfig(baseConfig())
    var restore = LiveRestoreState(activeTag: 2, focusedWindow: 50)
    restore.tags[2] = RestoredTagState(
      tagId: 2,
      name: "restored-web",
      layoutMode: LayoutMode.Deck,
      focusedWindow: 50,
      columns: @[
        RestoredColumnState(
          windows: @[WindowId(50)],
          widthProportion: 0.75)
      ],
      masterCount: 1,
      masterSplitRatio: 0.5)
    restore.windows[50] = RestoredWindowState(
      tagId: 2,
      appId: "browser",
      title: "Browser",
      widthProportion: 0.75,
      heightProportion: 0.8)
    restore.tagByWindow[50] = 2

    check state.applyRuntimeLiveRestore(restore)
    discard state.applyRuntimeUpdate(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 50,
      appId: "browser",
      title: "Browser"))

    let snapshot = state.readRuntimeSnapshot()
    check snapshot.activeTag == 2
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 50
    check snapshot.windows[0].workspaceIdx == 2
    check snapshot.workspaces[1].layoutMode == LayoutMode.Deck

  test "layout projection reads and applies directly from state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 10,
      appId: "term",
      title: "Terminal"))
    let projection = state.applyRuntimeLayoutProjection()

    check projection.instructions.len == 1
    check projection.instructions[0].windowId == 10
    check state.model.layoutInstructions().len == 1

  test "snapshot and live restore reads come from state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(Msg(
      kind: MsgKind.WlWindowCreated,
      windowId: 10,
      appId: "term",
      title: "Terminal"))

    let snapshot = state.readRuntimeSnapshot()
    let restoreJson = parseJson(state.readRuntimeLiveRestoreJson())
    check snapshot.windows[0].id == 10
    check restoreJson["schema"].getStr() == LiveRestoreSchema
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
      Msg(kind: MsgKind.WlWindowDestroyed, destroyedId: 1)
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok

    let snapshot = model.shellSnapshot()
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 2
