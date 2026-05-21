+++
title = "First Steps"
weight = 20
+++

# First Steps

You've logged into a River (Triad) session. Here's how to get your bearings.

## Open a Terminal

The starter config launches your terminal with `Super+Return`. If nothing
happens, `kitty` may not be installed. Edit `~/.config/triad/config.kdl` and
change the `Super+Return` binding to a terminal you have, such as `foot`,
`alacritty`, or `wezterm`.

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
tail -n 100 ~/.local/state/triad/triad-latest.log
```

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
triad msg layout-tile
triad msg layout-scroller
triad msg layout-monocle
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

The starter config launches Noctalia by default. If you'd prefer Waybar or
another shell, edit the `shells` block in your config. See
[Shell Setup](@/configuration/shell-setup.md).

## What's Next

- [Basics](@/configuration/basics.md) — config format, hot reload, startup commands
- [Window Rules](@/configuration/window-rules.md) — control where apps open
- [Key Bindings](@/configuration/key-bindings.md) — full bindings reference
- [IPC & Commands](@/usage/ipc-commands.md) — everything `triad msg` can do
