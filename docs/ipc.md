# Triad IPC Protocol & Commands

## Inter-Process Communication

Triad employs a Unix Domain Socket for two-way communication with external clients. By default, the socket resides at `$XDG_RUNTIME_DIR/triad.sock`. Should that environment variable be absent, it retreats to `/tmp/triad.sock`.

### Commands

To dispatch a command to the running Triad instance, use the following syntax:
`triad msg <command> [arguments]`

#### Navigation
*   `focus-next`: Shifts keyboard focus to the next window in the sequence.
*   `focus-prev`: Shifts keyboard focus to the previous window.
*   `focus-left`, `focus-right`, `focus-up`, `focus-down`: Moves focus
    spatially within the active tag. When overview is open, these move through
    the visible overview grid.
*   `focus-last`: Returns focus to the previous focused window when it is still available.
*   `focus-workspace <index>`: Focuses the compact Niri-style workspace index currently shown by shell UI.
*   `focus-tag <id>`: Focuses a stable Triad tag id directly.
*   `focus-tag-left`, `focus-tag-right`: Moves to the adjacent visible workspace, creating the next dynamic workspace when appropriate.
*   `focus-occupied-tag-left`, `focus-occupied-tag-right`: Moves to the adjacent non-empty tag.
*   `focus-column-first`, `focus-column-last`: Focuses the first or last visible column on the active tag.
*   `focus-window-or-workspace-up`, `focus-window-or-workspace-down`: Moves vertically within the focused column, or switches to the adjacent tag at the edge.
*   `toggle-overview`: Activates or deactivates the overview. Scroller
    layouts show Niri-style workspace previews; other layouts show the
    Mango-style global window grid.
*   `open-overview`, `close-overview`: Idempotently opens or closes the overview.
*   `toggle-scratchpad`: Shows the most recent scratchpad window as a centered overlay, or hides it.
*   `toggle-named-scratchpad <name>`: Shows or hides a named scratchpad; if the name is new, the focused window is assigned to it.
*   `restore-scratchpad`: Moves the visible or most recent scratchpad window back to the active tag.
*   `select-window`: In overview mode, selects the focused window and jumps to its tag.
*   `rename-tag <name>`: Bestows a new, more dignified name upon the active tag.
*   `lock-session`: Launches the configured `screen-lock` command.
*   `focus-shell-ui`: Focuses Triad's internal River shell surface when present.
*   `show-hotkey-overlay`, `hide-hotkey-overlay`, `toggle-hotkey-overlay`:
    Opens, closes, or toggles Triad's native keyboard helper popup.

#### Layout Management
*   `layout-scroller`: Sets the active tag to horizontal scrolling mode.
*   `layout-vertical-scroller`: Sets the active tag to vertical scrolling mode.
*   `layout-tile`: Sets the active tag to Master-Stack tiling mode.
*   `layout-grid`: Sets the active tag to geometric grid mode.
*   `layout-monocle`: Sets the active tag to fullscreen monocle mode.
*   `layout-deck`: Sets the active tag to master plus deck-stack mode.
*   `layout-center-tile`: Sets the active tag to a centered master with side stacks.
*   `layout-right-tile`: Sets the active tag to a right-side master with stack on the left.
*   `layout-vertical-tile`: Sets the active tag to a top master with horizontal stack below.
*   `layout-vertical-grid`: Sets the active tag to a row-first grid.
*   `layout-vertical-deck`: Sets the active tag to a top master with deck-stack below.
*   `layout-tgmix`: Sets the active tag to tile mode for up to three windows,
    then grid mode for larger sets.
*   `switch-layout`: Advances the active tag through the configured `layout-cycle`.

