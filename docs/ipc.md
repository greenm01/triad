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
*   `capabilities`: Prints native Triad IPC feature capabilities as JSON, including workspace creation/switching/content-scroll, overview, window, spawn, keyboard-layout, output metadata, monitor-power, and workspace-urgency support flags.
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
*   `power-off-monitor <output>`: Disables one output target, such as `DP-3`.
*   `power-on-monitor <output>`: Enables one output target and clears its monitor-power restore entry.
*   `perf-status`: Prints daemon performance, timing, loop wake, and IPC broadcast diagnostics.
*   `mem-status`: Prints memory and IPC subscriber diagnostics.
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
*   `new-workspace`: Reuses an inactive empty configured dynamic workspace on the
    active output, or creates and focuses the next dynamic workspace.
*   `focus-tag-left` / `focus-tag-right`: Moves to the adjacent workspace.
*   `focus-occupied-tag-left` / `focus-occupied-tag-right`: Skips empty tags.
*   `focus-column-first` / `focus-column-last`: Jumps to the edge of the scroller.
*   `focus-window-or-workspace-up` / `focus-window-or-workspace-down`: Moves focus between windows or wraps to the adjacent workspace.
*   `toggle-overview`: Toggles the bird's-eye workspace view.
*   `recent-window-next` / `recent-window-prev`: Navigates the MRU switcher.
*   `recent-window-confirm` / `recent-window-cancel`: Confirms or cancels the switcher.
*   `recent-window-first` / `recent-window-last`: Jumps to the start or end of history.
*   `recent-window-scope [all|workspace|output]`: Sets the MRU filter scope.
*   `recent-window-cycle-scope`: Cycles through available MRU scopes.
*   `recent-window-close-current`: Closes the window currently selected in the switcher.
*   `toggle-scratchpad`: Shows or hides the default scratchpad.
*   `toggle-named-scratchpad <name>`: Manages named scratchpad pools.

### Layout Management
Set the layout mode for the active workspace:
*   Short layout IDs such as `scroller`, `vertical-scroller`, `grid`, `notion`, `dwindle`,
    `center-tile`, `spiral`, and `i3`.
*   Legacy explicit aliases such as `layout-scroller`, `layout-vertical-scroller`, `layout-grid`,
    `layout-center-tile`, `layout-spiral`, and `layout-tgmix`.
*   `layout-custom <name>`: Selects a user-declared Janet layout when the
    short ID is not one of Triad's built-in or bundled layout IDs.
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
*   `frame-focus-parent` / `frame-focus-child`: Navigates the frame hierarchy.
*   `frame-bind-app` / `frame-unbind-app`: Binds or unbinds an application ID to a specific frame.

#### BSP & Dwindle
*   `bsp-balance` / `bsp-equalize`: Rebalances the tree or resets split ratios.
*   `bsp-preselect-left` / `-right` / `-up` / `-down`: Sets the insertion target for the next window.
*   `bsp-preselect-cancel`: Clears the pending insertion target.
*   `bsp-preselect-ratio <ratio>`: Sets the split ratio for the next preselected window.
*   `dwindle-split-left` / `-right` / `-up` / `-down`: Manual split direction for dwindle.
*   `dwindle-split-horizontal` / `dwindle-split-vertical`: Fixed orientation splitting.

#### Split-Tree (i3)
*   `split-tree-split-horizontal` / `split-tree-split-vertical`: Sets insertion direction.
*   `split-tree-layout-toggle-split`: Toggles horizontal/vertical orientation.
*   `split-tree-layout-stacking` / `split-tree-layout-tabbed`: Sets container mode.
*   `split-tree-layout-cycle-all`: Cycles through all available container modes.
*   `split-tree-layout-cycle <modes...>`: Cycles through a specific list of modes.
*   `split-tree-layout-default`: Resets the container to the default split mode.
*   `split-tree-focus-parent` / `split-tree-focus-child`: Navigates the container hierarchy.
*   `split-tree-focus-next-sibling` / `split-tree-focus-prev-sibling`: Moves focus between siblings in a split container.

### Window Manipulation
*   `close-window`: Requests the window to close.
*   `toggle-floating`: Toggles between tiled and floating states.
*   `fullscreen-window`: Toggles fullscreen mode.
*   `toggle-maximized`: Toggles the client-visible maximized state.
*   `move-to-tag <id>` / `move-to-workspace <index>`: Moves the focused window and follows focus.
*   `move-window-to-tag <id> <tag> [follow]`: Moves a specific window by ID to a tag.
*   `move-window-to-workspace <id> <index> [follow]`: Moves a specific window by ID to a workspace.
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
*   `focus-shell-ui`: Shifts focus to the shell UI surface.
*   `switch-shell <name>`: Switches the active shell profile.
*   `cycle-shell`: Cycles through the configured `shells.cycle` profiles.
*   `show-hotkey-overlay` / `hide-hotkey-overlay`: Manages the keybinding guide.
*   `toggle-hotkey-overlay`: Toggles the keybinding guide.
*   `rename-tag <name>`: Renames the active workspace.
*   `warp-pointer <x> <y>`: Warps the pointer on all active seats.

---

## Event Stream

Triad broadcasts state changes over its native event stream. It can also expose
the compatibility JSON schema used by Waybar's `niri/workspaces` module and
shells like Noctalia, DankMaterialShell, and Waylee.

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
{"triad":{"version":1,"request":"event-stream","events":["state", "layout", "window"]}}
```
Triad sends an initial state for each kind, then pushes updates as they occur.
The `window` stream carries compact metadata events such as `window-changed`
for title-only updates, avoiding a full `state-changed` snapshot when the
layout and structural state are unchanged.
Native event-stream clients are removed when their socket disconnects or when
a send fails, so shell reloads do not leave stale subscribers behind.

Workspace objects include `is_urgent`. The `workspace_urgency` capability is
currently `false`, so consumers should treat urgency as a stable field reserved
for future protocol support rather than a real attention signal today.
