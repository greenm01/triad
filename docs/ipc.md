# Triad IPC Protocol & Commands

Triad uses a Unix Domain Socket for communication with external clients. The socket resides at `$XDG_RUNTIME_DIR/triad.sock` (falling back to `/tmp/triad.sock`).

## Commands

Dispatch commands to the running Triad instance using:
`triad msg <command> [arguments]`

### General & Metadata
*   `commands [--json]`: Lists all available commands.
*   `validate <command...>`: Validates a command locally without sending it.
*   `request <json>`: Sends a raw JSON IPC request.
*   `state`: Prints the current session state as JSON.
*   `capabilities`: Prints native Triad IPC feature capabilities as JSON, including workspace creation/switching/content-scroll, overview, window, spawn, keyboard-layout, output metadata, and monitor-power support flags.
*   `workspaces`: Prints the current workspace state as JSON.
*   `outputs`: Prints the current output state as JSON.
*   `windows`: Prints the current window state as JSON.
*   `focused-window`: Prints the focused window as JSON.
*   `overview-state`: Prints overview state as JSON.
*   `keyboard-layouts`: Prints keyboard layout state as JSON.
*   `layout-state`: Prints the layout state for all visible workspaces.
*   `switch-keyboard-layout [next|prev|index]`: Switches the active keyboard layout.
*   `power-off-monitors`: Disables currently enabled outputs through output-management and remembers them for restore.
*   `power-on-monitors`: Restores the outputs remembered by `power-off-monitors`.
*   `perf-status`: Prints daemon performance, timing, and loop wake diagnostics.
*   `mem-status`: Prints memory diagnostics.
*   `config-reload`: Reloads the configuration.
*   `triad-reload`: Writes a live-restore snapshot and restarts the manager.
*   `dispatch-binding <kind> <chord>`: Triggers a configured binding (e.g., `key Super+Return`).

### Navigation
*   `focus-next` / `focus-prev`: Shifts focus to the next/previous window.
*   `focus-left`, `focus-right`, `focus-up`, `focus-down`: Spatial focus movement.
*   `focus-last`: Returns focus to the previously focused window.
*   `focus-workspace <index>`: Focuses a workspace by its compact index.
*   `focus-tag <id>`: Focuses a workspace by its stable tag ID.
*   `focus-window <id>`: Focuses a specific window by ID.
*   `new-workspace`: Creates and focuses a new dynamic workspace.
*   `focus-tag-left` / `focus-tag-right`: Moves to the adjacent workspace.
*   `focus-occupied-tag-left` / `focus-occupied-tag-right`: Skips empty tags.
*   `focus-column-first` / `focus-column-last`: Jumps to the edge of the scroller.
*   `toggle-overview`: Toggles the bird's-eye workspace view.
*   `recent-window-next` / `recent-window-prev`: Navigates the MRU switcher.
*   `recent-window-confirm` / `recent-window-cancel`: Confirms or cancels the switcher.
*   `toggle-scratchpad`: Shows or hides the default scratchpad.
*   `toggle-named-scratchpad <name>`: Manages named scratchpad pools.

### Layout Management
Set the layout mode for the active workspace:
*   `layout-scroller`, `layout-tile`, `layout-grid`, `layout-monocle`, `layout-deck`, `layout-spiral`, `layout-tgmix`.
*   `layout-custom <name>`: Selects a declared Janet layout.
*   `layout-native <name>`: Selects a native substrate (e.g., `frame-tree`, `bsp-tree`, `i3`).
*   `switch-layout`: Cycles through the configured `layout-cycle`.
*   `set-layout-for-workspace <tag> <layout>`: Targets a specific workspace by ID.

#### Master-Stack Controls
*   `master-count <n>` / `adjust-master-count <delta>`: Sets the number of master windows.
*   `master-ratio <ratio>` / `adjust-master-ratio <delta>`: Sets the master area size.

#### Frame-Tree (Notion)
*   `frame-split-horizontal` / `frame-split-vertical`: Splits the focused frame.
*   `frame-unsplit`: Removes the focused empty frame.
*   `frame-tab-next` / `frame-tab-prev`: Cycles tabs within a frame.

#### BSP & Dwindle
*   `bsp-balance` / `bsp-equalize`: Rebalances the tree or resets split ratios.
*   `bsp-preselect-left/right/up/down`: Sets the insertion target for the next window.
*   `bsp-preselect-cancel`: Clears the pending insertion target.

#### Split-Tree (i3)
*   `split-tree-split-horizontal` / `split-tree-split-vertical`: Sets insertion direction.
*   `split-tree-layout-toggle-split`: Toggles horizontal/vertical orientation.
*   `split-tree-layout-stacking` / `split-tree-layout-tabbed`: Sets container mode.
*   `split-tree-focus-parent` / `split-tree-focus-child`: Navigates the container hierarchy.

### Window Manipulation
*   `close-window`: Requests the window to close.
*   `toggle-floating`: Toggles between tiled and floating states.
*   `fullscreen-window`: Toggles fullscreen mode.
*   `toggle-maximized`: Toggles the client-visible maximized state.
*   `move-to-tag <id>` / `move-to-workspace <index>`: Moves the window and follows focus.
*   `move-window-to-tag <id> <tag> [follow]`: Moves a specific window.
*   `move-to-scratchpad` / `move-to-named-scratchpad <name>`: Sends the window to a pool.
*   `group-windows`: Groups the window with its neighbor.
*   `ungroup-window`: Dissolves the active group.
*   `maximize-column`: Toggles the focused column to full width.
*   `set-column-width <proportion>`: Sets exact width (e.g., `0.5`).
*   `resize-width <delta>` / `resize-height <delta>`: Adjusts window proportions.

#### Advanced Movement
*   `move-column-left` / `move-column-right`: Swaps columns in the scroller.
*   `move-window-left/right/up/down`: Directional window swapping.
*   `consume-window` / `expel-window`: Merges or splits windows from columns.

### System & Session
*   `spawn <argv...>` / `spawn-terminal`: Runs commands or the default terminal.
*   `screenshot [--path <path>]`: Captures a region, window, or screen.
*   `lock-session`: Launches the configured screen locker.
*   `exit-session`: Exits the session (requires `allow-exit-session #true`).
*   `rename-tag <name>`: Renames the active workspace.
*   `warp-pointer <x> <y>`: Warps the pointer on all active seats.

---

## Event Stream (Niri Emulation)

Triad broadcasts state changes in a Niri-compatible JSON format for integration with shells like Noctalia.

### Subscription
`triad msg event-stream`

### Key Events
*   `WorkspaceActivated`: Triggered on workspace switch.
*   `WindowFocusChanged`: Triggered on focus shift.
*   `WindowOpened` / `WindowClosed`: Triggered when windows appear or disappear.

---

## Native Triad JSON IPC

Native requests use `$TRIAD_SOCKET` and a versioned JSON format. This protocol exposes Triad’s tag-first model directly, including stable IDs and per-tag layouts.

### Request Format
```json
{"triad":{"version":1,"request":"state"}}
```

### Response Format
Replies use a standard success envelope:
```json
{
  "ok": true,
  "triad": {
    "version": 1,
    "type": "state",
    "state": { ... }
  }
}
```

### Native Actions
Native actions mirror CLI commands:
```json
{"triad":{"version":1,"request":"action","action":"focus-workspace","workspace_idx":2}}
```

### Subscription
Subscribe to native layout or state events:
```json
{"triad":{"version":1,"request":"event-stream","events":["state", "layout"]}}
```
Triad sends an initial state for each kind, then pushes updates as they occur.
