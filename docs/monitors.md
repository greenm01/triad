# Monitors and Workspaces

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

Use one `output` block to describe your monitors. Each nested `monitor` target
is usually the connector name shown by tools such as `wlr-randr`.

```kdl
output {
  monitor "DP-1" {
    mode "preferred"
    position "auto-right"
    scale "auto"
  }

  monitor "DP-2" {
    mode "2560x1440@120"
    position "0x0"
    focus-at-startup
    vrr 2
    reserved_area top=8 bottom=8
  }

  monitor "DP-3" {
    mode 1920 1080 60
    position 0 180
    transform "normal"
  }

  default {
    scale "auto"
  }
}
```

`position` is in global output coordinates. It is only the monitor arrangement;
it does not mean Triad will tile windows across that whole combined rectangle.
Each output still gets its own layout area using that monitor's resolution and
usable region.

`focus-at-startup` selects the monitor Triad should focus first. If workspace 1
is not explicitly pinned elsewhere, Triad also places workspace 1 there at
startup before filling the other monitors.

Supported output fields:

| Field | Format | Purpose |
| :--- | :--- | :--- |
| `focus-at-startup` | Flag or bool | Select the startup-focused output. |
| `workspaces` | Positive integers | Pin workspace IDs to this output. |
| `mode` | `W H Hz`, `"WxH"`, `"WxH@Hz"`, `"preferred"`, `"highres"`, `"highrr"`, `"maxwidth"` | Request an advertised output mode, or a custom string mode when the compositor accepts one. |
| `scale` | Float or `"auto"` | Request output scale in the range `0.01..64.0`; `"auto"` keeps the compositor's current scale. |
| `position` | `X Y`, `"XxY"`, `"auto"`, `"auto-right"`, `"auto-left"`, `"auto-up"`, `"auto-down"`, `"auto-center-*"` | Set or auto-arrange global output coordinates. |
| `transform` | String or `0..7` | One of `normal`, `90`, `180`, `270`, `flipped`, `flipped-90`, `flipped-180`, or `flipped-270`; integers follow the same Wayland transform order. |
| `adaptive-sync` | Bool | Request VRR/Adaptive Sync when the compositor protocol supports it. |
| `vrr` | `0..3` | Hyprland-compatible alias for `adaptive-sync`; `0` disables and nonzero enables because River exposes only a bool. |
| `enabled` | Bool | Enable or disable this output through wlroots output-management. |
| `disabled` | Bool | Inverse alias for `enabled`. |
| `reserved_area` | One int, four ints, or `top/right/bottom/left` properties | Add an inset on top of live layer-shell/bar usable-area reservations. |

Use `default` inside the grouped `output` block for fallback monitor-management
fields. Fallback output rules apply to connected heads that do not match a more
specific monitor rule, but they cannot set `focus-at-startup` or `workspaces`.
Top-level `output "DP-1" { ... }` and `output "" { ... }` rules remain
supported for existing configs.

River does not currently expose Hyprland's mirror, bit depth, color-management,
ICC, or HDR/luminance monitor controls through Triad's output-management path.
Triad documents those names as future features and rejects them during strict
validation instead of accepting no-op configuration.

## Hotplug Behavior

Triad is designed to keep workspaces and windows managed when monitors are
unplugged or plugged back in. A configured monitor block can stay in your config
even when that monitor is temporarily disconnected.

When an output disappears, Triad removes that output from the live output list
and falls back to a connected output for affected workspaces. Windows remain on
their existing workspaces, and those workspaces stay occupied instead of being
discarded because the monitor went away.

When the same output name reconnects, Triad can re-apply its monitor
configuration and move remembered workspaces back to that output. For example,
if workspace 3 was visible on `DP-3`, unplugging `DP-3` may temporarily place
workspace 3 on another connected output. When `DP-3` returns, Triad can restore
workspace 3 and its windows to `DP-3`.

Useful checks while testing monitor hotplug:

```sh
wlr-randr
triad msg state
triad msg perf-status
```

`wlr-randr` shows what the compositor currently exposes. `triad msg state`
shows Triad's live outputs, workspace-to-output mapping, and window outputs.
`triad msg perf-status` confirms the daemon stayed alive and responsive.

## Pin Workspaces

You can pin workspaces from either side.

Pin specific workspaces in an output block:

