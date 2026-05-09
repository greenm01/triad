import tables
import unittest
import ../src/state/entity_manager
import ../src/state/id_gen
import ../src/types/core

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
