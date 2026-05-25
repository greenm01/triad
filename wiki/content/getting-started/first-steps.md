+++
title = "First Steps"
weight = 20
+++

# First Steps

If you haven't tested Triad yet, the quickest way is a nested Wayland session
from your current desktop — no TTY switch needed:

```bash
WLR_BACKENDS=wayland ~/.local/bin/triad session
```

Open a second terminal to tail the log while you explore:

```bash
triad logs
tail -f ~/.local/state/triad/triad-session-latest.log
```

Once you're comfortable, log out and select **River (Triad)** from your display
manager for a full session.

---

## Open a Terminal

The starter config has the terminal bind commented out. Before your first
session, open `~/.config/triad/config.kdl`, find the `Super+Return` bind, and
uncomment it with a terminal you have installed:

```kdl
bind "Super+Return" "spawn foot"  // or kitty, alacritty, wezterm, …
```

Also update the `terminal { command "…" }` block to match — that's used by the
terminal scratchpad (`Super+Ctrl+e`).

## Validate Your Config

Check that Triad parsed your config cleanly:

```bash
triad validate-config
```

If you made edits and want to check a specific file without restarting:

```bash
triad validate-config --config ~/.config/triad/config.kdl
```

## Confirm IPC Is Working

Inside a running session:

```bash
triad msg state
triad msg workspaces
```

Both should return JSON. If they hang or fail, Triad isn't running or the
socket path is wrong. Check the session log:

```bash
ls -la ~/.local/state/triad/
triad logs
tail -n 100 ~/.local/state/triad/triad-session-latest.log
```

For live-session checks without a reload, `triad doctor-live` is the native
command. Prefer `nimble doctorLive`; it builds the current CLI first.

## Set Your First Bindings

Open `~/.config/triad/config.kdl` in your editor. The `bindings` block is
where you define keyboard shortcuts:

```kdl
bindings {
  bind "Super+Return"  "spawn kitty"
  bind "Super+Space"   "spawn fuzzel"
  bind "Super+q"       "close-window"
  bind "Super+o"       "toggle-overview"
  bind "Super+n"       "switch-layout"
  bind "Super+h"       "focus-left"
  bind "Super+l"       "focus-right"
  bind "Super+j"       "focus-down"
  bind "Super+k"       "focus-up"
}
```

Save the file. Triad reloads it immediately — no restart needed.

For the full bindings reference, see [Key Bindings](@/configuration/key-bindings.md).

## Pick a Layout

Each workspace picks its own layout. Switch the active one:

```bash
triad msg tile
triad msg scroller
triad msg monocle
```

Or cycle through a configured list with a binding:

```kdl
layout {
  layout-cycle "scroller" "tile" "monocle"
}
bindings {
  bind "Super+n" "switch-layout"
}
```

See the full [layout reference](@/configuration/layouts.md).

## Set Up a Shell or Bar

Shell integration is disabled in the starter config. To add a status bar,
enable it and configure a profile in the `shells` block. See
[Shell Setup](@/configuration/shell-setup.md).

## What's Next

- [Basics](@/configuration/basics.md) — config format, hot reload, startup commands
- [Window Rules](@/configuration/window-rules.md) — control where apps open
- [Key Bindings](@/configuration/key-bindings.md) — full bindings reference
- [IPC & Commands](@/usage/ipc-commands.md) — everything `triad msg` can do