#### Manipulation
*   `move-to-tag <id>`: Moves the focused window to the specified tag and focuses that tag.
*   `move-to-workspace <index>`: Moves the focused window to the compact Niri-style workspace index and focuses that workspace.
*   `move-to-tag-left`, `move-to-tag-right`: Moves the focused window to the adjacent visible workspace and focuses it, creating the next dynamic workspace when appropriate.
*   `move-to-scratchpad`: Moves the focused window to the scratchpad.
*   `move-to-named-scratchpad <name>`: Moves the focused window to a named scratchpad.
*   `close-window`: Politely requests that the focused window close.
*   `group-windows`: Orchestrates the union of the focused window and its neighbor into a single tabbed group.
*   `ungroup-window`: Dissolves the group, granting the focused window its independence.
*   `focus-next-in-group`: Cycles focus through the windows of a tabbed group.
*   `toggle-floating`: Toggles the focused window between tiled and floating states.
*   `fullscreen-window`, `toggle-fullscreen`: Commands the window to occupy the entire screen.
*   `maximize-window-to-edges`, `toggle-maximized`: Toggles client-visible window maximize.
*   `move-floating <dx> <dy>`: Displaces a floating window by the specified pixel deltas.
*   `resize-floating <dw> <dh>`: Adjusts the physical dimensions of a floating window.
*   `zoom`: Swaps the focused window with the primary window in the master position.
*   `resize-width <delta>`: Adjusts the width proportion (e.g., `0.1` or `-0.1`).
*   `resize-height <delta>`: Adjusts the height proportion.
*   `maximize-column`: Toggles the focused column to full width while keeping gaps, borders, and client state unchanged.
*   `set-column-width <proportion>`: Precisely dictates the width of the focused column (e.g., `0.5`, `1.0`).
*   `adjust-gaps <delta>`: Increases or decreases the global gap size (e.g., `5` or `-5`).
*   `toggle-gaps`: Instantly eliminates all gaps or restores them to their former glory.
*   `warp-pointer <x> <y>`: Requests a River pointer warp on every active seat.
*   `eat-next-key`: Requests River XKB handling to eat the next unbound key.
*   `cancel-eat-next-key`: Cancels the pending River XKB key-eat request.
*   `toggle-keyboard-shortcuts-inhibit`: Toggles whether the focused window inhibits Triad keyboard shortcuts.
*   `focus-last`: Useful with `allow-inhibiting=#false` as a VM escape hatch, e.g. `Ctrl+Alt+Escape` in the default config.
*   `screenshot`: Captures an interactively selected region.
*   `screenshot-screen`: Captures the primary output geometry known to Triad.
*   `screenshot-window`: Captures the focused window geometry known to Triad.
*   Screenshot flags: `--path <path>`, `--show-pointer`,
    `--hide-pointer`, `--no-clipboard`, and `--clipboard-only`.
*   `config-reload`: Reloads the KDL config without restarting Triad or the configured shell unless the shell config changed.
*   `triad-reload`: Writes a live-restore snapshot and stops the active River
    manager so the normal session restart path can start a replacement.
*   `dump-live-restore-state`: Prints a versioned JSON snapshot used by live reload to preserve workspaces, focus history, sizing, and window state.
*   `stop-manager`: Sends `river_window_manager_v1.stop`.
*   `exit-session`: Sends `river_window_manager_v1.exit_session` only when `allow-exit-session #true` is configured.

#### Pointer Bindings
`pointer-bind` entries in `config.kdl` use the same command strings as IPC and
keyboard bindings:

```kdl
pointer-bind "Super+left" "move"
pointer-bind "Super+right" "resize"
pointer-bind "Super+middle" "toggle-maximized"
pointer-bind "right" "close-window" mode="overview"
```

`move` and `resize` start River pointer operations. Other commands are parsed
as normal Triad commands and target the window under the pointer when the
command is window-specific. In the Niri-style scroller overview, unmodified
left-drag moves a window preview to the hovered workspace, and unmodified
right-drag scrolls the workspace preview stack; this overrides overview
right-click close only for that scroller overview mode. Mouse-wheel and
touchpad gesture bindings are not part of the current River input surface Triad
receives.

#### Master-Stack Refinements
*   `master-count <n>`: Sets the exact number of windows allowed in the master area.
*   `adjust-master-count <delta>`: Increments or decrements the master window count.
*   `master-ratio <ratio>`: Sets the master area split ratio (e.g., `0.6`).
*   `adjust-master-ratio <delta>`: Fine-tunes the master split ratio.

#### Advanced Movement
*   `move-column-left`: Swaps the focused column with its neighbor to the left.
*   `move-column-right`: Swaps the focused column with its neighbor to the right.
*   `move-column-to-first`: Moves the focused column to the first position.
*   `move-column-to-last`: Moves the focused column to the last position.
*   `move-window-left`: Transports the focused window to the adjacent column on the left, creating a new column if necessary.
*   `move-window-right`: Transports the focused window to the adjacent column on the right.
*   `move-window-up`: Swaps the focused window with the one above it in a stack.
*   `move-window-down`: Swaps the focused window with the one below it.
*   `move-window-up-or-to-workspace-up`: Moves the focused window up in its column, or to the previous tag at the edge.
*   `move-window-down-or-to-workspace-down`: Moves the focused window down in its column, or to the next tag at the edge.
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

---

## Native Triad JSON IPC

Triad has two shell-facing IPC surfaces with different purposes:

