# Triad Data-Oriented Design Architecture

This document is the hard spec for Triad's Data-Oriented Design migration.
It follows the same architectural split used in `~/dev/ec4x/src/engine`: pure
types, indexed state access, index-aware entity mutations, and behavior systems
layered above the data.

Triad's user-facing model remains DWM/River-style tagged window management.
DOD changes the storage and transformation model; it does not replace tags with
a desktop/workspace hierarchy.

## Goals

- Strictly separate data from code.
- Make Triad-owned logical IDs the canonical IDs for runtime entities.
- Make bitmask tag membership canonical.
- Store relationships in indexed tables instead of nested object graphs.
- Generate shell and IPC from canonical snapshots.
- Migrate adapter-first, then remove legacy storage after parity is proven.

## Module Boundaries

The migration target uses four primary layers.

### `types`

`types` modules define pure data:

- distinct ID types, null ID constants, enums, masks, and plain objects
- collection objects such as `EntityManager[ID, T]`
- aggregate state containers
- IPC, restore, config, and layout input/output shapes

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

#### The Read Layer: Iterators and Queries

Because DOD data is flattened across multiple tables, we strictly separate the mechanics of traversing data from the business logic that asks questions about it.

1.  **Iterators (`dod_iterators.nim`):** Handle the raw hash-table lookups and sequence traversals. They yield strongly-typed entities (e.g., `iterator windowsOnTag*(model: Model, tagId: TagId): WindowData`).
2.  **Queries (`dod_queries.nim`):** Consume iterators to answer business questions without exposing the underlying data structures (e.g., `proc hasFullscreenWindow*(model: Model, tagId: TagId): bool`).

Systems (like layout algorithms) consume Queries and Iterators. They never manually loop over `model.windows.data`.

### `entities`

`entities` modules are the only index-aware mutation layer:

- create, update, and delete windows, tags, columns, outputs, groups, and
  scratchpad records
- maintain secondary indexes and relationship tables
- preserve dense entity storage and placement consistency

Entity helpers do not decide policy. They apply validated mutations and keep
indexes correct.

#### The Write Layer: Operations (Ops)

Directly mutating state arrays or relation tables within business logic is strictly forbidden. Because a single logical action (like closing a window) requires updating the entity array, the tag relationships, and the focus state, manual mutations lead to desync bugs.

All mutations must go through the **Operations Layer** (e.g., `window_ops.nim`, `tag_ops.nim`).

An Operation acts as an atomic transaction for the DOD state. For example, `model.destroyWindow(winId)` handles removing the window from `windowTags`, cleaning up `windowColumns`, reassigning focus, and finally calling `delEntity` to swap-and-pop the data array.

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
