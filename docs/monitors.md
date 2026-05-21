# Monitors and Workspaces

This is a draft user guide for running Triad on more than one monitor.

Triad treats each monitor as its own output with its own visible workspace. It
does not lay out normal windows against one large desktop canvas. Output
positions still use global coordinates because that is how Wayland output
management describes monitors, but workspace placement, window layout, launcher
placement, and shell bar state are output-aware.

## Core Model

Triad uses tags internally and presents them as workspaces in shells such as
Noctalia. On a multi-monitor setup:

- each connected output shows at most one active workspace at a time;
- each workspace remembers the output where it belongs;
- focusing a workspace should show it on its remembered output;
- creating a workspace creates it on the currently active output;
- every connected output should keep at least one visible workspace;
- empty dynamic workspaces are pruned after you leave them.

Once a workspace is opened on a monitor, it should stay there unless you
explicitly move it or a config rule pins it somewhere else. If an output is
unavailable, Triad falls back to a valid connected output and restores the
workspace when the target output reconnects.

## Configure Outputs

Use `output` blocks to describe your monitors. The output name is usually the
connector name shown by tools such as `wlr-randr`.

```kdl
output "DP-1" {
  mode 1920 1080 60
  position 4480 180
}

output "DP-2" {
  mode 2560 1440 120
  position 1920 0
  focus-at-startup
}

output "DP-3" {
  mode 1920 1080 60
  position 0 180
}
```

`position` is in global output coordinates. It is only the monitor arrangement;
it does not mean Triad will tile windows across that whole combined rectangle.
Each output still gets its own layout area using that monitor's resolution and
usable region.

`focus-at-startup` selects the monitor Triad should focus first. If workspace 1
is not explicitly pinned elsewhere, Triad also places workspace 1 there at
startup before filling the other monitors.

## Pin Workspaces

You can pin workspaces from either side.

Pin specific workspaces in an output block:

```kdl
output "DP-2" {
  workspaces 1 2 8
}
```

Or pin a workspace in `workspace-rules`:

```kdl
workspace-rules {
  workspace 2 name="web" open-on-output="DP-2"
  workspace 4 name="chat" open-on-output="DP-1"
}
```

Pinned workspaces prefer their configured output whenever that output exists.
Focusing a pinned workspace moves focus to the pinned output instead of moving
the workspace to whichever monitor was active.

If you pin multiple workspaces to one output, focusing those workspaces switches
that output between them. Other outputs keep their own visible workspaces.

## Dynamic Workspaces

`new-workspace` creates an empty dynamic workspace on the currently active
output and focuses it:

```kdl
bindings {
  bind "Super+Shift+n" "new-workspace" hotkey-overlay-title="New Workspace"
}
```

This is intended for the common flow: choose a monitor, create a workspace
there, then open windows into it. If you leave that workspace without opening a
window, Triad prunes it.

Switching to an empty dynamic workspace from a monitor should keep focus on that
monitor. Triad should not create the workspace on a random output.

## Moving Workspaces Between Monitors

Use `move-workspace-to-output` when you want to explicitly move the active
workspace to another monitor:

```kdl
bindings {
  bind "Super+Shift+Left" "move-workspace-to-output left"
  bind "Super+Shift+Right" "move-workspace-to-output right"
}
```

Output targets can be directions such as `left`, `right`, `up`, and `down`, or
an output name such as `DP-2`.

Moving a workspace updates its remembered output. After that, focusing the
workspace should bring it back to the new output.

## New Windows and Launchers

New normal windows open on the workspace visible on the currently active
monitor. This includes applications launched through Triad's `spawn` command.

Layer-shell clients such as launchers and panels are handled separately by the
compositor protocol. Triad sets River's default layer-shell output to the
currently active monitor before spawning commands, so a launcher bound to a key
such as `Super+Space` should open on the monitor where focus currently is:

```kdl
bindings {
  bind "Super+Space" "spawn fuzzel"
}
```

Applications launched from that launcher should then land on the same monitor's
visible workspace unless a window rule, workspace pin, or explicit move command
places them elsewhere.

## Window Rules and Outputs

Use `window-rule open-on-output` for applications that should always open on a
specific monitor:

```kdl
window-rule {
  match app-id="org.telegram.desktop"
  open-on-output "DP-1"
  default-workspace 4
}
```

`open-on-output` can target a connector name, a stable output identity, or an
output description. When combined with `default-workspace`, Triad may make the
target output show that workspace so the window can open there without stealing
focus from unrelated monitors.

Live restore wins over opening rules. If a window is restored from a previous
session or live reload, Triad prefers the restored workspace, output, and window
state.

## Shell Bars

Shell integrations receive output-aware workspace snapshots. A workspace should
appear on the bar for the output where Triad currently shows or remembers it.

If a shell bar shows a workspace on one monitor while the actual workspace is on
another, check these first:

1. Confirm your output names and positions with `wlr-randr`.
2. Validate your config:

   ```sh
   triad validate-config
   ```

3. Check whether the workspace is pinned by an `output` block,
   `workspace-rules`, or a live move command.
4. If the issue appears after reload, inspect the retained live-restore snapshot
   and behavior log when development logging is enabled.

## Troubleshooting

If every new window lands on the same monitor, first verify which output Triad
believes is active:

```sh
triad msg state
```

Then move focus explicitly and try a launch again:

```sh
triad msg focus-output DP-2
triad msg spawn foot
```

If a layer-shell launcher opens on the wrong output, make sure you are running a
Triad build that sets the active output as River's layer-shell default before
spawned commands.

If workspaces jump between monitors, look for conflicting placement sources:

- `output "<name>" { workspaces ... }`
- `workspace-rules { workspace N open-on-output="..." }`
- `window-rule { default-workspace ... open-on-output ... }`
- explicit `move-workspace-to-output` commands
- restored live session state

The intended rule is simple: config pins are authoritative, explicit user moves
update workspace memory, and otherwise a workspace stays on the monitor where it
was opened.
