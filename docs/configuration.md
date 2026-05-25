# Configuring Triad

Triad uses the KDL configuration format. Edit your configuration at `$XDG_CONFIG_HOME/triad/config.kdl` (defaulting to `~/.config/triad/config.kdl`). Triad provides a default configuration on first start.

Practical examples are in `examples/config/`.

## Basics

### Command Line Overrides
Use the `--config` (or `-c`) flag to test a specific configuration:

```sh
triad --config /path/to/my-config.kdl
```

### Validation
Check your configuration syntax without launching the daemon:

```sh
triad validate-config
```

Validation rejects malformed includes, recursive includes, unknown top-level
configuration blocks, malformed fields inside known blocks, strict output-rule
errors, and invalid window-rule regexes.

### Hot Reloading
Triad watches your configuration and reloads instantly when you save, including any files added via the `include` directive.

### Modular Configuration
Split your configuration into multiple files:

```kdl
include "bindings.kdl"
include optional=#true "~/.config/triad/local.kdl"
```

Paths are relative to the including file. Use `~/` for your home directory.
The directive name must be spelled `include`; misspelled top-level directives
are rejected by `triad validate-config`.

---

## Naming Philosophy

Triad configuration uses clear, descriptive names:

*   **Descriptive:** `center-focused-column` instead of `cfc`.
*   **Verbose:** `split-ratio` instead of `mfact`.
*   **Positive:** `open-floating` instead of `isfloating`.
*   **Action-oriented:** Verbs for commands (e.g., `maximize-column`, `move-window-left`).
*   **Lowercase kebab-case:** Used throughout.

---

## Environment & Startup

### Environment Variables
Set variables for processes Triad starts using the `environment` block.

| Variable Name | Value | Description |
| :--- | :--- | :--- |
| `NAME` | `"Value"` | Sets a string value. |
| `NAME` | `#null` | Removes the variable. |

*Note: Use literal paths; Triad does not expand variables like `$HOME`.*

### Startup Commands
Run commands automatically at startup using `spawn-at-startup`.

```kdl
spawn-at-startup "waybar"
spawn-at-startup "nm-applet" "--indicator"
```

### Shell & Bar Profiles
Manage shells, status bars, and desktop overlays using `shells`.
Triad sets `$TRIAD_SOCKET` and Triad desktop environment variables for every
shell profile it launches. Add `niri-compat #true` when a shell also needs the
Niri-compatible IPC facade and `$NIRI_SOCKET`.

| Field | Type | Description |
| :--- | :--- | :--- |
| `active` | `String` | The default profile to start. |
| `cycle` | `List` | Profiles to rotate through via `cycle-shell`. |

**Example Profile Configuration:**
```kdl
shells {
  active "noctalia"
  cycle "noctalia" "waylee" "waybar"

  profile "noctalia" {
    launch "noctalia-shell"
    stop "pkill" "-f" "noctalia-shell"
    niri-compat #true 
  }

  profile "waylee" {
    launch "wayle"
    stop "pkill" "-x" "wayle"
    niri-compat #true
  }

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }
}
```

---

## Layout & Workspaces

### The Layout Block
Control window geometry and behavior.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `gaps` | `Pixels` | Gaps around windows (0..512). |
| `center-focused-column`| `"never"`, `"always"`, `"on-overflow"` | How to position the active scroller column. |
| `scroller-focus-center`| `Bool` | Keeps focus at screen center while scrolling. |
| `scroller-prefer-center`| `Bool` | Attempts to center columns even when not focused. |
| `scroller-proportion-presets` | `Float...` | Presets for `switch-proportion-preset` (0.05..1.0). |
| `default-column-width` | `Block` | Default width for new columns. |
| `default-window-width` | `Block` | Default width for new windows. |
| `default-window-height`| `Block` | Default height for new windows. |
| `master` | `Block` | Configure `count` and `split-ratio` (0.05..0.95). |
| `spiral` | `Block` | Configure `ratio`, `main-pane-ratio`, `main-pane`, and `clockwise`. |
| `border` | `Block` | Global `width` (0..64), `active-color`, and `inactive-color`. |
| `frame-tabs` | `Block` | Shared colors for frame-tree/notion tabs and i3 tabbed/stacking containers; also controls empty frame backgrounds. |
| `smart-gaps` | `Bool` | Remove gaps when only one window is visible. |
| `enable-animations` | `Bool` | Toggle viewport animations. |
| `animation-speed` | `0.0..1.0` | Speed of camera movement (0.0 is instant). |
| `frame-rate` | `"auto" / Int` | Targeted FPS (24..240, default: "auto"). |
| `layout-cycle` | `List` | Built-in or Janet layout IDs to rotate through. |

