# Configuring Triad

Triad uses the KDL format. Edit your configuration at `~/.config/triad/config.kdl`. We provide a default configuration on the first start.

Examples live in `examples/config/`.

## Basics

### Command Line Overrides
Use the `--config` (or `-c`) flag to test a configuration:

```sh
triad -c /path/to/my-config.kdl
```

### Validation
Check your syntax without launching the daemon:

```sh
triad validate-config
```

Validation catches malformed includes, unknown blocks, invalid regexes, and script errors.

### Hot Reloading
Triad watches your configuration and reloads instantly when you save.

### Modular Configuration
Split your configuration into multiple files:

```kdl
include "bindings.kdl"
include optional=#true "~/.config/triad/local.kdl"
```

## Naming
We prefer clear, descriptive names:
*   **Descriptive:** `center-focused-column` instead of `cfc`.
*   **Verbose:** `split-ratio` instead of `mfact`.
*   **Positive:** `open-floating` instead of `isfloating`.
*   **Action-oriented:** Verbs for commands (`maximize-column`, `move-window-left`).

## Environment & Startup

### Environment Variables
Set variables for processes Triad starts in the `environment` block.

| Variable Name | Value | Description |
| :--- | :--- | :--- |
| `NAME` | `"Value"` | Sets a value. |
| `NAME` | `#null` | Removes a variable. |

### Startup Commands
Run commands at startup with `spawn-at-startup`.

```kdl
spawn-at-startup "waybar"
spawn-at-startup "nm-applet" "--indicator"
```

### Shell & Bar Profiles
Manage shells and status bars in the `shells` block. Triad sets `$TRIAD_SOCKET` for every profile. Use `niri-compat #true` if a shell needs the Niri IPC facade and `$NIRI_SOCKET`.

**Example Profile:**
```kdl
shells {
  active "waybar"
  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }
}
```

## Layout & Workspaces

### The Layout Block
Control window geometry.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `gaps` | `Pixels` | Gaps around windows. |
| `center-focused-column`| `"never"`, `"always"`, `"on-overflow"` | How to position the active scroller column. |
| `scroller-focus-center`| `Bool` | Keeps focus at screen center while scrolling. |
| `border` | `Block` | Global `width`, `active-color`, and `inactive-color`. |
| `smart-gaps` | `Bool` | Remove gaps when only one window is visible. |
| `layout-cycle` | `List` | Layout IDs to rotate through. |

### Workspaces
Workspaces are virtual rooms. You can name them, pin them to monitors, and set default layouts.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `default-count` | `Int` | Minimum number of workspaces to keep open. |
| `default-layout` | `String` | Default layout ID or Janet layout name. |

**Example Rules:**
```kdl
workspaces {
  default-count 5
  default-layout "scroller"
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web" default-layout="deck"
}
```

### Output Rules
Configure monitors in the `output` section:

```kdl
output {
  layout {
    row "DP-1" "HDMI-A-1"
  }

  monitor "DP-1" {
    scale 1.5
    workspaces 1 2 3
  }
}
```

## Window Rules
Window rules define behavior based on identity or state.

### Matching
Every rule begins with a `match` or `exclude` block. 

| Matcher | Type | Description |
| :--- | :--- | :--- |
| `app-id` | `Regex` | Match application ID. |
| `title` | `Regex` | Match window title. |

### Behavior

| Property | Values | Description |
| :--- | :--- | :--- |
| `open-floating` | `Bool` | Force window to open floating. |
| `open-fullscreen` | `Bool` | Force fullscreen mode. |
| `default-workspace` | `Int` | Send window to a specific workspace. |
| `idle-inhibit` | `"none"`, `"focused"`, `"visible"` | Prevent screen idle/sleep. |

**Example Rules:**
```kdl
window-rule {
  match app-id="^org\.keepassxc\.KeePassXC$"
  open-floating #true
  center-floating #true
}
```

## Input
Configure keyboards and mice in the `input` block.

```kdl
input {
  keyboard {
    repeat-rate 40
    repeat-delay 300
  }

  touchpad {
    tap #true
    natural-scroll #true
  }
}
```

## Bindings
Triad supports keyboard, pointer, wheel, and gesture bindings.

```kdl
bindings {
  bind "Super+Return" "spawn kitty"
  bind "Super+q" "close-window"

  pointer-bind "Super+left" "move"
  pointer-bind "Super+right" "resize"
}
```

## Native Features

### Recent Windows
A Most Recently Used (MRU) switcher with previews.

```kdl
recent-windows {
  enabled #true
  debounce-ms 500
  open-delay-ms 150
}
```

### Hotkey Overlay
A visual guide to your keybindings. Use `hotkey-overlay` to configure it.

### Screenshot
Configure native screenshot behavior and external tools.

```kdl
screenshot {
  directory "~/Pictures/Screenshots"
  capture-command "grim"
  region-selector-command "slurp"
}
```

## Integration

### Shell Compatibility
Triad provides a compatibility layer for shells that use the Niri workspace schema. Set `niri-compat #true` in your shell profile to enable it.

### Janet Scripting
Embed Janet for automation. 

```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/automation"
  layout-dir "~/.config/triad/layouts"
}
```
