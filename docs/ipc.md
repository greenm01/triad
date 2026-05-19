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
    spatially within the active tag. In overview, these keep normal layout
    semantics inside the focused workspace and switch workspaces at the edge.
    In frame-tree layouts, all four directions navigate between frames.
*   `focus-last`: Returns focus to the previous focused window when it is still available.
*   `focus-workspace <index>`: Focuses the compact Niri-style workspace index currently shown by shell UI.
*   `focus-tag <id>`: Focuses a stable Triad tag id directly.
*   `focus-window <id>`: Focuses a specific compositor window ID.
*   `focus-tag-left`, `focus-tag-right`: Moves to the adjacent visible
    workspace, creating the next dynamic workspace when appropriate. In
    overview, these wrap through every visible workspace preview, including
    empty default workspaces and visible dynamic empty workspaces.
*   `focus-occupied-tag-left`, `focus-occupied-tag-right`: Moves to the adjacent non-empty tag.
*   `focus-column-first`, `focus-column-last`: Focuses the first or last visible column on the active tag.
*   `focus-window-or-workspace-up`, `focus-window-or-workspace-down`: Moves vertically within the focused column, or switches to the adjacent tag at the edge.
*   `toggle-overview`: Activates or deactivates the unified workspace-strip
    overview for every layout.
*   `open-overview`, `close-overview`: Idempotently opens or closes the overview.
*   `recent-window-next [--scope all|workspace|output] [--filter all|app-id]`:
    Opens or advances the recent-windows switcher toward older MRU entries.
*   `recent-window-prev [--scope all|workspace|output] [--filter all|app-id]`:
    Opens or advances the recent-windows switcher toward newer MRU entries.
*   `recent-window-confirm`, `recent-window-cancel`: Closes the switcher and
    either focuses the selected window or leaves focus unchanged.
*   `recent-window-first`, `recent-window-last`: Jumps to the first or last
    visible switcher candidate.
*   `recent-window-scope all|workspace|output`,
    `recent-window-cycle-scope`: Changes the active switcher scope.
*   `recent-window-close-current`: Requests close for the selected switcher
    window without leaving the switcher.
*   `toggle-scratchpad`: Shows the next standard scratchpad window as a centered
    overlay, focuses it, or hides the visible scratchpad and restores workspace
    focus.
*   `toggle-named-scratchpad <name>`: Shows or hides a named scratchpad; if the name is new, the focused window is assigned to it.
*   `restore-scratchpad`: Moves the visible or next standard scratchpad window
    back to the workspace it occupied before entering scratchpad.
*   `select-window`: In overview mode, selects the focused window and jumps to its tag.
*   `rename-tag <name>`: Bestows a new, more dignified name upon the active tag.
*   `lock-session`: Launches the configured `screen-lock` command.
*   `focus-shell-ui`: Focuses Triad's internal River shell surface when present.
*   `switch-shell <name>`: Stops the active configured shell profile and starts the named profile.
*   `cycle-shell`: Rotates through the configured `shells.cycle` profile list.
*   `dev-mode [on|off|toggle|status]`: Shows or changes the running daemon's
    developer diagnostics mode. `on` enables behavior JSONL logging for the
    live process, `off` disables it, `toggle` flips the current state, and no
    argument is equivalent to `status`.
*   `perf-status`: Prints daemon frame pacing, idle wake timing, wait backend,
    render-start skip counters, layout-projection counters, and render request
    counters as JSON for live CPU investigations.
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
*   `layout-spiral`: Sets the active tag to bundled Spiral recursive-split mode.
*   `set-layout-for-workspace <tag> <layout>`: Sets a stable tag id to a
    built-in layout id or declared custom layout name without changing focus.
*   `layout-custom <name>`: Sets the active tag to a declared Janet layout.
*   `layout-state`: Prints the native JSON layout-state reply for the running
    session.