Native `i3` layouts support i3-style container modes. The default bindings scope i3 commands to `layout "i3"`. Use `Super+Alt+h/v` to split, and `Super+e/s/w` to select split, stacking, or tabbed modes.

**Example Layout Configuration:**
```kdl
layout {
  gaps 16
  center-focused-column "on-overflow"
  default-column-width { proportion 0.5; }
  
  border {
    width 2
    active-color "#7fc8ff"
    inactive-color "#505050"
  }

  frame-tabs {
    active-color "#3f7fd5"
    inactive-color "#161a22ee"
    active-line-color "#ffffff"
  }
}
```

### Layout Switch Toast
A native centered toast shown when switching layout modes.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `enabled` | `Bool` | Toggle the layout switch toast. |
| `timeout-ms` | `ms` | How long the toast remains visible. |
| `ring-color` | `Color` | Color of the layout indicator ring. |

**Example Toast Configuration:**
```kdl
layout-switch-toast {
  enabled #true
  timeout-ms 1500
  ring-color "#7fc8ff"
}
```

### Workspaces
Workspaces are virtual rooms. You can name them, pin them to monitors, and set default layouts.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `default-count` | `Int` | Minimum number of default workspaces to keep open. Connected monitor count can raise the effective reserved count. |
| `default-layout` | `String` | Default layout ID or Janet layout name. |

**Example Workspace Rules:**
```kdl
workspaces {
  default-count 5
  default-layout "scroller"
}

workspace-rules {
  workspace 1 name="term"
  workspace 2 name="web" default-layout="deck"
  workspace 4 name="chat" open-on-output="HDMI-A-1"
}
```

On multi-monitor sessions, connected monitors do not need explicit workspace
pins just to receive a workspace. Triad keeps at least one reserved default
workspace per connected monitor, so the effective default count is
`max(default-count, connected monitors)`. Workspace 1 goes to the
`focus-at-startup` output, or to the primary output if no startup focus is
configured; remaining reserved workspaces are assigned by monitor geometry
around that output. Explicit output `workspaces` and
`workspace-rules open-on-output` entries override that automatic distribution.

Workspace rules above `default-count` are stable configured workspaces. They
stay visible to shells and bars, are not pruned or renumbered, and dynamic
workspace allocation starts after the highest configured workspace ID.

### Output Rules
Configure monitor-specific settings.

The recommended form groups all monitor rules in one `output` section:

```kdl
output {
  layout {
    row "DP-3" "DP-2" "DP-1"
    row "HDMI-A-1" align="center"
  }

  monitor "HDMI-A-1" {
    mode "1920x1080@144"
    workspaces 1 2 3
    vrr 1
  }

  monitor "DP-1" {
    transform "90"
    scale 1.5
  }

  default {
    scale "auto"
  }
}
```

| Setting | Format | Description |
| :--- | :--- | :--- |
| `layout` | `String...` or `row String...` children | Declare physical monitor arrangement. A shorthand list is one left-to-right row; `layout { row ... }` rows stack top-to-bottom. |
| `focus-at-startup` | `Flag` | Focus this output on launch. |
| `workspaces` | `Int...` | Pin workspace IDs to this output. |
| `mode` | `W H Hz`, `"WxH"`, `"WxH@Hz"`, `"preferred"`, `"highres"`, `"highrr"`, `"maxwidth"` | Set resolution and refresh rate. |
| `scale` | `Float`, `"auto"` | Output scaling factor (0.01..64.0). |
| `position` | `X Y`, `"XxY"`, `"auto-*"` | Global coordinate position. |
| `transform` | `String`, `0..7` | Rotation (e.g., `"90"`, `"flipped"`, `"normal"`). |
| `vrr` | `0..3` | Enable VRR/Adaptive Sync (nonzero enables). |
| `reserved_area` | `Int`, `Int Int Int Int`, or properties | Add usable-area insets. |

