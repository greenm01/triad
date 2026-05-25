# Triad: The Wire

Triad talks to the world through a Unix Domain Socket. Look for it at `$XDG_RUNTIME_DIR/triad.sock`. If that fails, check `/tmp/triad.sock`.

## The Messenger

Use the CLI to bark orders:
`triad msg <command> [arguments]`

### The Basics

Ask Triad about its world. `commands` lists your options. `state` dumps everything. If you want specific pieces, use `workspaces`, `outputs`, or `windows`. 

`capabilities` tells you what Triad can do. It tracks window management, overview modes, and power flags. `perf-status` and `mem-status` show the daemon's guts. Diagnostics. Loop times. Memory usage. It’s all there.

Manage your environment. `config-reload` refreshes your settings. `triad-reload` snaps a restore point and restarts the manager. `switch-keyboard-layout` swaps your keys. `power-off-monitors` kills the screens; `power-on-monitors` brings them back.

### Navigation

Move through your windows. `focus-next` and `focus-prev` are your bread and butter. Use `focus-left/right/up/down` for spatial moves. `focus-last` takes you back.

Workspaces follow suit. `focus-workspace <index>` or `focus-tag <id>` jumps you across the tag-scape. `new-workspace` grabs an empty tag or creates a fresh one. `toggle-overview` gives you the bird’s-eye view.

History matters. `recent-window-next` and `recent-window-prev` navigate the switcher. Confirm with `recent-window-confirm`. Close the selected window with `recent-window-close-current`.

Scratchpads hide your mess. `toggle-scratchpad` handles the default pool. `toggle-named-scratchpad <name>` manages the rest.

### Layout

Set the mood for your workspace. Triad knows many shapes: `scroller`, `grid`, `notion`, `dwindle`, `i3`, and `spiral`. 

`switch-layout` cycles your favorites. `set-layout-for-workspace` forces a layout on a specific tag.

#### The Masters
Command the master-stack. `master-count` sets the limit. `master-ratio` carves the screen. 

#### Notion (The Frame Tree)
Split your frames. `frame-split-horizontal` and `frame-split-vertical` divide the space. `frame-unsplit` kills the empty. Bind apps to frames with `frame-bind-app`.

#### BSP and Dwindle
Balance the tree with `bsp-balance`. Preselect your next move with `bsp-preselect-left/right/up/down`. Dwindle handles manual splits.

#### i3 (The Split Tree)
Traditional tiling. Set your direction with `split-tree-split-horizontal`. Toggle with `split-tree-layout-toggle-split`. Move up the tree with `split-tree-focus-parent`.

### Window Mastery

Control the clients. `close-window` asks politely. `toggle-floating` breaks the grid. `fullscreen-window` takes it all.

Move them. `move-to-tag` or `move-to-workspace` shifts the window and your focus. Send them to the `scratchpad` when they’re in the way.

Group them. `group-windows` binds them to their neighbor. `ungroup-window` sets them free.

### The System

Run things. `spawn` starts your apps. `spawn-terminal` hits your favorite shell. `lock-session` guards the screen. `exit-session` quits (if you let it).

Interact. `screenshot` captures the moment. `warp-pointer` moves the cursor across every seat. `rename-tag` changes the label on your active workspace.

---

## The Stream

Triad broadcasts its life. State changes, focus shifts, windows opening—it’s all on the wire.

Listen in:
`triad msg event-stream`

We also talk the Waybar dialect. Noctalia and Waylee understand it.

---

## Native JSON

The native protocol is JSON over the Triad socket. It’s tag-first. It’s fast.

### The Request
```json
{"triad":{"version":1,"request":"state"}}
```

### The Reply
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

### Direct Action
Bark orders in JSON:
```json
{"triad":{"version":1,"request":"action","action":"focus-workspace","workspace_idx":2}}
```

### Stay Informed
Subscribe to the pulse:
```json
{"triad":{"version":1,"request":"event-stream","events":["state", "layout", "window"]}}
```
We send the initial state, then push updates. The `window` stream is lean. It only sends what changed. If a socket dies, we drop the subscriber. No stale ghosts.

A note on urgency: We have the field. We don't use it yet. Don't rely on it.