*   `switch-layout`: Advances the active tag through the configured `layout-cycle`.
    `triad msg switch-layout` prints the native JSON ack after the request is
    accepted.
    Niri-compatible `SwitchLayout` is separate keyboard-layout vocabulary and
    switches configured River XKB keyboard layouts instead of triggering this
    command.
*   `frame-split-horizontal`, `frame-split-vertical`: Splits the focused
    frame. When the frame has multiple tabs, the active tab moves into the new
    sibling frame; when it has one tab, focus stays on the original frame and
    the new sibling starts empty. Splitting an already-empty frame is a no-op;
    use `frame-unsplit` to remove the focused empty frame.
*   `frame-unsplit`: Removes the focused empty frame and promotes its sibling.
*   `frame-tab-next`, `frame-tab-prev`: Cycles tabs in the focused frame. In
    native `i3`, the same commands cycle the focused tabbed or stacking split
    container.
*   `split-tree-layout-toggle-split`: In native `i3`, toggles the focused
    split container between horizontal and vertical split layout, returning
    from tabbed or stacking to the last split layout.
*   `split-tree-layout-stacking`, `split-tree-layout-tabbed`: In native `i3`,
    changes the focused split container to i3-style stacking or tabbed mode.

#### Manipulation
*   `move-to-tag <id>`: Moves the focused window to the specified tag and focuses that tag.
*   `move-to-workspace <index>`: Moves the focused window to the compact Niri-style workspace index and focuses that workspace.
*   `move-window-to-tag <id> <tag> [follow]`: Moves a specific compositor
    window ID to a tag. `follow` defaults to `false`.
*   `move-window-to-workspace <id> <index> [follow]`: Moves a specific
    compositor window ID to a compact workspace index. `follow` defaults to
    `false`.
*   `move-to-tag-left`, `move-to-tag-right`: Moves the focused window to the adjacent visible workspace and focuses it, creating the next dynamic workspace when appropriate.
*   `move-to-scratchpad`: Moves the focused window to the scratchpad.
*   `move-to-named-scratchpad <name>`: Moves the focused window to a named scratchpad.
*   `close-window`: Politely requests that the focused window close.
*   `group-windows`: Groups the focused window with its next rendered neighbor.
    Scroller layouts first move the neighbor into the focused column; frame-tree
    layouts move it into the focused frame. BSP layouts ignore this command.
*   `ungroup-window`: Dissolves the focused window's group.
*   `focus-next-in-group`: Cycles focus through the windows of the focused group.
*   `toggle-floating`: Toggles the focused window between tiled and floating states.
*   `set-window-floating <id> true|false`: Sets floating state for a specific
    compositor window ID.
*   `fullscreen-window`, `toggle-fullscreen`: Commands the window to occupy the entire screen.
*   `maximize-window-to-edges`, `toggle-maximized`: Toggles client-visible window maximize.
*   `set-window-maximized <id> true|false`: Sets client-visible maximize state
    for a specific compositor window ID.
