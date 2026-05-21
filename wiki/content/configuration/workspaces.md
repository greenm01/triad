+++
title = "Workspaces"
weight = 30
+++

# Workspaces

Triad presents tags as workspaces. A workspace is a virtual room that holds windows. You name workspaces, pin them to monitors, and assign each its own layout.

## Defaults

Set global workspace behavior in the `workspaces` block:

```kdl
workspaces {
  default-count 5
  default-layout "scroller"
}
```

| Setting | Format | Description |
| :--- | :--- | :--- |
| `default-count` | `Int` | Minimum number of workspaces to keep open. |
| `default-layout` | `String` | Default layout ID or Janet layout name. |

## Workspace Rules

Name workspaces, assign layouts, and pin them to outputs:

```kdl
workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web" default-layout="deck"
  workspace 4 name="chat" open-on-output="DP-2"
}
```

| Setting | Format | Description |
| :--- | :--- | :--- |
| `name` | `String` | Display name for the workspace. |
| `default-layout` | `String` | Layout to use when the workspace is active. |
| `open-on-output` | `String` | Pin the workspace to a specific monitor. |

Focusing a pinned workspace moves focus to its assigned output.

## Dynamic Workspaces

Create a new workspace on the active output with `new-workspace`:

```kdl
bindings {
  bind "Super+Shift+n" "new-workspace"
}
```

If you leave a dynamic workspace without opening a window, Triad prunes it.

## Moving Workspaces

Move the active workspace to another monitor:

```kdl
bindings {
  bind "Super+Shift+Left" "move-workspace-to-output left"
  bind "Super+Shift+Right" "move-workspace-to-output right"
}
```

Targets can be directions (`left`, `right`, `up`, `down`) or output names (`DP-2`).

## Workspaces Across Monitors

Each monitor shows one active workspace. Every connected output maintains at least one visible workspace. When a monitor disconnects, its workspaces fall back to a connected monitor and return once the original monitor reconnects.

For output configuration, see [Monitors](@/configuration/monitors.md).
