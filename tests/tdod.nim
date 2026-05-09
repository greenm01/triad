import json, sequtils, strutils, tables
import unittest
import ../src/core/model_utils
import ../src/core/niri_state
import ../src/core/shell_state
import ../src/core/triad_state
import ../src/entities/dod_ops
import ../src/state/dod_adapter
import ../src/state/entity_manager
import ../src/state/dod_invariants
import ../src/state/dod_snapshot
import ../src/state/id_gen
import ../src/types/core
import ../src/types/dod_model
from ../src/types/legacy_model import nil

type
  TestEntity = object
    id*: WindowId
    value*: string

suite "DOD state primitives":
  test "logical IDs are monotonic and reserve zero":
    var counters = IdCounters()

    let firstWindow = counters.generateWindowId()
    let secondWindow = counters.generateWindowId()
    let firstTag = counters.generateTagId()

    check firstWindow == WindowId(1)
    check secondWindow == WindowId(2)
    check firstTag == TagId(1)
    check firstWindow != NullWindowId
    check firstTag != NullTagId

  test "entity manager adds, updates, and deletes densely":
    var manager: EntityManager[WindowId, TestEntity]

    manager.addEntity(TestEntity(id: WindowId(1), value: "one"))
    manager.addEntity(TestEntity(id: WindowId(2), value: "two"))
    manager.addEntity(TestEntity(id: WindowId(3), value: "three"))

    check manager.len == 3
    check manager.hasEntity(WindowId(2))
    manager.getEntity(WindowId(2)).value = "updated"
    check manager.getEntity(WindowId(2)).value == "updated"

    check manager.delEntity(WindowId(2))
    check manager.len == 2
    check not manager.hasEntity(WindowId(2))
    check manager.hasEntity(WindowId(3))
    check manager.getEntity(WindowId(3)).value == "three"
    check manager.index[WindowId(3)] >= 0
    check manager.index[WindowId(3)] < manager.data.len
    check manager.data[manager.index[WindowId(3)]].id == WindowId(3)

  test "entity manager rejects duplicate IDs":
    var manager: EntityManager[WindowId, TestEntity]

    manager.addEntity(TestEntity(id: WindowId(1), value: "one"))

    expect ValueError:
      manager.addEntity(TestEntity(id: WindowId(1), value: "dupe"))

  test "tag masks are bounded and composable":
    var mask = EmptyTagMask
    let first = tagBit(1)
    let last = tagBit(MaxTagBits)

    check mask.isEmpty()
    mask.incl(first)
    check mask.contains(first)
    check not mask.contains(last)
    mask.incl(last)
    check mask.contains(last)
    mask.excl(first)
    check not mask.contains(first)
    check mask.contains(last)

    expect ValueError:
      discard tagBit(0)
    expect ValueError:
      discard tagBit(MaxTagBits + 1)

  test "DOD placement supports multi-tag windows and destroy cleanup":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tagOne = model.addTag(1, "one")
    let tagTwo = model.addTag(2, "two")
    let colOne = model.addColumn(tagOne, 0.5)
    let colTwo = model.addColumn(tagTwo, 0.75)
    let win = model.addWindow(ExternalWindowId(10), appId = "term", title = "Terminal")

    model.placeWindow(tagOne, colOne, win)
    model.placeWindow(tagTwo, colTwo, win)

    check model.windowTags[win].contains(tagBit(1))
    check model.windowTags[win].contains(tagBit(2))
    check model.windowsByTag[tagOne] == @[win]
    check model.windowsByTag[tagTwo] == @[win]
    check model.windowsByColumn[colOne] == @[win]
    check model.windowsByColumn[colTwo] == @[win]
    check model.validateInvariants().ok

    check model.destroyWindow(win)
    check not model.windows.hasEntity(win)
    check not model.externalWindowIds.hasKey(ExternalWindowId(10))
    check model.windowsByTag[tagOne].len == 0
    check model.windowsByTag[tagTwo].len == 0
    check model.windowsByColumn[colOne].len == 0
    check model.windowsByColumn[colTwo].len == 0
    check model.validateInvariants().ok

  test "DOD invariants report broken relationship indexes":
    var model = DodModel(defaultWorkspaceCount: 3)
    let tag = model.addTag(1, "one")
    discard model.addColumn(tag, 0.5)
    model.windowsByTag[tag].add(WindowId(999))

    let report = model.validateInvariants()
    check not report.ok
    check report.errors.anyIt(it.message.contains("missing window"))

  test "legacy adapter preserves shell snapshots and existing IPC ids":
    var source = legacy_model.Model(
      activeTag: 1,
      screenWidth: 1920,
      screenHeight: 1080,
      overviewActive: true
    )
    source.workspaces.defaultCount = 3
    source.layoutCycle = @[legacy_model.Scroller, legacy_model.Grid, legacy_model.Monocle]
    source.tags[1] = initTagState(1, legacy_model.Scroller, "main")
    source.tags[1].columns.add(legacy_model.Column(windows: @[legacy_model.WindowId(10)], widthProportion: 0.5))
    source.tags[1].focusedWindow = 10
    source.tags[2] = initTagState(2, legacy_model.Grid, "web")
    source.tags[2].columns.add(legacy_model.Column(windows: @[legacy_model.WindowId(20)], widthProportion: 0.8))
    source.tags[2].focusedWindow = 20
    source.windows[10] = legacy_model.WindowData(
      id: 10,
      appId: "kitty",
      title: "Terminal",
      widthProportion: 0.5,
      heightProportion: 1.0,
      actualW: 900,
      actualH: 1000
    )
    source.windows[20] = legacy_model.WindowData(
      id: 20,
      appId: "brave",
      title: "Browser",
      widthProportion: 0.8,
      heightProportion: 1.0,
      isMaximized: true
    )
    source.outputs[42] = legacy_model.OutputData(id: 42, name: "DP-1", x: 0, y: 0, w: 1920, h: 1080)
    source.outputs[43] = legacy_model.OutputData(id: 43, x: 1920, y: 0, w: 1920, h: 1080)
    source.primaryOutput = 42
    source.outputTags[43] = 2
    source.focusHistory = @[legacy_model.WindowId(10), 20]
    source.workspaceHistory = @[1'u32, 2]

    let dod = source.dodFromLegacy()
    check dod.validateInvariants().ok
    check uint32(dod.windows.getEntity(WindowId(1)).externalId) == 10
    check uint32(dod.windows.getEntity(WindowId(2)).externalId) == 20

    let legacySnapshot = shellSnapshot(source)
    let dodSnapshot = dodShellSnapshot(dod)

    check triadStateJson(dodSnapshot) == triadStateJson(legacySnapshot)
    check triadLayoutStateJson(dodSnapshot) == triadLayoutStateJson(legacySnapshot)
    check niriWorkspacesJson(dodSnapshot) == niriWorkspacesJson(legacySnapshot)
    check niriWindowsJson(dodSnapshot) == niriWindowsJson(legacySnapshot)
    check niriOutputsJson(dodSnapshot) == niriOutputsJson(legacySnapshot)

    let windows = triadStateJson(dodSnapshot)["windows"]
    check windows[0]["id"].getInt() == 10
    check windows[1]["id"].getInt() == 20
