# Triad Architecture

Triad is a window manager client for River 0.4+. It speaks the `river-window-management-v1` Wayland protocol. We wrote it in Nim for speed, configure it with KDL, and run the entire system on a single, explicit data model.

Triad uses a tag-first runtime with per-workspace layouts and programmable policy. It stands on its own but integrates cleanly with existing River and desktop-shell tooling.

## Core Technologies
*   **Compositor:** River 0.4+
*   **Language:** Nim
*   **Protocol:** `river-window-management-v1`
*   **Configuration:** KDL 2.0
*   **State:** Data-oriented transformations

## Implementation Principles

### Data-Oriented Design
Triad runs on Data-Oriented Design. We care about the shape and flow of data, discarding object-oriented hierarchies entirely.
*   **State as Data:** The `Model` is a pure data structure.
*   **Logic as Transformations:** Submodules provide functions that transform the `Model` from one state to another. They do not maintain hidden internal state.

### Domain Boundaries
Source files are small and focused. We organize the project into clear boundaries:
*   `src/triad.nim`: Entry point and main event loop orchestration.
*   `src/types/`: Pure runtime, IPC, and layout data.
*   `src/state/`: Entity storage, queries, and snapshots.
*   `src/entities/`: Mutation operations.
*   `src/systems/`: Behavior systems that transform the model.
*   `src/layouts/`: Mathematical layout algorithms.
*   `src/config/`: KDL parsing and management.
*   `src/ipc/`: Unix socket communication for control and shell projections.

## The Event Loop
Wayland is asynchronous. To prevent tearing and race conditions, Triad uses a unidirectional data flow.

1.  **Model:** A single source of truth for the entire state (Outputs, Tags, Windows).
2.  **Update:** A function that takes the current `Model` and an incoming `Msg` (Wayland event or IPC command), returning a new `Model` and side effects.
3.  **Projection:** A layout projection takes the finalized `Model` and calculates the physical screen coordinates.

### Sequence Mapping
River's `window-management-v1` protocol uses a double-buffered sequence. Triad maps directly to this:
*   **Manage Sequence:** The **Update** loop processes all accumulated messages.
*   **Render Sequence:** The **View** function runs, executes layout math, and pushes position instructions to River.

## Hybrid Layout Engine
Layouts are decoupled from the core event loop. They are mathematical functions called during the View phase based on the current `TagState`.

*   **Scroller:** A proportion-based scrolling workflow. Windows occupy a fraction of the screen width (e.g., 0.5, 0.8). If they exceed 1.0, they slide into a virtual overflow area.
*   **Tiling:** Algorithmic layouts like master-stack and grid.
*   **Janet Layouts:** You can define custom layouts in Janet with native fallbacks like `frame-tree` or `bsp-tree`.

## Configuration (KDL)
Triad uses KDL for hot-reloadable configuration.
*   **Validation:** We check configuration shapes strictly. Unknown fields or invalid scales are rejected before they touch the runtime.
*   **Rules:** Global settings for gaps, borders, and ratios. Gaps in `frame-tree` layouts fill the output usable rect; `bsp-tree` and `i3` use traditional margins.
*   **Workspaces:** `workspaces.default-count` sets the floor for empty workspaces. We prune stale, empty workspaces automatically.

## IPC and Shell Projection
Triad separates its native IPC from shell compatibility.

*   **Native IPC (`$TRIAD_SOCKET`):** The primary protocol for shells designed for Triad. It exposes JSON requests and events.
*   **Compatibility Projection (`$NIRI_SOCKET`):** A projection of the internal snapshot into the JSON schema used by Niri-aware shells. This allows you to use existing Niri shell bars without modification.

We map internal state to standard JSON payloads. Stable Tag IDs become Workspace IDs, and focus history ensures that hot reloads return you to where you left off.