*   `move-floating <dx> <dy>`: Displaces a floating window by the specified pixel deltas.
*   `resize-floating <dw> <dh>`: Adjusts the physical dimensions of a floating window.
*   `zoom`: Swaps the focused window with the primary window in the master position.
*   `resize-width <delta>`: Adjusts the width proportion (e.g., `0.1` or `-0.1`). In BSP layouts, adjusts the nearest horizontal split fence for the focused leaf.
*   `resize-height <delta>`: Adjusts the height proportion. In BSP layouts, adjusts the nearest vertical split fence for the focused leaf.
*   `bsp-balance`: Rebalances the active BSP tree by leaf counts.
*   `bsp-equalize`: Resets active BSP split ratios to `0.5`.
*   `bsp-preselect-left`, `bsp-preselect-right`, `bsp-preselect-up`, `bsp-preselect-down`: Marks the focused BSP leaf as the insertion target for the next tiled window, choosing the side where the new window appears.
*   `dwindle-split-left`, `dwindle-split-right`, `dwindle-split-up`, `dwindle-split-down`, `dwindle-split-horizontal`, `dwindle-split-vertical`: Dwindle-facing aliases for BSP preselection policy. Horizontal selects right insertion; vertical selects down insertion.
*   `bsp-preselect-ratio <ratio>`: Sets the preselected split ratio. If no side is selected yet, Triad defaults to the right side.
*   `bsp-preselect-cancel`: Clears the focused BSP leaf preselection.
*   `maximize-column`: Toggles the focused column to full width while keeping gaps, borders, and client state unchanged.
*   `set-column-width <proportion>`: Precisely dictates the width of the focused column (e.g., `0.5`, `1.0`).
*   `switch-proportion-preset [delta]`: Cycles the focused scroller column through `layout.scroller-proportion-presets`; negative deltas cycle backward.
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
*   `config-reload`: Reloads the KDL config without restarting Triad or the configured shell profile unless the shell config changed.
*   `triad-reload`: Writes a live-restore snapshot and stops the active River
    manager so the normal session restart path can start a replacement. It
    preserves dev mode only when the active daemon is already in dev mode.
*   `dump-live-restore-state`: Prints a versioned JSON snapshot used by live reload to preserve workspaces, focus history, sizing, and window state.
*   `perf-status`: Prints frame-rate selection, idle wake timing, wait backend,
    whether a frame tick is currently active, and cumulative render/manage
    counters including skipped clean render starts.
*   `stop-manager`: Sends `river_window_manager_v1.stop`.
*   `exit-session`: Opens a confirmation dialog, then sends `river_window_manager_v1.exit_session` after Enter only when `allow-exit-session #true` is configured.
    Niri-compatible `Quit` maps to this command, and `Quit` with
    `skip_confirmation` bypasses only the confirmation dialog while still
    honoring `allow-exit-session`.

#### Pointer Bindings
`pointer-bind` and `axis-bind` entries in `config.kdl` use the same command
strings as IPC and keyboard bindings:

```kdl
pointer-bind "Super+left" "move"
pointer-bind "Super+right" "resize"
pointer-bind "Super+middle" "toggle-maximized"
pointer-bind "right" "close-window" mode="overview"
axis-bind "Super+wheel-up" "focus-left"
axis-bind "Super+wheel-down" "focus-right"
```

