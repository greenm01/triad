import ../types/core

proc nextRaw(counter: var uint32): uint32 =
  if counter == high(uint32):
    raise newException(OverflowDefect, "exhausted Triad logical IDs")
  inc counter
  if counter == 0:
    raise newException(OverflowDefect, "logical ID counter wrapped to zero")
  counter

proc generateWindowId*(counters: var IdCounters): WindowId =
  WindowId(nextRaw(counters.nextWindowId))

proc generateTagId*(counters: var IdCounters): TagId =
  TagId(nextRaw(counters.nextTagId))

proc generateColumnId*(counters: var IdCounters): ColumnId =
  ColumnId(nextRaw(counters.nextColumnId))

proc generateFrameId*(counters: var IdCounters): FrameId =
  FrameId(nextRaw(counters.nextFrameId))

proc generateOutputId*(counters: var IdCounters): OutputId =
  OutputId(nextRaw(counters.nextOutputId))

proc generateGroupId*(counters: var IdCounters): GroupId =
  GroupId(nextRaw(counters.nextGroupId))

proc tagBit*(slot: uint32): TagMask =
  if slot == 0 or slot > MaxTagBits:
    raise newException(ValueError, "tag bit slot must be between 1 and " & $MaxTagBits)
  TagMask(1'u64 shl (slot - 1))

proc incl*(mask: var TagMask, bit: TagMask) =
  mask = TagMask(uint64(mask) or uint64(bit))

proc excl*(mask: var TagMask, bit: TagMask) =
  mask = TagMask(uint64(mask) and not uint64(bit))

proc contains*(mask: TagMask, bit: TagMask): bool =
  (uint64(mask) and uint64(bit)) != 0

proc isEmpty*(mask: TagMask): bool =
  uint64(mask) == 0
