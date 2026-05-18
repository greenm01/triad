import std/[hashes, tables]

type
  WindowId* = distinct uint32
  TagId* = distinct uint32
  ColumnId* = distinct uint32
  FrameId* = distinct uint32
  BspNodeId* = distinct uint32
  SplitNodeId* = distinct uint32
  OutputId* = distinct uint32
  GroupId* = distinct uint32

  ExternalWindowId* = distinct uint32
  ExternalOutputId* = distinct uint32

  TagMask* = distinct uint64

  Rect* = object
    x*, y*, w*, h*: int32

  EntityManager*[ID, T] = object
    data*: seq[T]
    index*: Table[ID, int]

  IdCounters* = object
    nextWindowId*: uint32
    nextTagId*: uint32
    nextColumnId*: uint32
    nextFrameId*: uint32
    nextBspNodeId*: uint32
    nextSplitNodeId*: uint32
    nextOutputId*: uint32
    nextGroupId*: uint32

const
  NullWindowId* = WindowId(0)
  NullTagId* = TagId(0)
  NullColumnId* = ColumnId(0)
  NullFrameId* = FrameId(0)
  NullBspNodeId* = BspNodeId(0)
  NullSplitNodeId* = SplitNodeId(0)
  NullOutputId* = OutputId(0)
  NullGroupId* = GroupId(0)
  NullExternalWindowId* = ExternalWindowId(0)
  NullExternalOutputId* = ExternalOutputId(0)
  EmptyTagMask* = TagMask(0)
  MaxTagBits* = 64'u32

proc `==`*(a, b: WindowId): bool {.borrow.}
proc `==`*(a, b: TagId): bool {.borrow.}
proc `==`*(a, b: ColumnId): bool {.borrow.}
proc `==`*(a, b: FrameId): bool {.borrow.}
proc `==`*(a, b: BspNodeId): bool {.borrow.}
proc `==`*(a, b: SplitNodeId): bool {.borrow.}
proc `==`*(a, b: OutputId): bool {.borrow.}
proc `==`*(a, b: GroupId): bool {.borrow.}
proc `==`*(a, b: ExternalWindowId): bool {.borrow.}
proc `==`*(a, b: ExternalOutputId): bool {.borrow.}
proc `==`*(a, b: TagMask): bool {.borrow.}

proc `<`*(a, b: WindowId): bool {.borrow.}
proc `<`*(a, b: TagId): bool {.borrow.}
proc `<`*(a, b: ColumnId): bool {.borrow.}
proc `<`*(a, b: FrameId): bool {.borrow.}
proc `<`*(a, b: BspNodeId): bool {.borrow.}
proc `<`*(a, b: SplitNodeId): bool {.borrow.}
proc `<`*(a, b: OutputId): bool {.borrow.}
proc `<`*(a, b: GroupId): bool {.borrow.}

proc `$`*(id: WindowId): string {.borrow.}
proc `$`*(id: TagId): string {.borrow.}
proc `$`*(id: ColumnId): string {.borrow.}
proc `$`*(id: FrameId): string {.borrow.}
proc `$`*(id: BspNodeId): string {.borrow.}
proc `$`*(id: SplitNodeId): string {.borrow.}
proc `$`*(id: OutputId): string {.borrow.}
proc `$`*(id: GroupId): string {.borrow.}
proc `$`*(id: ExternalWindowId): string {.borrow.}
proc `$`*(id: ExternalOutputId): string {.borrow.}

proc hash*(id: WindowId): Hash =
  hash(uint32(id))

proc hash*(id: TagId): Hash =
  hash(uint32(id))

proc hash*(id: ColumnId): Hash =
  hash(uint32(id))

proc hash*(id: FrameId): Hash =
  hash(uint32(id))

proc hash*(id: BspNodeId): Hash =
  hash(uint32(id))

proc hash*(id: SplitNodeId): Hash =
  hash(uint32(id))

proc hash*(id: OutputId): Hash =
  hash(uint32(id))

proc hash*(id: GroupId): Hash =
  hash(uint32(id))

proc hash*(id: ExternalWindowId): Hash =
  hash(uint32(id))

proc hash*(id: ExternalOutputId): Hash =
  hash(uint32(id))

proc hash*(mask: TagMask): Hash =
  hash(uint64(mask))
