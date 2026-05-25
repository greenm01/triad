# Triad: The Data-Oriented Machine

This is the hard spec for Triad’s Data-Oriented Design (DOD) runtime. It mirrors the engine split in `ec4x`: pure types, indexed state, and systems that act on data.

Users manage windows with tags. We ignore desktop hierarchies. In our world, the table is king.

## The Mission

Keep data and code apart. Triad IDs govern every entity. Tags live in bitmasks. We store relationships in indexed tables, never nested graphs. Everything—IPC, shell snapshots, runtime state—flows from these tables.

## The Layers

We split the runtime into four territories.

### Types

`types` modules define pure data. No logic lives here. We define IDs, enums, masks, and objects. `types/core.nim` owns IDs and rectangles. `types/model.nim` owns the records for windows, tags, and outputs. If it involves layout projection or live restores, it lives in its own type file.

Minimal interop—hashing or string conversion—is the only exception. Nim needs it. We allow it.

### State

`state` is the database. It handles ID generation, CRUD, and queries. Only this layer touches the raw entity manager.

New systems use `state/engine.nim`. It’s the facade. It provides typed accessors and relationship queries. Implementation details like `queries.nim` or `iterators.nim` hide behind it. We check our code to ensure no system reaches past this wall.

We separate traversal from business questions. Iterators handle the hash-table lookups. Queries answer the "why." Systems consume both. They never loop over raw data arrays.

### Entities

`entities` modules are the only ones allowed to change the indexes. They create and destroy windows, tags, and columns. They don't decide policy; they just apply the math.

Mutating state directly in business logic is a sin. Closing a window touches arrays, tags, and focus. Manual updates invite desync. Every mutation goes through an Operation. `window_ops.nim` handles the atomic transaction. It cleans up, reassigns focus, and pops the data array. One call. Zero leaks.

### Systems

`systems` hold the behavior. They manage focus history, workspace pruning, and window rules. They read through queries and mutate through entity helpers. They never touch tables or indexes directly.

## IDs

Triad uses logical IDs. We don't care about River or Wayland identifiers.

ID `0` is null. Generators increment before they issue. Zero is never an answer. External compositor handles are just fields in our records. They aren't the authority.

## Storage

We use dense storage. The `EntityManager` holds a data sequence and an index table. Deletion uses swap-and-pop. We find the index, move the tail, and update the table. Physical position means nothing to the caller.

## Tags and Placement

Tag membership is a bitmask. Everything else is a view.

Windows, columns, and placements live in relationship tables. A window can have multiple tags. A tag owns its columns. Placements are tracked per tag and window. This keeps windows stable across multiple tags. Remove a tag bit, and the placement dies. Destroy the window, and every row vanishes.

## Outputs

Each monitor is an output. Each output has a workspace. We track coordinates globally, but layout stays output-aware. If a monitor disappears, the workspace moves to a connected output. When the monitor returns, the workspace moves back. We use pinning to keep focus where it belongs.

## IPC and Snapshots

Shells get snapshots, not our internal guts. Production state is data-oriented. The daemon reads snapshots or JSON. Numeric IDs go over the wire; we wrap them in canonical types at the boundary.

## Layout Projection

We split layout into projection and writes. Projection builders are pure; they never touch the model. They return instructions. The facade applies viewport targets back to the model and tells River where to put windows.

## Updates

Updates are direct transformations. The daemon calls `Model.update(msg)`. Config reloads and live restores hit the model directly. Tests exercise these paths without ceremony.

## Config

The `Model` handles its own config. It writes to flattened data. It materializes default workspaces and re-evaluates window rules. Everything—focus, history, scratchpads—must survive a reload. Startup is simple: create a model, apply config, and run.

## Boundaries

One state: `TriadRuntimeState.model`. If a test needs to see what’s inside, it uses a snapshot.
