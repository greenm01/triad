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
- Generate shell and compatibility IPC from canonical snapshots.
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

### `entities`

`entities` modules are the only index-aware mutation layer:

- create, update, and delete windows, tags, columns, outputs, groups, and
  scratchpad records
- maintain secondary indexes and relationship tables
- preserve dense entity storage and placement consistency

Entity helpers do not decide policy. They apply validated mutations and keep
indexes correct.

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

- Native Triad IPC reads a canonical Triad snapshot.
- Niri compatibility IPC is a projection of the same snapshot.
- Noctalia, quickshell, and future shells should be able to consume native
  Triad IPC without depending on nested layout internals.

Snapshot generation belongs in `state` or a thin projection layer over `state`.
IPC modules should not independently infer focus, workspace lists, placement,
or app identity.

## Migration Order

The migration is adapter-first.

1. Introduce DOD primitives and tests without changing runtime behavior.
2. Define the final DOD model shape and invariant checks.
3. Add adapters from the current nested model into the DOD model.
4. Prove parity for shell snapshots, Niri IPC, Triad IPC, restore data, and
   layout inputs.
5. Move read paths to DOD queries.
6. Move mutation paths to entity helpers and systems.
7. Remove the legacy nested storage after parity is stable.

The later big-bang cleanup pass is tracked in `docs/todo.md`; it is not the
first migration step.

## Required Invariants

- No live focus ID points at a missing window.
- No workspace history entry points at a missing or invalid tag.
- No column points at a missing tag.
- No placement row points at a missing window or column.
- No window appears twice on the same tag.
- No window appears in a column for a tag it does not belong to.
- No empty dynamic workspace is advertised unless it is within the configured
  minimum workspace count or is the active trailing workspace.
- IPC snapshots must be derivable from canonical state without consulting
  compositor callbacks.

## Verification

Every DOD migration step must include tests appropriate to its blast radius.

Baseline suites:

- `nimble testDod`
- `nimble testUnit`
- `nimble testCompat`
- `nimble testStress`
- `nimble testHardening`
- `nimble buildAll`

Coverage expectations:

- ID generation reserves zero and is monotonic.
- Entity deletion preserves dense storage and updates indexes.
- Tag masks reject out-of-range slots and compose correctly.
- Adapter projections match the current nested model before read paths move.
- Randomized window/tag/focus sequences preserve DOD invariants.
- Reload paths preserve focus, workspace state, maximized/floating state, and
  placement.
