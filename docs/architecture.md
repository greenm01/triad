# Triad Window Manager Architecture

## Overview
Triad is a dynamic window management client built for **River 0.4+**, leveraging the `river-window-management-v1` Wayland protocol. It is written in **Nim** for performance and safety, configured via **KDL**, and built around one canonical data model with explicit runtime transformations.

Triad combines the infinite scrolling workflow of **Niri** with the flexible,
per-workspace hybrid layouts of **Mango**, while remaining extensible enough
to power a full desktop environment using external shell bars.

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
*   `src/ipc/`: Unix socket communication for external control and shell projections.
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

*   **Validation Logic:** Configuration validation checks strict output-rule shapes. Unknown or unsupported `output` fields, invalid transforms, malformed modes, non-positive workspace IDs, and out-of-range scales are rejected before startup or reload.
*   **Layout Rules:** Global settings for gaps, borders, default column widths, and master ratios.
    *   **Gaps:** In native `frame-tree` layouts, gaps represent the split gap between frames; the frame tree fills the output usable rect with no extra outer margin. Native `bsp-tree` and `i3` use traditional outer and inner gaps.
*   **Workspace Rules:** `workspaces.default-count` controls the minimum empty workspace floor; extra workspaces appear while active or occupied, a trailing empty creation workspace remains available only when no earlier empty dynamic workspace can be reused, and stale empty workspaces are pruned. Shell compatibility views and overview previews hide inactive empty workspaces.
*   **Workspace Rule Templates:** Provides lazy name/layout templates for workspace slots when internal tags are created (e.g., `workspace 1 default-layout="scroller"`).
*   **Window Rules:** Matches `app-id` or titles to dictate floating behavior or specific workspace assignments.

*   **Janet Layouts:** User-defined Janet layouts can be declared with a native fallback (e.g., `scroller`, `frame-tree`, `bsp-tree`, `i3`).
    *   **Frame-tree Fallback:** When a layout uses `fallback="frame-tree"`, it can return frame geometry via `:frame-id`. Triad maps these to the active visible tab and preserves empty frame rects for native chrome.
    *   **BSP-tree Fallback:** Layouts using `fallback="bsp-tree"` can return geometry via `:bsp-node-id`. Triad maps these to tiled windows and exposes preselection state (`:preselect-direction`, `:preselect-ratio`).
    *   **Split-tree (i3) Fallback:** Layouts using `fallback="i3"` receive immutable `:split-nodes` and return geometry via `:split-node-id`. Mutation (insertion, resize, etc.) remains a native state operation.

Config names follow the policy in `docs/configuration.md`: Niri-style KDL
clarity is the naming baseline, while Mango remains a feature reference for
layouts, tags, scratchpads, and pointer workflows.

### 5. Shell IPC and Niri Projection
Triad separates Triad-native IPC from shell projection IPC to support both native and legacy shell ecosystems.

*   **Canonical Shell Snapshot:** Triad derives all shell-facing state from a single internal model snapshot. This snapshot contains stable tag IDs, compact workspace indices, windows, outputs, focus history, and layout modes.
*   **Native Triad IPC (`$TRIAD_SOCKET`):** The primary, long-term protocol for shells that integrate with Triad directly. It exposes versioned JSON requests and events including the full shell state and per-tag layout details.
*   **Niri Projection IPC (`$NIRI_SOCKET`):** A projection of the same snapshot into Niri-shaped JSON. It is intentionally constrained to Niri semantics to support existing Niri-aware shells (Noctalia, DankMaterialShell) without modification.
*   **Command Flow:** Both native Triad requests and Niri-compatible actions translate into core `Msg` values. The protocols do not call through each other's JSON shapes.

IPC window and output IDs are numeric external compositor IDs, stable for the lifetime of the compositor object but distinct from Triad's internal logical IDs.

### Niri Projection IPC
Triad implements a Niri-shaped JSON IPC stream for shells that consume that
schema.

*   **Socket Path:** `$NIRI_SOCKET` points at a Triad-owned compatibility socket when Triad launches a Niri-compatible shell profile.
*   **Protocol:** Triad implements the Niri request and event shapes used by shell code, including workspaces, windows, outputs, overview state, keyboard layouts, and event streams.
*   **Event Mapping:** Triad maps its internal shell snapshot to Niri-standard JSON payloads. Workspace `id` values stay as stable Triad tag IDs, while workspace `idx` values are compacted for Niri-style shell bars.
*   **Focus MRU:** Window and workspace focus history is kept in the model and included in live restore snapshots so close behavior and hot reloads can return to the last useful focus target.
