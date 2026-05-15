import std/tables
import runtime_values

const LiveRestoreSchema* = "triad-live-restore-v2"
const
  LiveRestoreStatusPending* = "pending"
  LiveRestoreStatusApplied* = "applied"

type
  LiveRestoreState* = object
    activeTag*: uint32
    focusedWindow*: WindowId
    tagByWindow*: Table[WindowId, uint32]
    windows*: Table[WindowId, RestoredWindowState]
    tags*: Table[uint32, RestoredTagState]
    outputTags*: Table[uint32, uint32]
    scratchpadWindows*: seq[WindowId]
    namedScratchpads*: Table[string, WindowId]
    scratchpadRestoreSlots*: Table[WindowId, seq[uint32]]
    visibleScratchpad*: WindowId
    isScratchpadVisible*: bool
    focusHistory*: seq[WindowId]
    workspaceHistory*: seq[uint32]
    swallowedBy*: Table[WindowId, WindowId]
    swallowing*: Table[WindowId, WindowId]

  LiveRestoreWriteResult* = object
    ok*: bool
    path*: string
    error*: string
