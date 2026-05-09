import json, os, sequtils, strutils, tables, unittest
import ../src/config/parser
import ../src/core/effects
import ../src/core/msg
import ../src/core/restore_state
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

proc baseConfig(): Config =
  Config(
    layout: LayoutConfig(
      gaps: 12,
      defaultColumnWidth: 0.6,
      defaultWindowWidth: 0.8,
      defaultWindowHeight: 0.7,
      defaultMasterCount: 2,
      defaultMasterRatio: 0.55,
      layoutCycle: @[Scroller, Deck, Grid]),
    workspaces: WorkspaceConfig(defaultCount: 3),
    tagRules: @[
      TagRule(tagId: 1, name: "main", defaultLayout: Scroller),
      TagRule(tagId: 2, name: "web", defaultLayout: Grid)
    ],
    terminal: TerminalConfig(command: @["foot"]))

proc sourceFiles(): seq[string] =
  for path in walkDirRec("src"):
    if path.endsWith(".nim"):
      result.add(path)

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

  test "runtime init builds a valid model from config":
    let initialized = initRuntimeStateFromConfig(baseConfig())
    let snapshot = initialized.readRuntimeSnapshot()

    check initialized.model.validateInvariants().ok
    check initialized.model.defaultWorkspaceCount == 3
    check initialized.model.outerGaps == 12
    check initialized.model.layoutCycle == @[Scroller, Deck, Grid]
    check snapshot.activeTag == 1
    check snapshot.workspaces.len == 3
    check snapshot.workspaces[0].name == "main"
    check snapshot.workspaces[1].layoutMode == Grid

  test "runtime update mutates model and returns effects":
    var state = initRuntimeStateFromConfig(baseConfig())
    let effects = state.applyRuntimeUpdate(Msg(
      kind: WlWindowCreated,
      windowId: 42,
      appId: "term",
      title: "Terminal"))
    let snapshot = state.readRuntimeSnapshot()

    check effects.anyIt(it.kind == EffManageDirty)
    check effects.anyIt(
      it.kind == EffBroadcastJson and
      it.jsonPayload.contains("WindowOpenedOrChanged"))
    check state.model.validateInvariants().ok
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].focusedWindow == 42

  test "runtime config reload preserves live state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(Msg(
      kind: WlWindowCreated,
      windowId: 42,
      appId: "term",
      title: "Terminal"))

    let reloaded = Config(
      layout: LayoutConfig(gaps: 30, layoutCycle: @[Monocle, Deck]),
      workspaces: WorkspaceConfig(defaultCount: 4),
      tagRules: @[
        TagRule(tagId: 1, name: "renamed", defaultLayout: Monocle)
      ])
    check state.applyRuntimeConfig(reloaded)

    let snapshot = state.readRuntimeSnapshot()
    check state.model.validateInvariants().ok
    check state.model.outerGaps == 30
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 42
    check snapshot.workspaces[0].name == "renamed"
    check snapshot.workspaces[0].layoutMode == Monocle

  test "runtime live restore applies to model":
    var state = initRuntimeStateFromConfig(baseConfig())
    var restore = LiveRestoreState(activeTag: 2, focusedWindow: 50)
    restore.tags[2] = RestoredTagState(
      tagId: 2,
      name: "restored-web",
      layoutMode: Deck,
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
      kind: WlWindowCreated,
      windowId: 50,
      appId: "browser",
      title: "Browser"))

    let snapshot = state.readRuntimeSnapshot()
    check snapshot.activeTag == 2
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 50
    check snapshot.windows[0].workspaceIdx == 2
    check snapshot.workspaces[1].layoutMode == Deck

  test "layout projection reads and applies directly from state":
    var state = initRuntimeStateFromConfig(baseConfig())
    discard state.applyRuntimeUpdate(Msg(
      kind: WlWindowCreated,
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
      kind: WlWindowCreated,
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
      Msg(kind: WlWindowCreated, windowId: 1, appId: "a", title: "A"),
      Msg(kind: WlWindowCreated, windowId: 2, appId: "b", title: "B"),
      Msg(kind: CmdFocusWindowById, focusWindowId: 1),
      Msg(kind: CmdMoveToWorkspaceIndex, workspaceIndex: 2),
      Msg(kind: CmdFocusWorkspaceIndex, workspaceIndex: 2),
      Msg(kind: CmdToggleFloating),
      Msg(kind: WlWindowDestroyed, destroyedId: 1)
    ]:
      let (next, _) = model.update(msg)
      model = next
      check model.validateInvariants().ok

    let snapshot = model.shellSnapshot()
    check snapshot.windows.len == 1
    check snapshot.windows[0].id == 2
