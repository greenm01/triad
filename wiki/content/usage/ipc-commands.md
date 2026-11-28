+++
title = "IPC & Commands"
weight = 10
+++

# IPC: Commands and Control

Triad talks through a Unix socket. Look at `$XDG_RUNTIME_DIR/triad.sock`. If it’s not there, check `/tmp/triad.sock`.

Send a command with the CLI:

```bash
triad msg <command> [arguments]
```

---

## The Basics

Ask Triad about its health and world.

| Command | Description |
|---|---|
| `commands` | Lists what you can do. |
| `state` | Dumps everything Triad knows. |
| `captures` | Shows River v5 screencopy capture-session counts. |
| `workspaces`, `outputs`, `windows` | Snippets of the state. |
| `perf-status`, `mem-status` | Shows the daemon's guts. |
| `config-reload` | Refreshes your settings. |
| `triad-reload` | Snaps a restore point and restarts. |

## Navigation

Move through your windows and tags.

| Command | Description |
|---|---|
| `focus-next` / `focus-prev` | Shift focus. |
| `focus-left/right/up/down` | Move focus spatially. |
| `focus-last` | Go back to the previous window. |
| `switch-focus-between-floating-and-tiling` | Jump between the floating windows and the tiled ones on your workspace. |
| `focus-workspace <index>` | Jump to a tag. |
| `new-workspace` | Grab a fresh tag. |
| `toggle-overview` | See the bird’s-eye view. |
| `toggle-scratchpad` | Hide your mess. |

## Layout

Pick a shape for your windows.

| Command | Description |
|---|---|
| `scroller`, `grid`, `i3`, `dwindle` | Choose a layout. |
| `switch-layout` | Cycle your favorites. |
| `master-count`, `master-ratio` | Command the master-stack. |

### Advanced Shapes
- **Notion:** Use `frame-split-horizontal` and `frame-split-vertical`.
- **BSP:** Balance the tree with `bsp-balance`.
- **i3:** Traditional splits with `split-tree-split-horizontal`.

## Window Mastery

Control the clients.

| Command | Description |
|---|---|
| `close-window` | Request a close. |
| `toggle-floating` | Break the grid. |
| `fullscreen-window` | Take it all. |
| `focus-window <id>` | Focus a specific window and restore it if minimized. |
| `minimize` / `restore-minimized` | Hide the focused window, then restore the most recently minimized window. |
| `move-to-tag <id>` | Send a window away. |
| `group-windows` | Bind neighbors together. |

`restore-minimized` restores one minimized window per invocation, newest first.
Use `focus-window <id>` when a shell or dock needs to restore a specific minimized
window instead.
For Mango/DMS compatibility, `minimized` aliases `minimize` and
`restore_minimized` aliases `restore-minimized`.

### Floating and stacking

Floating windows always sit above tiled ones. Focusing a tiled window gives it
the keyboard without raising it over your floating windows. Among floating
windows, the one you focused last is on top. To reach a tiled window covered by
a floating one, run `switch-focus-between-floating-and-tiling`, or move,
minimize, or scratchpad the floating window.

From bottom to top:

1. Tiled windows. A maximized window covers the other tiles, and the focused
   tile sits above the rest.
2. Floating windows, most recently focused on top.
3. The visible scratchpad.
4. A fullscreen window that has focus. It covers floating windows; once it
   loses focus it drops back to its own layer.
5. Windows a window rule marks as overlay or unmanaged global.
6. The overview highlight and the window you are dragging.

Both kinds of maximize, `toggle-maximized` (maximize to edges) and
`maximize-column` (full-width column), stay in the tiled layer. Only
fullscreen covers floating windows.

Child windows such as dialogs stay above their parent. While a dialog has
focus, its parent keeps its place, so a fullscreen app stays on top while you
answer its dialog. A dialog from another app on your workspace takes focus when
it opens. A large child window that tiles instead of floating does not take
focus from the window you are working in.

A floating window pushed partly off the screen keeps the border on its visible
edges.

## The System

| Command | Description |
|---|---|
| `spawn` | Run an app. |
| `screenshot` | Capture the screen. |
| `lock-session` | Guard your computer. |
| `exit-session` | Quit Triad. |
| `rename-tag` | Label your workspace. |

---

## The Event Stream

Listen to Triad’s life in JSON.

```bash
triad msg event-stream
```

We broadcast `WorkspaceActivated`, `WindowFocusChanged`, and window lifecycle events.

---

## Native JSON

Talk to Triad directly. Use the versioned JSON protocol over the socket.

### Request
```json
{"triad":{"version":1,"request":"state"}}
```

### Action
```json
{"triad":{"version":1,"request":"action","action":"focus-workspace","workspace_idx":2}}
```

### Subscribe
```json
{"triad":{"version":1,"request":"event-stream","events":["state","layout"]}}
```
We send a snapshot first, then push updates.

For capture indicators, subscribe to the native capture stream:

```bash
triad msg event-stream --native capture
```

Or use the bundled Waybar/custom-bar formatter:

```bash
sh tools/triad-capture-status.sh --watch --waybar
```

`capture_sessions.windows` always carries `id`, `count`, and `known`. When the
window is still known to Triad, the entry also includes app id, title,
workspace, tag, output name, and common window state flags.
On River window-management protocol v4, this payload remains present and empty,
and `capabilities.capture_sessions` is false.

Waybar custom module:

```json
{
  "custom/triad-capture": {
    "exec": "sh /path/to/triad/tools/triad-capture-status.sh --watch --waybar",
    "return-type": "json",
    "format": "{}"
  }
}
```
