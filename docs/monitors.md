# Monitors: The Output Map

Triad treats every monitor as its own world. Windows live in their output. We don't believe in one giant canvas.

## The Model

Each monitor shows one workspace. That workspace remembers where it belongs. Focus a workspace, and Triad takes you to its assigned monitor. Every connected screen must show something. If you leave an empty workspace, we prune it.

Workspaces stay put. Unplug a monitor, and its windows move to a connected screen. Plug it back in, and they return home.

Triad always finds a place for your workspaces. Even if you don't configure enough, we’ll spread them across your screens. We start at workspace 1 on your primary monitor and fill the rest. We prefer left over right.

## Configure Your Outputs

Use the `output` block to map your world. Find your connector names with `wlr-randr`.

```kdl
output {
  layout "DP-3" "DP-2" "DP-1"

  monitor "DP-1" {
    mode "preferred"
    scale "auto"
  }

  monitor "DP-2" {
    mode "2560x1440@120"
    focus-at-startup
    vrr 2
    reserved_area top=8 bottom=8
  }

  default {
    scale "auto"
  }
}
```

Layout defines your physical space. It doesn't stretch windows across screens. Every output tiles its own windows.

For complex stacks, use a matrix:

```kdl
output {
  layout {
    row "DP-4" align="center"
    row "DP-3" "DP-2" "DP-1"
  }
}
```

Rows go top-to-bottom. Monitors in a row go left-to-right. We skip the gaps.

### The Rules

You have power over your pixels. Set the `mode` for resolution and refresh rate. Use `scale` for clarity. `position` handles global coordinates. `transform` rotates the view. `adaptive-sync` (or `vrr`) kills the tear.

Use `default` for the strangers. Any monitor we don't recognize gets these rules.

We validate everything. If a property isn't supported, we reject it. We don't guess.

## Hotplugging

Connect or disconnect at will. Triad manages the chaos. Windows move when screens die and return when they live again.

Check your work:
```sh
wlr-randr
triad msg state
```

## Pinning

Force a workspace to stay on a monitor.

```kdl
output {
  monitor "DP-2" {
    workspaces 1 2 8
  }
}
```

Or use rules:

```kdl
workspace-rules {
  workspace 2 name="web" open-on-output="DP-2"
}
```

Focusing a pinned workspace moves your eyes to that monitor. Pins override our automatic distribution.

## Dynamic Workspaces

`new-workspace` is efficient. It reuses the first empty workspace it finds. If none exist, it creates a fresh one. Leave it empty, and we kill it.

## Movement

Move your active workspace with `move-workspace-to-output`. Use directions or names.

```kdl
bindings {
  bind "Super+Shift+Left" "move-workspace-to-output left"
  bind "Super+Shift+Right" "move-workspace-to-output right"
}
```

Moving a workspace isn't a swap. If a monitor is left empty, we give it a new workspace immediately.

## Launching

New windows open where you are. Launchers and bars appear on the active monitor. Focus is the anchor.
