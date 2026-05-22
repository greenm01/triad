# Monitors and Workspaces

Triad treats each monitor as a distinct output with its own visible workspace. Windows are laid out within individual monitors rather than a single large desktop canvas.

## Core Model

Triad presents tags as workspaces. In a multi-monitor setup:

- Each monitor shows one active workspace.
- Each workspace remembers its assigned output.
- Focusing a workspace shows it on its remembered output.
- Every connected output maintains at least one assigned, visible workspace.
- Empty dynamic workspaces are pruned when you leave them.

Workspaces stay on their assigned monitors unless moved or pinned elsewhere. If a monitor is disconnected, its workspaces fall back to a connected monitor and return once the original monitor reconnects.

Triad keeps enough reserved default workspaces to cover the connected monitors,
even when `workspaces.default-count` is lower than the monitor count. The
startup-focused monitor gets workspace 1, or the primary monitor does when no
startup focus is configured. Remaining monitors are assigned by geometry around
that anchor; side monitors at the same distance prefer left before right. Extra
default workspaces cycle through that same order. You only need `workspaces` in
an output rule when you want to pin specific workspace IDs to a specific
monitor.

## Configuring Outputs

Use the `output` block to configure your monitors. Identify targets using the connector names shown by tools like `wlr-randr`.

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

For monitors not listed in `layout`, `position` defines the monitor
arrangement; it does not tile windows across combined rectangles. Each output
tiles windows within its own resolution and usable area.

For stacked or mixed physical arrangements, use a matrix layout:

```kdl
output {
  layout {
    row "DP-4" align="center"
    row "DP-3" "DP-2" "DP-1"
  }
}
```

Rows are top-to-bottom and monitors within a row are left-to-right. Missing
monitors are skipped, and remaining monitors close the gap.

### Output Settings

| Field | Format | Purpose |
| :--- | :--- | :--- |
| `layout` | `String...` or `row String...` children | Arrange listed monitors physically through output-management. |
| `focus-at-startup` | Flag or bool | Select the startup-focused output. |
| `workspaces` | Positive integers | Pin workspace IDs to this output. |
| `mode` | `W H Hz`, `"WxH"`, `"WxH@Hz"`, `"preferred"`, `"highres"`, `"highrr"`, `"maxwidth"` | Request an advertised mode or a custom string mode. |
| `scale` | Float or `"auto"` | Set the output scale (0.01..64.0). `"auto"` uses the compositor's current scale. |
| `position` | `X Y`, `"XxY"`, `"auto"`, `"auto-right"`, `"auto-left"`, `"auto-up"`, `"auto-down"`, `"auto-center-*"` | Set or auto-arrange global output coordinates. |
| `transform` | String or `0..7` | Rotation: `normal`, `90`, `180`, `270`, or `flipped` variants (e.g., `flipped-90`). Integers follow Wayland transform order. |
| `adaptive-sync` | Bool | Request VRR/Adaptive Sync. |
| `vrr` | `0..3` | alias for `adaptive-sync`. `0` disables; nonzero enables. |
| `enabled` / `disabled` | Bool | Enable or disable the output. |
| `reserved_area` | Ints or properties | Add a top/right/bottom/left inset on top of bar reservations. |

Use `default` for fallback rules. Fallback rules apply to connected monitors that do not match a specific rule.

**Note on Validation:** Triad strictly validates output fields. Unsupported properties (such as mirroring, bit depth, or HDR) are rejected to prevent configuration errors.

## Hotplugging

Triad keeps workspaces and windows managed when monitors are connected or disconnected. When a monitor disappears, its workspaces move to a connected monitor. When the monitor returns, Triad restores the original workspaces.

Verify your setup with:

```sh
wlr-randr
triad msg state
```

## Pinning Workspaces

Pin workspaces in an `output` block:

```kdl
output {
  monitor "DP-2" {
    workspaces 1 2 8
  }
}
```

Or via `workspace-rules`:

```kdl
workspace-rules {
  workspace 2 name="web" open-on-output="DP-2"
}
```

Focusing a pinned workspace moves focus to its assigned output.

Pins override the automatic default workspace distribution. Unpinned default
workspaces still fill any connected monitors that do not have a pinned
workspace.

Workspace rules above `workspaces.default-count` are stable configured
workspaces. They stay materialized and visible in shell workspace projections,
and dynamic workspace allocation starts after the highest configured workspace
ID.

## Dynamic Workspaces

`new-workspace` reuses the lowest inactive empty dynamic workspace on the active
output. If none is available, it creates the next dynamic workspace after the
reserved and configured workspace range on that output:

```kdl
bindings {
  bind "Super+Shift+n" "new-workspace"
}
```

If you leave a transient dynamic workspace without opening a window, Triad prunes
it.

## Moving Workspaces

Use `move-workspace-to-output` to move the active workspace to another monitor:

```kdl
bindings {
  bind "Super+Shift+Left" "move-workspace-to-output left"
  bind "Super+Shift+Right" "move-workspace-to-output right"
}
```

Targets can be directions (`left`, `right`, `up`, `down`) or output names (`DP-2`).

## Windows and Launchers

New windows open on the active monitor's workspace. Triad sets the default layer-shell output to the active monitor, ensuring launchers like Waybar or Quickshell appear where focus is.
