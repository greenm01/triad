# Triad Data-Oriented Design Architecture

This document is the hard spec for Triad's Data-Oriented Design runtime.
It follows the same architectural split used in `~/dev/ec4x/src/engine`: pure
types, indexed state access, index-aware entity mutations, and behavior systems
layered above the data.

Triad's user-facing model is DWM/River-style tagged window management. The
storage and transformation model is data-oriented; tags remain the canonical
user workflow instead of a desktop/workspace hierarchy.

## Goals

- Strictly separate data from code.
- Make Triad-owned logical IDs the canonical IDs for runtime entities.
- Make bitmask tag membership canonical.
- Store relationships in indexed tables instead of nested object graphs.
- Generate shell and IPC from canonical snapshots.
- Keep production runtime state data-oriented.

## Module Boundaries

The runtime uses four primary layers.

### `types`

`types` modules define pure data:

- distinct ID types, null ID constants, enums, masks, and plain objects
- collection objects such as `EntityManager[ID, T]`
- aggregate state containers
- IPC, restore, config, and layout input/output shapes

Type ownership is explicit:

- `types/core.nim` owns canonical logical IDs, external ID wrappers, masks,
  null constants, `EntityManager`, and `Rect`.
- `types/model.nim` owns canonical runtime entity records such as
  `WindowData`, `TagData`, `ColumnData`, `OutputData`, and `GroupData`.
- `types/projection_values.nim` owns render/layout projection records such as
  `ProjectedWindow`, `ProjectedTag`, `ProjectedColumn`, `ProjectedOutput`,
  `ProjectedGroup`, and `RenderInstruction`.
- `types/live_restore.nim` owns live-restore wire records.
- `types/runtime_values.nim` is limited to runtime/config enums and config
  value objects. It must not define canonical IDs, `Rect`, model entity
  records, projection records, or live-restore records.

`types` modules must not contain business logic. Minimal ID interop such as
hashing, equality, ordering, and string conversion is allowed because Nim needs
it for tables, sorting, and diagnostics.

### `state`

`state` modules are the database layer:

- monotonic logical ID generation
- generic entity manager CRUD
- read-only iterators
- derived queries
- invariant checks

Only this layer may directly access `EntityManager.data` and
`EntityManager.index`.

#### The State Facade

`state/engine.nim` is the public state API for runtime systems. It mirrors the
facade pattern used by `~/dev/ec4x/src/engine/state/engine.nim`: systems import
one module and get typed entity accessors, relation queries, iterators,
invariant checks, snapshots, ID helpers, and entity operations.

Rules:

- New systems should import `state/engine.nim`.
- `entity_manager.nim` is internal plumbing for `state` and `entities`.
- `queries.nim`, `iterators.nim`, and entity op modules stay focused
  implementation modules behind the facade.
- Tests may import `entity_manager.nim` directly when testing the generic
  entity manager itself.
- Systems must not import `entity_manager.nim` directly or reach into
  `model.windows.entity(...)`; add a typed query or entity operation instead.
- System source is checked by tests for facade-only state imports and no
  direct entity manager storage access.

#### The Read Layer: Iterators and Queries

Because runtime data is flattened across multiple tables, we strictly separate the
mechanics of traversing data from the business logic that asks questions about
it.

1.  **Iterators (`iterators.nim`):** Handle the raw hash-table lookups and
    sequence traversals. They yield strongly-typed entities.
2.  **Queries (`queries.nim`):** Consume iterators to answer business
    questions without exposing the underlying data structures.

Systems consume Queries and Iterators. They never manually loop over
`model.windows.data`.

### `entities`

`entities` modules are the only index-aware mutation layer:

- create, update, and delete windows, tags, columns, outputs, groups, and
  scratchpad records
- maintain secondary indexes and relationship tables
- preserve dense entity storage and placement consistency

Entity helpers do not decide policy. They apply validated mutations and keep
indexes correct.

#### The Write Layer: Operations (Ops)

Directly mutating state arrays or relation tables within business logic is
strictly forbidden. Because a single logical action like closing a window
requires updating the entity array, the tag relationships, and the focus state,
manual mutations lead to desync bugs.

All mutations must go through the **Operations Layer**, such as
`window_ops.nim` and `tag_ops.nim`.

An Operation acts as an atomic transaction for runtime state. For example,
`model.destroyWindow(winId)` handles removing the window from `windowTags`,
cleaning up `windowColumns`, reassigning focus, and finally calling `delete`
to swap-and-pop the data array.

### `systems`

`systems` modules contain behavior:

- focus and focus history
- workspace projection and dynamic workspace pruning
- tag movement and retagging
- layout state transitions
- restore application
- scratchpad behavior
- overview behavior
- window rules

