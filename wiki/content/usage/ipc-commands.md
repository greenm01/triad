+++
title = "IPC & Commands"
weight = 10
+++

# IPC & Commands

Triad communicates over a Unix socket at `$XDG_RUNTIME_DIR/triad.sock` (falls back to `/tmp/triad.sock`).

Send any command with:

```bash
triad msg <command> [arguments]
```

---

## General & Diagnostics

| Command | Description |
|---|---|
| `commands [--json]` | List all available commands. |
| `validate <command…>` | Validate a command locally without sending it. |
| `request <json>` | Send a raw JSON IPC request. |
| `state` | Print current session state as JSON. |
| `capabilities` | Print native Triad IPC feature capabilities as JSON. |
| `workspaces` | Print current workspace state as JSON. |
| `outputs` | Print current output state as JSON. |
| `windows` | Print current window state as JSON. |
| `focused-window` | Print focused window state as JSON. |
| `overview-state` | Print overview state as JSON. |
| `keyboard-layouts` | Print keyboard layout state as JSON. |
| `layout-state` | Print layout state for all visible workspaces. |
| `switch-keyboard-layout [next\|prev\|index]` | Switch active keyboard layout. |
| `perf-status` | Print daemon performance and timing diagnostics. |
| `mem-status` | Print memory diagnostics. |
| `config-reload` | Reload the configuration file. |
| `triad-reload` | Write a live-restore snapshot and restart the manager. |
| `dispatch-binding <kind> <chord>` | Trigger a configured binding, e.g. `key Super+Return`. |

---

## Navigation

| Command | Description |
|---|---|
| `focus-next` / `focus-prev` | Shift focus to the next or previous window. |
| `focus-left` / `focus-right` / `focus-up` / `focus-down` | Move focus spatially. |
| `focus-last` | Return focus to the previously focused window. |
| `focus-workspace <index>` | Focus a workspace by compact index. |
| `focus-tag <id>` | Focus a workspace by stable tag ID. |
| `focus-window <id>` | Focus a specific window by ID. |
| `new-workspace` | Create and focus a new dynamic workspace. |
| `focus-tag-left` / `focus-tag-right` | Move to the adjacent workspace. |
| `focus-occupied-tag-left` / `focus-occupied-tag-right` | Skip empty workspaces. |
| `focus-column-first` / `focus-column-last` | Jump to the first or last column in the scroller. |
| `toggle-overview` | Toggle the bird's-eye workspace view. |
| `recent-window-next` / `recent-window-prev` | Navigate the MRU switcher. |
| `recent-window-confirm` / `recent-window-cancel` | Confirm or cancel the switcher selection. |
| `toggle-scratchpad` | Show or hide the default scratchpad. |
| `toggle-named-scratchpad <name>` | Show or hide a named scratchpad pool. |

---

## Layout

| Command | Description |
|---|---|
| `scroller`, `grid`, `notion`, `dwindle`, `center-tile`, `spiral`, `i3` | Select a layout by its layout ID. |
| `layout-scroller`, `layout-grid`, `layout-spiral`, ... | Legacy explicit aliases for common layouts. |
| `layout-custom <name>` | Select a user-declared Janet layout when it is not one of Triad's bundled layout IDs. |
| `layout-native <name>` | Select a native substrate: `frame-tree`, `bsp-tree`, or `i3`. |
| `switch-layout` | Cycle through the configured `layout-cycle`. |
| `set-layout-for-workspace <tag> <layout>` | Set a layout on a specific workspace by tag ID. |

### Master-Stack

| Command | Description |
|---|---|
| `master-count <n>` / `adjust-master-count <delta>` | Set or adjust the number of master windows. |
| `master-ratio <ratio>` / `adjust-master-ratio <delta>` | Set or adjust the master area size. |

### Frame-Tree (Notion)

| Command | Description |
|---|---|
| `frame-split-horizontal` / `frame-split-vertical` | Split the focused frame. |
| `frame-unsplit` | Remove the focused empty frame. |
| `frame-tab-next` / `frame-tab-prev` | Cycle tabs within a frame. |

### BSP & Dwindle

| Command | Description |
|---|---|
| `bsp-balance` / `bsp-equalize` | Rebalance the tree or reset split ratios. |
| `bsp-preselect-left` / `-right` / `-up` / `-down` | Set the insertion target for the next window. |
| `bsp-preselect-cancel` | Clear the pending insertion target. |

### Split-Tree (i3)

| Command | Description |
|---|---|
| `split-tree-split-horizontal` / `split-tree-split-vertical` | Set insertion direction. |
| `split-tree-layout-toggle-split` | Toggle horizontal/vertical orientation. |
| `split-tree-layout-stacking` / `split-tree-layout-tabbed` | Set container mode. |
| `split-tree-focus-parent` / `split-tree-focus-child` | Navigate the container hierarchy. |

---

## Window Manipulation

| Command | Description |
|---|---|
| `close-window` | Request the focused window to close. |
| `toggle-floating` | Toggle between tiled and floating. |
| `fullscreen-window` | Toggle fullscreen mode. |
| `toggle-maximized` | Toggle the client-visible maximized state. |
| `move-to-tag <id>` / `move-to-workspace <index>` | Move the window and follow focus. |
| `move-window-to-tag <id> <tag> [follow]` | Move a specific window by ID. |
| `move-to-scratchpad` / `move-to-named-scratchpad <name>` | Send the window to a scratchpad pool. |
| `group-windows` | Group the window with its neighbor. |
| `ungroup-window` | Dissolve the active group. |
| `maximize-column` | Toggle the focused column to full width. |
| `set-column-width <proportion>` | Set exact column width, e.g. `0.5`. |
| `resize-width <delta>` / `resize-height <delta>` | Adjust window proportions. |
| `move-column-left` / `move-column-right` | Swap columns in the scroller. |
| `move-window-left` / `-right` / `-up` / `-down` | Swap windows directionally. |
| `consume-window` / `expel-window` | Merge or split windows from columns. |

---

## System & Session

| Command | Description |
|---|---|
| `spawn <argv…>` | Run a command. |
| `spawn-terminal` | Launch the configured terminal. |
| `screenshot [--path <path>]` | Capture a region, window, or screen. |
| `lock-session` | Launch the configured screen locker. |
| `exit-session` | Exit the session (requires `allow-exit-session #true` in config). |
| `rename-tag <name>` | Rename the active workspace. |
| `warp-pointer <x> <y>` | Warp the pointer on all active seats. |

---

## Event Stream

Triad broadcasts state changes in a Niri-compatible JSON format. Subscribe with:

```bash
triad msg event-stream
```

| Event | Fired when |
|---|---|
| `WorkspaceActivated` | Workspace switches. |
| `WindowFocusChanged` | Focus moves to a different window. |
| `WindowOpened` / `WindowClosed` | A window appears or disappears. |

---

## Native JSON IPC

For scripting, send requests directly over `$TRIAD_SOCKET`.

### Request

```json
{"triad":{"version":1,"request":"state"}}
```

### Response

```json
{
  "ok": true,
  "triad": {
    "version": 1,
    "type": "state",
    "state": { }
  }
}
```

### Action

```json
{"triad":{"version":1,"request":"action","action":"focus-workspace","workspace_idx":2}}
```

### Subscribe

```json
{"triad":{"version":1,"request":"event-stream","events":["state","layout"]}}
```

Triad sends an initial snapshot for each requested kind, then streams updates as they occur.
