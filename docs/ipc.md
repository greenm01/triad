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
*   `select-window`: In overview mode, selects the focused window and jumps to its tag.

#### Layout Management
*   `layout-scroller`: Sets the active tag to horizontal scrolling mode.
*   `layout-vertical-scroller`: Sets the active tag to vertical scrolling mode.
*   `layout-tile`: Sets the active tag to Master-Stack tiling mode.
*   `layout-grid`: Sets the active tag to geometric grid mode.
*   `layout-monocle`: Sets the active tag to fullscreen monocle mode.

#### Manipulation
*   `move-to-tag <id>`: Banishes the focused window to the specified tag.
*   `toggle-floating`: Toggles the focused window between tiled and floating states.
*   `resize-width <delta>`: Adjusts the width proportion (e.g., `0.1` or `-0.1`).
*   `resize-height <delta>`: Adjusts the height proportion.
*   `adjust-gaps <delta>`: Increases or decreases the global gap size (e.g., `5` or `-5`).

#### Advanced Movement
*   `move-column-left`: Swaps the focused column with its neighbor to the left.
*   `move-column-right`: Swaps the focused column with its neighbor to the right.
*   `move-window-up`: Swaps the focused window with the one above it in a stack.
*   `move-window-down`: Swaps the focused window with the one below it.

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