`move` and `resize` start River pointer operations. Other commands are parsed
as normal Triad commands and target the window under the pointer when the
command is window-specific. `axis-bind` supports `wheel-up`, `wheel-down`,
`wheel-left`, and `wheel-right`, and runs once per accumulated 120-unit wheel
detent. In overview, unmodified left-drag moves a window
preview to the hovered workspace, unmodified right-drag pans the hovered
workspace camera, unmodified vertical wheel switches workspace previews,
unmodified horizontal wheel focuses columns, and Shift+vertical wheel focuses
columns when no configured `axis-bind` consumes that wheel direction. The drag
overrides overview right-click close while overview is open. `gesture-bind`
uses live touchpad swipe events when the compositor advertises
`zwp_pointer_gestures_v1`.

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
*   `move-window-left`: Swaps the focused window with the same leftward target that directional focus would choose. In frame layouts, an empty target frame receives the focused window.
*   `move-window-right`: Swaps the focused window with the same rightward target that directional focus would choose. In frame layouts, an empty target frame receives the focused window.
*   `move-window-up`: Swaps the focused window with the same upward target that directional focus would choose. In frame layouts, an empty target frame receives the focused window.
*   `move-window-down`: Swaps the focused window with the same downward target that directional focus would choose. In frame layouts, an empty target frame receives the focused window.
*   `move-window-up-or-to-workspace-up`: Moves the focused window upward within the current layout, or to the previous tag when there is no upward layout target.
*   `move-window-down-or-to-workspace-down`: Moves the focused window downward within the current layout, or to the next tag when there is no downward layout target.
*   `swap-window-up`: An alias for `move-window-up`.
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
{"ok":false,"error":"unknown layout: missing-layout"}
```

Native Triad state is generated from Triad's internal shell snapshot. The Niri
compatibility socket is a separate projection of that same snapshot; Triad-only
fields are not added to the Niri protocol. This keeps the compatibility layer
predictable while giving new shells a richer protocol they can adopt when they
are ready.

Window and output IDs on IPC surfaces are numeric external compositor IDs. They
are stable for the lifetime of the compositor object, but they are not Triad's
internal logical `WindowId` or `OutputId` values.

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
        {"id": 42, "name": "Virtual-1", "is_primary": true, "refresh_rate": 144000}
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

The reply contains supported built-in and custom layout ids, the configured
layout cycle, the active tag/workspace index, and layout state for every visible
workspace:

```json
{
  "ok": true,
  "triad": {
    "version": 1,
    "type": "layout-state",
    "state": {
      "version": 1,
      "layouts": [
        {"kind": "builtin", "id": "scroller", "ordinal": 0},
        {"kind": "custom", "id": "spiral", "fallback_layout": "scroller"}
      ],
      "layout_cycle": ["scroller", "tile", "grid"],
      "layout_cycle_entries": [
        {"kind": "builtin", "id": "scroller"}
      ],
      "active_tag": 1,
      "active_workspace_idx": 1,
      "workspaces": [
        {
          "tag_id": 1,
          "workspace_idx": 1,
          "name": "term",
          "layout": "scroller",
          "layout_kind": "builtin",
          "fallback_layout": "scroller",
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

Custom layout ids are the declared Janet layout names.

### Layout Actions

Set the active tag layout:

```json
{"triad":{"version":1,"request":"set-layout","layout":"grid"}}
```

Set the active tag to a declared Janet layout:

```json
{"triad":{"version":1,"request":"set-layout","layout":"spiral"}}
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

### Native Actions

Native actions mirror the same command names accepted by `triad msg <command>`
and config bindings:

```json
{"triad":{"version":1,"request":"action","action":"focus-workspace","workspace_idx":2}}
{"triad":{"version":1,"request":"action","action":"set-column-width","value":0.75}}
{"triad":{"version":1,"request":"action","action":"spawn","argv":["foot","--working-directory","/tmp"]}}
```

Actions without arguments only need the `action` name. Argument-bearing actions
use structured fields:

- `id` for window-id commands such as `focus-window`, `close-window`,
  `fullscreen-window`, `toggle-fullscreen`, and `exit-fullscreen`.
- `id` plus `tag`, `workspace_idx`, `follow`, or `value` for targeted window
  actions such as `move-window-to-tag`, `move-window-to-workspace`,
  `set-window-floating`, and `set-window-maximized`.
- `tag` plus `layout` for `set-layout-for-workspace`.
- `tag` for tag commands and `workspace_idx` for shell workspace commands.
- `name` for `rename-tag`, `move-to-named-scratchpad`, and
  `toggle-named-scratchpad`.
- `output` for `focus-output`, `move-workspace-to-output`, and
  `move-to-output`.
- `delta`, `value`, `count`, `dx`, `dy`, `dw`, and `dh` for sizing and layout
  adjustment commands.
- `scope` and `filter` for recent-window actions.
- `argv` for `spawn`. Niri-compatible `Spawn` and `SpawnSh` actions use the
  same configured-process spawn path for shell clients.
- `x` and `y` for `warp-pointer`.
- Screenshot actions accept `path`, `show_pointer`, `write_to_disk`, and
  `copy_to_clipboard`.

The layout-specific action names such as `layout-grid`, `layout-tgmix`, and `layout-spiral`
remain available for command parity and affect the active tag. Prefer
`request:"set-layout"` when a shell needs to target a specific tag or workspace
without changing focus.

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

See `docs/the_triad.md` for why this combination enables powerful external
orchestration.