Systems read through `state` queries and mutate through `entities` helpers.
They must not write entity tables, indexes, or placement relations directly.

## Canonical IDs

Triad uses logical IDs that are independent of River, Wayland, or shell IPC
identifiers.

```nim
type
  WindowId* = distinct uint32
  TagId* = distinct uint32
  ColumnId* = distinct uint32
  OutputId* = distinct uint32
  GroupId* = distinct uint32

  ExternalWindowId* = distinct uint32
  ExternalOutputId* = distinct uint32
```

ID `0` is always null. ID generators increment before issuing an ID and must
never return zero. External compositor handles live in entity data and lookup
indexes; they are not canonical entity IDs.

## Entity Storage

Every primary entity collection uses dense storage:

```nim
type
  EntityManager*[ID, T] = object
    data*: seq[T]
    index*: Table[ID, int]
```

Deletion uses swap-and-pop:

1. Find the entity's physical index.
2. Move the last entity into that slot when deleting a non-tail entity.
3. Update the moved entity's index entry.
4. Shorten the dense array and delete the removed ID from the index.

No caller outside `state` should depend on physical array position.

## Tags and Placement

Tag membership is canonical as a bitmask. Tag projection and workspace UI are
derived views.

Core relationship tables:

- `windowTags: Table[WindowId, TagMask]`
- `externalWindowIds: Table[ExternalWindowId, WindowId]`
- `columnsByTag: Table[TagId, seq[ColumnId]]`
- `windowsByTag: Table[TagId, seq[WindowId]]`
- `windowsByColumn: Table[ColumnId, seq[WindowId]]`
- `placementByTagWindow: Table[(TagId, WindowId), WindowPlacement]`

`WindowPlacement` is per `(tag, window)`, not just per window. This lets a
multi-tagged window keep stable placement on each visible tag.

Rules:

- A window may have multiple tag bits.
- A tag owns its columns.
- A column belongs to exactly one tag.
- A window may appear once per tag.
- A window may have different placement on different tags.
- Removing a tag bit removes that tag's placement for the window.
- Destroying a window removes all of its tag membership and placement rows.

## Snapshots and IPC

Shell integrations must serialize snapshots, not internal storage.

Production runtime state is data-oriented. `TriadRuntimeState` stores one
`Model`, and daemon reads use snapshots, live-restore JSON, layout projection,
and daemon-view helpers directly.

IPC, shell snapshots, live restore, and compositor adapters expose numeric
external IDs on the wire. The model converts those numeric IDs to canonical
`ExternalWindowId`/`ExternalOutputId` wrappers at the reducer/state boundary.

Window groups are modeled as entities. `GroupData` stores the dense member
list and active window, while `groupByWindow` keeps one-window-to-one-group
membership lookups cheap. External River IDs are stored as entity fields and
resolved through lookup indexes.

## Layout Projection

Layout computation is split into pure projection and explicit writes:

- `LayoutProjection.instructions` is the River-facing placement output.
- `LayoutProjection.viewportTargets` records scroller viewport target updates.
- projection builders must not mutate their input models.
- runtime helpers apply viewport targets and return instructions.

Runtime manage/render layout is state-authoritative. The layout
facade computes `Model.layoutProjection()`, applies viewport targets back to
the model, and sends layout instructions to River.

## Runtime Updates

Runtime updates are direct model transformations:

- daemon update helpers call `Model.update(msg)` directly
- returned effects are production effects
- config reload applies through `Model.applyConfig(config)`
- live restore applies through `Model.applyLiveRestore(...)`
- shell snapshots and live-restore reads are serialized from the model

Tests exercise the reducer, runtime facade, shell snapshots, layout projection,
and live-restore serialization directly.

## Config Application

`Model` has a native config application path that writes into flattened data:

- config-owned runtime fields live directly on `Model`
- default workspaces are materialized through workspace/entity operations
- non-default tag rules remain lazy unless the tag already exists
- existing windows re-evaluate keyboard-shortcuts inhibition after window rules
  change
- live entities, placements, focus history, workspace history, restore buffers,
  and scratchpad state must be preserved

Runtime config reload applies the parsed config directly to `Model`. Shell
restarts, binding rebuilds, manage requests, and broadcasts stay in the daemon
loop because they are side effects of accepting a config reload, not state
transformation rules.

Initial daemon startup creates an empty `Model`, applies config through the
native config path, ensures the active workspace, and stores that model as
production runtime state.

Live-restore application converts the parsed restore payload to
`PendingRestoreState` and applies it directly to the model before
manage/render resumes.

## Runtime Boundaries

Production code must keep one daemon state: `TriadRuntimeState.model`.
Runtime reads are snapshots or live-restore JSON derived from that model. If a
test needs a daemon read surface, build it from `Model.shellSnapshot()` or
`Model.liveRestoreJson()`.