Rows in `output.layout` accept `align="left"`, `"center"`, or `"right"`.
The matrix starts at `0x0`, skips missing monitors, and packs remaining
monitors without gaps. Monitors listed in the matrix cannot also set
`position`; unlisted monitors may still use explicit or automatic positions.

---

## Window Rules

Window rules define how windows behave based on their identity or state.

### Matching & Exclusion
Every rule begins with a `match` or `exclude` block. 

| Matcher | Type | Description |
| :--- | :--- | :--- |
| `app-id` | `Regex` | Match application ID. |
| `title` | `Regex` | Match window title. |
| `is-focused` | `Bool` | Match if focused. |
| `is-floating` | `Bool` | Match if floating. |

### Behavior & Placement

| Property | Values | Description |
| :--- | :--- | :--- |
| `open-floating` | `Bool` | Force window to open floating. |
| `open-focused` | `Bool` | Grant focus immediately on open. |
| `open-fullscreen` | `Bool` | Force fullscreen mode. |
| `open-maximized` | `Bool` | Open as a full-width column in scroller layouts. |
| `maximize-policy` | `"edge"`, `"column"`, `"ignore"` | Set behavior for the maximize command. |
| `default-workspace` | `Int` | Send window to a specific workspace. |
| `open-on-output` | `String` | Pin window to a specific monitor. |
| `open-on-all-workspaces` | `Bool` | Make window sticky across all workspaces. |
| `idle-inhibit` | `"none"`, `"focused"`, `"visible"` | Prevent screen idle/sleep. |
| `presentation-mode` | `"default"`, `"vsync"`, `"async"` | Output presentation policy. |

### Sizing & Geometry

| Property | Values | Description |
| :--- | :--- | :--- |
| `min-width` / `max-width` | `Pixels` | Size boundaries. |
| `scroller-proportion` | `0.05..1.0` | Initial width/height in scroller layouts. |
| `center-floating` | `Bool` | Center the window if floating. |

**Example Window Rules:**
```kdl
window-rule {
  match app-id="^org\.keepassxc\.KeePassXC$"
  open-floating #true
  center-floating #true
  default-workspace 2
}

window-rule {
  match app-id="^steam_app_"
  open-fullscreen #true
  idle-inhibit "visible"
}
```

---

## Interaction & Input

### Input Devices
Configure peripherals like keyboards, mice, and touchpads.

| Setting | Values | Description |
| :--- | :--- | :--- |
| `off` | `Bool` | Disable the device. |
| `repeat-rate` | `Hz` | Keys repeated per second. |
| `repeat-delay` | `ms` | Delay before key repeat starts. |
| `natural-scroll` | `Bool` | Reverse scroll direction. |
| `tap` | `Bool` | (Touchpad) Enable tap-to-click. |
| `dwt` | `Bool` | Disable while typing. |

**Example Input Configuration:**
```kdl
input {
  keyboard {
    xkb {
      layout "us"
      options "ctrl:nocaps"
    }
    repeat-rate 40
    repeat-delay 300
  }

  touchpad {
    tap #true
    natural-scroll #true
  }
}
```

### Cursor

| Setting | Format | Description |
| :--- | :--- | :--- |
| `theme` | `String` | Cursor theme name. |
| `size` | `Pixels` | Base cursor size. |
| `shake-to-find` | `Bool` | Enlarge cursor when shaken. |

---

## Bindings & Events

### Bindings
Triad supports keyboard, pointer, wheel, and gesture bindings.

*   `bind`: Keyboard commands.
*   `pointer-bind`: Mouse buttons.
*   `axis-bind`: Scroll wheel.
*   `gesture-bind`: Touchpad gestures.

Bindings can be scoped to a layout:

```kdl
bindings {
  bind "Super+Alt+h" "move-column-left"

  layout "i3" {
    bind "Super+Alt+h" "split-tree-split-horizontal"
  }
}
```

**Example Bindings:**
```kdl
bindings {
  bind "Super+Return" "spawn kitty"
  bind "Super+Space" "spawn fuzzel"
  bind "Super+q" "close-window"
  bind "Super+o" "toggle-overview"

  pointer-bind "Super+left" "move"
  pointer-bind "Super+right" "resize"
}
```

### Switch Events
Trigger commands based on hardware switch state changes, such as closing a laptop lid or toggling tablet mode.

