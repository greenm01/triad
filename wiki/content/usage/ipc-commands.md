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
| `move-to-tag <id>` | Send a window away. |
| `group-windows` | Bind neighbors together. |

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