- `$TRIAD_SOCKET` is Triad's native protocol. It is the long-term integration
  surface for shell deployers and Quickshell themes that want to understand
  Triad directly.
- `$NIRI_SOCKET` is a compatibility projection. It lets existing Niri-aware
  shells, including Noctalia-shell and DankMaterialShell, work today without
  forks.

Future shell integrations should prefer the native Triad protocol. It exposes
Triad's tag-first model directly: stable tag IDs, compact shell workspace
indices, per-tag layout modes, layout cycles, overview state, outputs, and
windows. The Niri protocol remains valuable, but it is intentionally a lossy
facade because Niri does not model Triad's per-tag hybrid layouts.

Native requests are line-delimited JSON sent to `$TRIAD_SOCKET`, which defaults
to `$XDG_RUNTIME_DIR/triad.sock`.

Native requests use a reserved top-level `triad` object and a version number:

```json
{"triad":{"version":1,"request":"layout-state"}}
```

Replies use a stable success envelope:

```json
{"ok":true,"triad":{"version":1,"type":"ack"}}
```

Errors use:

```json
{"ok":false,"error":"unknown layout: spiral"}
```

Native Triad state is generated from Triad's internal shell snapshot. The Niri
compatibility socket is a separate projection of that same snapshot; Triad-only
fields are not added to the Niri protocol. This keeps the compatibility layer
predictable while giving new shells a richer protocol they can adopt when they
are ready.

### Shell State

Request:

```json
{"triad":{"version":1,"request":"state"}}
```

The reply contains the full native shell-facing state:

```json
{
  "ok": true,
  "triad": {
    "version": 1,
    "type": "state",
    "state": {
      "version": 1,
      "overview": {"is_open": false},
      "layout": {},
      "outputs": [
        {"id": 42, "name": "Virtual-1", "is_primary": true}
      ],
      "windows": [
        {
          "id": 10,
          "parent_id": null,
          "app_id": "Alacritty",
          "tag_id": 1,
          "workspace_idx": 1,
          "output": "Virtual-1",
          "is_focused": true
        }
      ]
    }
  }
}
```

### Layout State

Request:

```json
{"triad":{"version":1,"request":"layout-state"}}
```

The reply contains supported layout ids, the configured layout cycle, the active
tag/workspace index, and layout state for every visible workspace:

```json
{
  "ok": true,
  "triad": {
    "version": 1,
    "type": "layout-state",
    "state": {
      "version": 1,
      "layouts": [{"id": "scroller", "ordinal": 0}],
      "layout_cycle": ["scroller", "tile", "grid"],
      "active_tag": 1,
      "active_workspace_idx": 1,
      "workspaces": [
        {
          "tag_id": 1,
          "workspace_idx": 1,
          "name": "term",
          "layout": "scroller",
          "is_active": true,
          "focused_window_id": 10,
          "columns": [{"idx": 1, "width_proportion": 0.5, "windows": [10]}],
          "master_count": 1,
          "master_split_ratio": 0.55,
          "viewport": {
            "target_x": 0.0,
            "current_x": 0.0,
            "target_y": 0.0,
            "current_y": 0.0
          }
        }
      ]
    }
  }
}
```

Canonical layout ids are:

`scroller`, `vertical-scroller`, `tile`, `grid`, `monocle`, `deck`,
`center-tile`, `right-tile`, `vertical-tile`, `vertical-grid`,
`vertical-deck`, `tgmix`.

### Layout Actions

Set the active tag layout:

```json
{"triad":{"version":1,"request":"set-layout","layout":"grid"}}
```

Set a stable tag id without switching focus:

```json
{"triad":{"version":1,"request":"set-layout","layout":"deck","target":{"tag":4}}}
```

Set a compact shell workspace index without switching focus:

```json
{"triad":{"version":1,"request":"set-layout","layout":"monocle","target":{"workspace_idx":2}}}
```

Advance the active tag through the configured layout cycle:

```json
{"triad":{"version":1,"request":"switch-layout"}}
```

### Event Stream

Subscribe to native layout events:

```json
{"triad":{"version":1,"request":"event-stream","events":["layout"]}}
```

Subscribe to native full-state events:

```json
{"triad":{"version":1,"request":"event-stream","events":["state"]}}
```

After the acknowledgement, Triad sends an initial event for every requested
event kind and then pushes updates when relevant state changes:

```json
{"triad":{"version":1,"event":"layout-state-changed","state":{}}}
{"triad":{"version":1,"event":"state-changed","state":{}}}
```

Native Triad subscribers receive only native Triad events. Niri compatibility
subscribers continue to receive only Niri-shaped events.