```kdl
output {
  monitor "DP-2" {
    workspaces 1 2 8
  }
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

## Diagnostics

Run `triad validate-config` after editing output rules. Strict validation rejects
unknown output fields, unsupported Hyprland-style fields, malformed supported
fields, empty output targets, non-positive workspace IDs, invalid transforms,
and out-of-range scales before the daemon starts or reloads the config.

Some output problems can only be known after Triad sees the live compositor
state. These stay as runtime warnings: the output-management protocol may be
missing, a configured output target may not be connected, a requested mode may
not be advertised by the monitor, `adaptive-sync` may require a newer protocol
version, or the compositor may reject an output-management apply.

## Shell Bars

Shell integrations receive output-aware workspace snapshots. A workspace should
appear on the bar for the output where Triad currently shows or remembers it.
Workspace labels come from `workspace-rules` names:

```kdl
workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="files"
}
```

### Noctalia

Noctalia works through Triad's Niri-compatible IPC facade. Start it from a
shell profile with `niri-compat #true` so Triad provides `$NIRI_SOCKET`:

```kdl
shells {
  enabled #true
  active "noctalia"

  profile "noctalia" {
    launch "noctalia-shell"
    stop "pkill" "-f" "noctalia-shell|noctalia-qs|qs.*noctalia-shell"
    niri-compat #true
  }
}
```

Noctalia's bar needs a `Workspace` widget. These are Noctalia settings, not
Triad settings: edit them in Noctalia's settings UI under the bar/widget
configuration, or directly in `~/.config/noctalia/settings.json` under the
`bar.widgets` section for the `Workspace` widget. The `labelMode` setting
controls whether the bar shows workspace numbers, names, both, or only pills:

```jsonc
{
  "id": "Workspace",
  "labelMode": "index",
  "hideUnoccupied": false,
  "showLabelsOnlyWhenOccupied": true
}
```

Use Noctalia `labelMode: "name"` to show Triad workspace names, or
`labelMode: "index+name"` to show both. If multi-monitor workspace lists look
wrong, keep the Noctalia `followFocusedScreen` option disabled on the
`Workspace` widget so each bar uses its own screen instead of the currently
focused screen.

### DankMaterialShell

DankMaterialShell also works through the Niri-compatible shell environment:

```kdl
shells {
  enabled #true
  active "dank"

  profile "dank" {
    launch "dms" "run" "--session"
    stop "dms" "kill"
    niri-compat #true
  }
}
```

The Dank bar needs the `workspaceSwitcher` widget enabled. These are
DankMaterialShell settings, not Triad settings: edit them in DMS's settings UI,
or directly in `~/.config/DankMaterialShell/settings.json`. Workspace numbers
and names are controlled by these global DMS keys:

```jsonc
{
  "showWorkspaceSwitcher": true,
  "showWorkspaceIndex": true,
  "showWorkspaceName": false
}
```

Use `dms ipc` to update a running shell and persist the same settings to
`~/.config/DankMaterialShell/settings.json`:

```sh
dms ipc call settings set showWorkspaceIndex true
dms ipc call settings set showWorkspaceName true
```

Turn the DMS `showWorkspaceName` setting on only when you want labels from
Triad `workspace-rules`; with both DMS settings enabled, DMS shows an index
plus the workspace name.

### Waybar

Waybar works through Triad's Niri-compatible IPC facade. Start it from a shell
profile with `niri-compat #true` so Triad provides `$NIRI_SOCKET` and the
compatibility tools in that shell's private environment:

```kdl
shells {
  enabled #true
  active "waybar"

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }
}
```

Use Waybar's `niri/workspaces` module. These are Waybar settings, not Triad
settings: edit them in `~/.config/waybar/config`,
`~/.config/waybar/config.jsonc`, or whichever file your Waybar launch command
passes with `--config`. For normal multi-monitor bars, do not set a top-level
Waybar `output`; Waybar will create one bar per monitor. Keep the Waybar
`niri/workspaces.all-outputs` setting disabled so each bar filters workspaces
to the output that owns that bar:

```jsonc
{
  "modules-left": ["niri/workspaces"],

  "niri/workspaces": {
    "on-click": "activate",
    "all-outputs": false,
    "format": "{index}"
  }
}
```

Set the Waybar `all-outputs` option to `true` only when you intentionally want
every bar to show the complete workspace list from all monitors.

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

- `output { monitor "<name>" { workspaces ... } }`
- `workspace-rules { workspace N open-on-output="..." }`
- `window-rule { default-workspace ... open-on-output ... }`
- explicit `move-workspace-to-output` commands
- restored live session state

The intended rule is simple: config pins are authoritative, explicit user moves
update workspace memory, and otherwise a workspace stays on the monitor where it
was opened.
