# Triad IPC Protocol & Commands

## Inter-Process Communication

Triad employs a Unix Domain Socket for two-way communication with external clients. By default, the socket resides at `$XDG_RUNTIME_DIR/triad.sock`. Should that environment variable be absent, it retreats to `/tmp/triad.sock`.

### Commands

To dispatch a command to the running Triad instance, use the following syntax:
`triad msg <command> [arguments]`

#### Navigation
*   `focus-next`: Shifts keyboard focus to the next window in the sequence.
*   `focus-prev`: Shifts keyboard focus to the previous window.
*   `toggle-overview`: Activates or deactivates the global window grid.
*   `toggle-scratchpad`: Summons the active scratchpad window as an overlay or dismisses it to the shadows.
*   `select-window`: In overview mode, selects the focused window and jumps to its tag.
*   `rename-tag <name>`: Bestows a new, more dignified name upon the active tag.

#### Layout Management
*   `layout-scroller`: Sets the active tag to horizontal scrolling mode.
*   `layout-vertical-scroller`: Sets the active tag to vertical scrolling mode.
*   `layout-tile`: Sets the active tag to Master-Stack tiling mode.
*   `layout-grid`: Sets the active tag to geometric grid mode.
*   `layout-monocle`: Sets the active tag to fullscreen monocle mode.

#### Manipulation
*   `move-to-tag <id>`: Banishes the focused window to the specified tag.
*   `move-to-scratchpad`: Consigns the focused window to the scratchpad, where it awaits your summons.
*   `close-window`: Politley requests that the focused window terminate its existence.
*   `group-windows`: Orchestrates the union of the focused window and its neighbor into a single tabbed group.
*   `ungroup-window`: Dissolves the group, granting the focused window its independence.
*   `focus-next-in-group`: Cycles focus through the windows of a tabbed group.
*   `toggle-floating`: Toggles the focused window between tiled and floating states.
*   `toggle-fullscreen`: Commands the window to occupy the entire screen, as is its right.
*   `move-floating <dx> <dy>`: Displaces a floating window by the specified pixel deltas.
*   `resize-floating <dw> <dh>`: Adjusts the physical dimensions of a floating window.
*   `zoom`: Swaps the focused window with the primary window in the master position.
*   `resize-width <delta>`: Adjusts the width proportion (e.g., `0.1` or `-0.1`).
*   `resize-height <delta>`: Adjusts the height proportion.
*   `set-column-width <proportion>`: Precisely dictates the width of the focused column (e.g., `0.5`, `1.0`).
*   `adjust-gaps <delta>`: Increases or decreases the global gap size (e.g., `5` or `-5`).
*   `toggle-gaps`: Instantly eliminates all gaps or restores them to their former glory.

#### Master-Stack Refinements
*   `master-count <n>`: Sets the exact number of windows allowed in the master area.
*   `adjust-master-count <delta>`: Increments or decrements the master window count.
*   `master-ratio <ratio>`: Sets the master area split ratio (e.g., `0.6`).
*   `adjust-master-ratio <delta>`: Fine-tunes the master split ratio.

#### Advanced Movement
*   `move-column-left`: Swaps the focused column with its neighbor to the left.
*   `move-column-right`: Swaps the focused column with its neighbor to the right.
*   `move-window-left`: Transports the focused window to the adjacent column on the left, creating a new column if necessary.
*   `move-window-right`: Transports the focused window to the adjacent column on the right.
*   `move-window-up`: Swaps the focused window with the one above it in a stack.
*   `move-window-down`: Swaps the focused window with the one below it.
*   `swap-window-up`: An alias for `move-window-up`, reordering windows within their column.
*   `swap-window-down`: An alias for `move-window-down`.
*   `consume-window`: Merges the first window of the column to the right into the currently focused column.
*   `expel-window`: Liberates the focused window from its stack, granting it a new column to its immediate right.

---

## State Broadcast (Niri Emulation)

Triad can broadcast a continuous stream of state changes in a Niri-compatible JSON format. This enables seamless integration with shells such as **Noctalia-shell**.

### Subscription
To subscribe to the event stream, execute:
`triad msg event-stream`

### JSON Schema

Triad emits line-delimited JSON objects. Each object contains a single key representing the event type.

#### WorkspaceActivated
Occurs when the user switches tags or selects a window from the overview.
```json
{
  "WorkspaceActivated": {
    "id": 1,
    "name": "Web",
    "focused": true
  }
}
```

#### WindowFocusChanged
Occurs when the keyboard focus shifts.
```json
{
  "WindowFocusChanged": {
    "id": 12345
  }
}
```

#### WindowOpened
Occurs when a new window appears.
```json
{
  "WindowOpened": {
    "id": 12345,
    "title": "Terminal",
    "app_id": "alacritty"
  }
}
```

#### WindowClosed
Occurs when a window is destroyed.
```json
{
  "WindowClosed": {
    "id": 12345
  }
}
```
