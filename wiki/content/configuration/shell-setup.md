+++
title = "Shell Setup"
weight = 55
+++

# Shell Setup

Triad manages status bars and desktop shells through shell profiles. A profile
defines how to launch and stop a shell, and whether it needs Niri-compatible
IPC. Triad starts the active profile on launch and can cycle between profiles
at runtime.

## The `shells` Block

```kdl
shells {
  active "noctalia"
  cycle  "noctalia" "waylee" "waybar"

  watchdog {
    enabled  #true
    fallback "waybar"
  }

  profile "noctalia" {
    launch "noctalia-shell"
    stop   "pkill" "-f" "noctalia-shell"
    niri-compat #true
  }

  profile "waybar" {
    launch "waybar"
    stop   "pkill" "-x" "waybar"
    niri-compat #true
  }

  profile "waylee" {
    launch "wayle"
    stop   "pkill" "-x" "wayle"
    niri-compat #true
  }

  profile "dank" {
    launch "dankmaterialshell"
    stop   "pkill" "-f" "dankmaterialshell"
    niri-compat #true
  }
}
```

| Setting | Type | Description |
|---|---|---|
| `active` | String | Profile to launch at startup. |
| `cycle` | List | Profiles to rotate through with `cycle-shell`. |
| `watchdog.enabled` | Bool | Restart the shell if it crashes. |
| `watchdog.fallback` | String | Profile to use if the active shell fails repeatedly. |

Each profile takes:

| Setting | Type | Description |
|---|---|---|
| `launch` | String argv | Command to start the shell. |
| `stop` | String argv | Command to stop it cleanly. |
| `niri-compat` | Bool | Set `$NIRI_SOCKET` and expose the compatibility IPC facade used by Noctalia, DankMaterialShell, Waylee, and Waybar's `niri/workspaces` module. |

## Supported Shells

### Waybar

Waybar reads standard Wayland protocols for most modules. Its
`niri/workspaces` module uses Triad's compatibility IPC facade, so add
`niri-compat #true` when you want Waybar workspace buttons.

```kdl
profile "waybar" {
  launch "waybar"
  stop   "pkill" "-x" "waybar"
  niri-compat #true
}
```

### Noctalia, DankMaterialShell, and Waylee

These shells consume the compatibility IPC schema. Set `niri-compat #true` in
their profiles. Triad sets `$NIRI_SOCKET` to a compatibility socket and
translates events from its native snapshot.

```kdl
profile "noctalia" {
  launch "noctalia-shell"
  stop   "pkill" "-f" "noctalia-shell"
  niri-compat #true
}
```

Waylee uses the same compatibility path:

```kdl
profile "waylee" {
  launch "wayle"
  stop   "pkill" "-x" "wayle"
  niri-compat #true
}
```

## Workspace Names in Your Bar

Workspace names you set in `workspace-rules` flow through IPC to your shell
automatically. Name your workspaces once in your Triad config and they appear
in every bar without any further coordination:

```kdl
workspaces {
  default-count 3
  default-layout "scroller"
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web"
  workspace 3 name="files"
  workspace 4 name="chat"  default-layout="deck"
  workspace 5 name="media" default-layout="monocle"
  workspace 6 name="code"  default-layout="center-tile"
}
```

### Waybar

Add `niri-compat #true` to the Waybar profile. Triad then sets `$NIRI_SOCKET`
and Waybar's `niri/workspaces` module reads from it.

```kdl
profile "waybar" {
  launch "waybar"
  stop   "pkill" "-x" "waybar"
  niri-compat #true
}
```

In your Waybar JSON config, set `"all-outputs": false` so each bar instance
shows only the workspaces belonging to its own monitor — essential for
multi-monitor setups:

```json
"modules-left": ["niri/workspaces"],

"niri/workspaces": {
  "on-click": "activate",
  "all-outputs": false,
  "format": "{index}",
  "format-icons": {
    "active":  "󱓻",
    "urgent":  "󱓻",
    "default": "",
    "1": "1", "2": "2", "3": "3",
    "4": "4", "5": "5", "6": "6",
    "7": "7", "8": "8", "9": "9"
  }
}
```

With `"all-outputs": false`, the workspace bar on each monitor shows only
the workspaces assigned to that output. Pin workspaces to specific monitors
in `workspace-rules` or the `output` block:

```kdl
workspace-rules {
  workspace 4 name="chat"  open-on-output="DP-2"
  workspace 5 name="media" open-on-output="DP-2"
}
```

### Noctalia

Noctalia receives workspace state directly via the event stream — names and
active state update automatically. In Noctalia's `settings.json`, the
`Workspace` widget in your bar config controls display:

```json
{
  "id": "Workspace",
  "labelMode": "index",
  "hideUnoccupied": false,
  "showLabelsOnlyWhenOccupied": true,
  "enableScrollWheel": true
}
```

Set `"labelMode": "name"` to show workspace names instead of numbers. Noctalia
will use the names from your `workspace-rules` directly.

### DankMaterialShell

DankMaterialShell also uses `niri-compat #true` and reads workspace state from
the same Niri-compatible event stream. No additional configuration is needed
beyond the profile entry.

### Waylee

Waylee also uses `niri-compat #true`. It reads workspaces, windows, outputs,
overview state, and keyboard layout events through the same `$NIRI_SOCKET`
facade.

### Exporting Sockets to the Session

Some launchers and systemd-activated services won't see `$NIRI_SOCKET` or
`$TRIAD_SOCKET` unless they're exported to the D-Bus activation environment.
Add this to your Triad config to handle it at startup:

```kdl
spawn-at-startup "sh" "-lc" \
  "dbus-update-activation-environment --systemd \
   WAYLAND_DISPLAY XDG_CURRENT_DESKTOP NIRI_SOCKET TRIAD_SOCKET"
```

## Shell Management Commands

Manage your shell profiles and UI focus at runtime:

| Command | Description |
|---|---|
| `switch-shell <name>` | Switch the active shell profile by name. |
| `cycle-shell` | Cycle through the profiles in `shells.cycle`. |
| `focus-shell-ui` | Shift focus to the shell UI surface. |

**Example Bindings:**

```kdl
bindings {
  bind "Ctrl+Alt+0" "cycle-shell"
  bind "Ctrl+Alt+9" "switch-shell 'noctalia'"
  bind "Super+Alt+u" "focus-shell-ui"
}
```

## Notifications

Get notified when the config reloads:

```kdl
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded."
  reload-failed    "notify-send" "Triad" "Config error — check the log."
}
```