| Event | Description |
| :--- | :--- |
| `lid-close` | Triggered when the laptop lid is closed. |
| `lid-open` | Triggered when the laptop lid is opened. |
| `tablet-mode-on` | Triggered when entering tablet mode. |
| `tablet-mode-off` | Triggered when leaving tablet mode. |

**Example Switch Configuration:**
```kdl
switch-events {
  lid-close "lock-session"
  tablet-mode-on "spawn onboard"
}
```

---

## Native Features

### Recent Windows (Switcher)
A Most Recently Used (MRU) switcher with native previews and customizable behavior.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `enabled` | `Bool` | Toggle the MRU switcher. |
| `debounce-ms` | `ms` | Time a window must remain focused before it is recorded in history. |
| `open-delay-ms` | `ms` | Delay before the switcher overlay appears after the command is triggered. |
| `highlight` | `Block` | Configure `active-color`, `urgent-color`, `padding`, and `corner-radius`. |
| `previews` | `Block` | Configure `max-height` (Pixels) and `max-scale` (0.01..1.0). |

**Example Switcher Configuration:**
```kdl
recent-windows {
  enabled #true
  debounce-ms 500
  open-delay-ms 150

  highlight {
    active-color "#7fc8ff"
    urgent-color "#ff5555"
    padding 8
    corner-radius 12
  }

  previews {
    max-height 300
    max-scale 0.8
  }
}
```

### Hotkey Overlay
A visual guide to current keybindings that can be shown on demand or at startup.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `skip-at-startup` | `Bool` | If true, do not show the overlay automatically when Triad starts. |
| `hide-not-bound` | `Bool` | Only show rows that have an active keybinding. |
| `position` | `"top"`, `"center"`, `"bottom"` | Vertical placement on the screen. |
| `columns` | `Int` | Number of columns to display (1..4). |

**Example Hotkey Overlay Configuration:**
```kdl
hotkey-overlay {
  skip-at-startup #false
  position "center"
  columns 3
}
```

### Scratchpads
Persistent, hidden window pools.

### Overview
A birds-eye view of all workspaces.

---

## System Tools

### Terminal & Screen Lock
Configure the default terminal and screen locker.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `terminal` | `Block` | The command to launch via `spawn-terminal`. |
| `screen-lock` | `Block` | The command to launch via `lock-session`. |

**Example:**
```kdl
terminal {
  command "kitty"
}

screen-lock {
  command "swaylock" "-c" "000000"
}
```

### Window Menu
Configure the command used for window menu requests.

```kdl
window-menu-command "wmenu"
```

### Screenshot
Configure native screenshot behavior and external tools.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `directory` | `String` | Where to save screenshots (supports `~/`). |
| `filename-prefix` | `String` | Prefix for generated filenames. |
| `capture-command` | `String` | Tool for full-screen capture (e.g., `grim`). |
| `region-selector-command` | `String` | Tool for region selection (e.g., `slurp`). |
| `clipboard-command` | `String` | Tool for clipboard copy (e.g., `wl-copy`). |
| `show-pointer` | `Bool` | Whether to include the mouse pointer in captures. |

**Example Screenshot Configuration:**
```kdl
screenshot {
  directory "~/Pictures/Screenshots"
  filename-prefix "triad-cap-"
  capture-command "grim"
  region-selector-command "slurp"
  clipboard-command "wl-copy"
  show-pointer #false
}
```

---

## Integration

### Shell Compatibility
Triad provides its own native shell IPC and an optional compatibility layer for
shells that consume the Niri workspace schema.

Every shell profile launched by Triad receives `$TRIAD_SOCKET` for native IPC.
When a shell profile uses `niri-compat #true`, Triad also sets `$NIRI_SOCKET`
and provides a compatible IPC facade.
This lets Noctalia, DankMaterialShell, Waylee, and Waybar's `niri/workspaces`
module run without Triad-specific patches.

### Janet Scripting
Triad embeds Janet for advanced automation. Scripts in `automation-dir` can subscribe to events and emit commands.

**Example Janet Configuration:**
```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/automation"
  layout-dir "~/.config/triad/layouts"
  layout "cascade" fallback="scroller"
}
```

### Config Notifications
Run commands to notify you of configuration reload results.

```kdl
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded"
  reload-failed "notify-send" "Triad" "Syntax error in config"
}
```
