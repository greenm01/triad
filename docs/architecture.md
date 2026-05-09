# Triad Window Manager Architecture

## Overview
Triad is a dynamic window management client built for **River 0.4+**, leveraging the `river-window-management-v1` Wayland protocol. It is written in **Nim** for performance and safety, configured via **KDL**, and built around one canonical data model with explicit runtime transformations.

Triad combines the infinite scrolling workflow of **Niri** with the flexible,
per-workspace hybrid layouts of **Mango**, while remaining extensible enough
to power a full desktop environment using tools like **Quickshell**.

## Core Technologies
*   **Compositor:** River 0.4+
*   **Language:** Nim (using `nayland` or `wayland-nim` for `libwayland-client` bindings)
*   **Protocol:** `river-window-management-v1`
*   **Configuration:** KDL 2.0 (`nimkdl`)
*   **State Management:** Data-oriented model transformations

## Implementation Principles

### 1. Data-Oriented Design
Following the principles of Yehonathan Sharvit, Triad prioritizes the shape and flow of data over object-oriented hierarchies. 
*   **State as Data:** The `Model` is a pure data structure (predominantly value types and flat collections).
*   **Logic as Transformations:** Submodules provide functions that transform data from one state to another without maintaining hidden internal state.

### 2. DRY (Don't Repeat Yourself)
Common patterns, especially in Wayland protocol handling and coordinate math, are centralized into shared utility modules.

### 3. Lean Submodules by Domain
Source files are kept small and focused. The project is organized into clear domain boundaries:

*   `src/triad.nim`: Entry point and main event loop orchestration.
*   `src/types/`: Pure runtime, IPC, restore, config, and layout data.
*   `src/state/`: Entity storage, queries, iterators, invariants, snapshots,
    and restore serialization.
*   `src/entities/`: Index-aware mutation operations.
*   `src/systems/`: Behavior systems that transform the runtime model.
*   `src/layouts/`: Pure mathematical layout algorithms.
*   `src/protocols/`: Generated Wayland protocol bindings.
*   `src/config/`: KDL parsing and configuration management.
*   `src/ipc/`: Unix socket communication for external control (e.g., Quickshell).
*   `src/utils/`: Generic helpers and coordinate math.

## Architectural Design
...

### 1. Runtime Event Loop
Wayland is inherently asynchronous. To prevent tearing and race conditions, Triad uses a strict unidirectional data flow.

*   **Model:** A single source of truth representing the entire window manager state (Outputs, Tags, Windows, current Layout Modes, and Scroller offsets).
*   **Update:** A function that takes the current `Model` and an incoming `Msg` (Wayland event or IPC command), and returns a new `Model` alongside side effects (e.g., commands to send to River).
*   **Projection (Render Phase):** A layout projection takes the finalized `Model` and executes the math for the active layout (Scroller, Master-Stack, etc.), translating abstract logical coordinates into physical Wayland screen coordinates.

### 2. Double-Buffered Sequence Mapping
River's `window-management-v1` requires a double-buffered sequence. The runtime model maps directly to this:

1.  **Manage Sequence (`manage_start` -> `manage_finish`):** 
    *   This is where the **Update** loop processes all accumulated `Msg` types (new windows, focus shifts). The `Model` is updated.
2.  **Render Sequence (`render_start` -> `render_finish`):** 
    *   This is where the **View** function runs. It reads the `Model`, executes the layout algorithms, and pushes `set_position` / `set_dimensions` instructions to River.

### 3. Hybrid Layout Engine
Layouts are decoupled from the core Wayland event loop. They are simply mathematical functions called during the View phase based on the current `TagState`.

*   **Tag State:** Each Tag (Workspace) maintains its own layout configuration (e.g., Tag 1 is a Scroller, Tag 2 is a Master-Stack).
*   **Scroller Layout:** Implements a Mango-inspired hybrid scrolling workflow. Unlike Niri's fixed ribbon, Triad's scroller treats scrolling as a swappable policy based on window proportions.
    *   **Proportion-Based:** Windows (or Columns) occupy a fraction of the screen width (e.g., 0.5, 0.8). If total proportions exceed 1.0, windows slide into a virtual overflow area.
    *   **Viewport Centering (Niri Influence):** While the math is Mango-style, Triad supports an optional `center-focused-column` mode. When enabled, the `viewport_x_offset` is automatically adjusted to center the focused window, providing the smooth Niri-style navigation feel within Mango's flexible framework.
*   **Tiling Layouts:** Traditional Mango-style layouts (Master-Stack, Grid) execute rigid geometric subdivisions based on configured ratios.

### 4. Configuration (KDL)
Triad uses KDL for robust, hot-reloadable configuration.
*   **Layout Rules:** Global settings for gaps, borders, default column widths, and master ratios.
*   **Workspace Rules:** `workspaces.default-count` controls the minimum empty workspace floor; extra workspaces appear while active or occupied, one trailing empty creation workspace is advertised after the last occupied workspace, and stale empty workspaces are pruned.
*   **Tag Rules:** Provides lazy name/layout templates for tags when they are created (e.g., `tag 1 default-layout="scroller"`).
*   **Window Rules:** Matches `app-id` or titles to dictate floating behavior or specific tag assignments.

### 5. Shell IPC and Quickshell Integration
Triad is designed to act as the backend window manager for a full desktop environment powered by Quickshell or other shell deployers.

The architecture separates Triad-native IPC from shell projection IPC:

*   **Canonical Shell Snapshot:** Triad derives shell-facing state from one internal snapshot of the `Model`. This snapshot contains Triad concepts directly: stable tag IDs, compact workspace indices, windows, outputs, focus, overview state, and per-tag layout modes.
*   **Native Triad IPC (`$TRIAD_SOCKET`):** This is the long-term protocol for deployers and shells that want to integrate with Triad directly. It exposes versioned JSON requests and events such as full shell state, layout state, layout changes, and native state updates.
*   **Niri Projection IPC (`$NIRI_SOCKET`):** This is a projection of the same snapshot into Niri-shaped JSON. It is intentionally constrained to Niri semantics and does not receive Triad-only fields.
*   **Command Flow:** Both native Triad requests and Niri-compatible actions translate into core `Msg` values. The protocols do not call through each other's JSON shapes.

This lets Quickshell modules choose either Niri-shaped projection events or
Triad's richer tagged model.

### Niri Projection IPC
Triad implements a Niri-shaped JSON IPC stream for shells that consume that
schema.

*   **Socket Path:** `$NIRI_SOCKET` points at a Triad-owned compatibility socket when Triad launches Quickshell.
*   **Protocol:** Triad implements the Niri request and event shapes used by shell code, including workspaces, windows, outputs, overview state, keyboard layouts, and event streams.
*   **Event Mapping:** Triad maps its internal shell snapshot to Niri-standard JSON payloads. Workspace `id` values stay as stable Triad tag IDs, while workspace `idx` values are compacted for Niri-style shell bars.
*   **Focus MRU:** Window and workspace focus history is kept in the model and included in live restore snapshots so close behavior and hot reloads can return to the last useful focus target.
