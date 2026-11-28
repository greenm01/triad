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
  enabled #true
  active "noctalia"
  cycle  "noctalia" "wayle" "waybar"

  watchdog {
    enabled  #true
    fallback "waybar"
  }

  profile "noctalia" {
    launch "noctalia"
    stop   "pkill" "-x" "noctalia"
    niri-compat #true
  }

  profile "waybar" {
    launch "waybar"
    stop   "pkill" "-x" "waybar"
  }

  profile "wayle" {
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
| `enabled` | Bool | Enable managed shell profiles. |
| `active` | String | Profile to launch at startup. |
| `cycle` | List | Profiles to rotate through with `cycle-shell`. |
| `watchdog.enabled` | Bool | Recover the active shell when its tracked process exits. |
| `watchdog.fallback` | String | Profile to select when the active shell exits or holds exclusive focus past the watchdog timeout. |

Each profile takes:

| Setting | Type | Description |
|---|---|---|
| `launch` | String argv | Command to start the shell. |
| `stop` | String argv | Command to stop it cleanly. |
| `niri-compat` | Bool | Set `$NIRI_SOCKET` for clients that use Niri-compatible IPC. |

## Standard Wayland Workspaces

Stock Noctalia 5.6 and Waybar's `ext/workspaces` module use
`ext-workspace-v1` to list workspaces and switch between them. On River builds
that lack the protocol, Triad automatically starts `triad-wayland-proxy` for
managed shells when the helper is installed. When River advertises the protocol
itself, managed shells use River directly. Set `TRIAD_WORKSPACE_PROXY=0` in
Triad's environment to opt out of the helper.

The bridge also supports creating workspaces, moving them between outputs,
and deactivating them. Clients can remove empty, inactive dynamic workspaces.
Each client decides which actions to expose. Noctalia 5.6 uses the bridge for
workspace display and switching. See the
[bridge documentation](https://github.com/greenm01/triad/blob/master/docs/ext-workspace-v1.md)
for installation, available actions, and how to run other clients through it.

## Supported Shells

### Waybar

Use a Waybar build that includes `ext/workspaces`. Add the module to your
Waybar config to show workspace names on each monitor and switch by clicking:

```json
{
  "modules-left": ["ext/workspaces"],
  "ext/workspaces": {
    "on-click": "activate",
    "all-outputs": false,
    "format": "{name}",
    "sort-by-name": false,
    "sort-by-coordinates": true
  }
}
```

For Waybar's `niri/workspaces` module or other Niri modules, set
`niri-compat #true` in the Waybar profile.

### Noctalia

For stock Noctalia 5.6, use the `noctalia` profile above. Niri-compatible IPC
supplies additional window and application metadata to Noctalia. The
Triad-native Noctalia fork can read that metadata directly from Triad.

Set label preferences in a TOML file under `~/.config/noctalia/`:

```toml
[widget.workspaces]
show_labels = true
label_source = "id"
```

Use `label_source = "name"` for workspace names. See
[Noctalia's workspace widget documentation](https://docs.noctalia.dev/noctalia/v5.6.0/bar/widgets/workspaces/)
for the other settings.

### DankMaterialShell and Wayle

Set `niri-compat #true` in these profiles. Triad exposes the Niri workspace,
window, output, overview, and keyboard layout events through `$NIRI_SOCKET`.

## Workspace Names in Your Bar

Name workspaces in `workspace-rules`. These names are available to shell
clients over the workspace protocol and through IPC.

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

Pin workspaces to specific monitors in `workspace-rules` or the `output` block:

```kdl
workspace-rules {
  workspace 4 name="chat"  open-on-output="DP-2"
  workspace 5 name="media" open-on-output="DP-2"
}
```

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
