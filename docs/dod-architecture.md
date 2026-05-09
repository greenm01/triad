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

#### The State Facade

`state/engine.nim` is the public state API for DOD systems. It mirrors the
facade pattern used by `~/dev/ec4x/src/engine/state/engine.nim`: systems import
one module and get typed entity accessors, relation queries, iterators,
invariant checks, snapshots, ID helpers, and entity operations.

Rules:

- New DOD systems should import `state/engine.nim`.
- `entity_manager.nim` is internal plumbing for `state` and `entities`.
- `dod_queries.nim`, `dod_iterators.nim`, and entity op modules stay focused
  implementation modules behind the facade.
- Tests may import `entity_manager.nim` directly when testing the generic
  entity manager itself.
- Systems must not import `entity_manager.nim` directly or reach into
  `model.windows.entity(...)`; add a typed query or entity operation instead.
- DOD system source is checked by tests for facade-only state imports and no
  direct entity manager storage access.

#### The Read Layer: Iterators and Queries

Because DOD data is flattened across multiple tables, we strictly separate the
mechanics of traversing data from the business logic that asks questions about
it.

1.  **Iterators (`dod_iterators.nim`):** Handle the raw hash-table lookups and
    sequence traversals. They yield strongly-typed entities.
2.  **Queries (`dod_queries.nim`):** Consume iterators to answer business
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

An Operation acts as an atomic transaction for the DOD state. For example,
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

Triad currently runs DoD as the preferred read projection while legacy remains
the live reducer and River placement authority. IPC and live-restore reads use
the shadow `DodModel` while shadow parity is healthy. On the first divergence,
the runtime disables DoD projection reads and falls back to legacy projections
for the rest of the process.

Projection read selection lives behind a read bridge. Shadow health is explicit
DoD data (`DodShadowHealth`) updated through a small transition system. The
bridge selects `DodProjectionSource` only while the shadow is initialized and
healthy; otherwise it reads from the legacy model. The same source selection is
used for shell snapshots, live-restore JSON reads, and live-restore file writes.

The daemon stores the live legacy model, shadow DoD model, and shadow health as
one `TriadRuntimeState`. Runtime-state facade helpers route updates, config
application, live restore, layout projection, and projection reads through that
single object. This keeps the current legacy authority policy intact while
giving the final DoD promotion one aggregate state boundary to change.

## Layout Projection

Layout computation is split into pure projection and explicit writes:

- `LayoutProjection.instructions` is the River-facing placement output.
- `LayoutProjection.viewportTargets` records scroller viewport target updates.
- projection builders must not mutate their input models.
- compatibility wrappers apply viewport targets and return instructions.

During the shadow phase, runtime manage/render layout still returns legacy
instructions to River. The layout sync bridge computes both legacy and DoD
projections, applies each model's own viewport targets, and reports projection
mismatches through the shadow divergence path. This keeps DoD snapshots current
without making DoD placement authoritative yet.

The layout bridge also has an explicit authority policy. The daemon uses
`LegacyLayoutAuthority` today, so `authoritativeProjection` is the legacy
projection and River placement remains unchanged. Tests can select
`DodLayoutAuthority` to prove that the bridge can return DoD instructions as
authoritative while still computing legacy projection for parity checks.

## Runtime Update Sync

Runtime updates are also bridged explicitly during the shadow phase:

- legacy `update` still mutates the live `Model`
- legacy effects are the only effects executed against River and the host
- the DoD shadow receives the same message stream through `dodUpdate`
- shadow state, effect signatures, snapshots, histories, and layout projections
  are compared after each bridged update
- runtime-owned messages that do not pass through legacy `update`, such as
  terminal spawning, use a shadow-only bridge step

This keeps update policy out of the daemon loop and gives the final DoD runtime
promotion a single seam to change when DoD effects become authoritative.

That seam is represented by an explicit runtime authority policy. The daemon
uses `LegacyRuntimeAuthority` today, so `authoritativeEffects` are the legacy
effects and live behavior is unchanged. Tests can select `DodRuntimeAuthority`
to prove that the same bridge can return DoD effects as authoritative while
still advancing legacy state for parity checks. Config and IPC do not expose
this policy yet; it is an internal promotion control.

## Config Application

`DodModel` has a native config application path. It uses the same normalized
runtime defaults as the legacy `Model` path, but writes into flattened DoD data:

- config-owned runtime fields live directly on `DodModel`
- default workspaces are materialized through workspace/entity operations
- non-default tag rules remain lazy unless the tag already exists
- existing windows re-evaluate keyboard-shortcuts inhibition after window rules
  change
- live entities, placements, focus history, workspace history, restore buffers,
  and scratchpad state must be preserved

This bridge lets config reload parity be proven before promoting `DodModel` to
the canonical runtime state.

Runtime config reload uses the state application sync bridge. The bridge applies
the config to the legacy model, applies the same config to the DoD shadow when
shadow sync is enabled, and compares the resulting state through the normal DoD
shadow report path. Shell restarts, binding rebuilds, manage requests, and
broadcasts stay in the daemon loop because they are side effects of accepting a
config reload, not state transformation rules.

Initial daemon startup uses the same bridge boundary. The startup helper builds
the live legacy model from a fresh seed, builds the DoD shadow from an
unconfigured seed, applies config through both native paths, and reports parity
before projection reads are trusted. This keeps startup from treating a
configured legacy-to-DoD adapter conversion as proof that DoD config application
works.

Live-restore application uses the same bridge style. The legacy model remains
authoritative today, while the DoD shadow applies `DodLiveRestoreState` derived
from the same restore payload and reports parity before manage/render resumes.

## Shadow Runtime

Before `DodModel` becomes authoritative, Triad runs a diagnostic DoD shadow
model beside the legacy runtime:

- legacy `Model` remains the only source of live River effects
- the shadow receives the same config, live-restore state, and message stream
- shadow effects are compared for stable signatures but never executed
- shell snapshots, focus history, workspace history, layout instructions, and
  DoD invariants are checked after shadow steps
- divergences are logged and throttled, never fatal to the live session

This phase is intentionally observational. It proves the reducer and runtime
state boundaries under a live session before the final runtime promotion.

Shadow health follows the same data/code split as other DoD state: health fields
live in `types/dod_shadow_health.nim`, while report application, read fallback,
and divergence throttle decisions live in `systems/dod_shadow_health.nim`.
Daemon code handles logging side effects from those decisions but does not own
the health transition policy.
