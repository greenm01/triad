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

Run commands when River reports screencopy capture sessions starting or
stopping:

```kdl
capture-session {
  started "notify-send" "Triad" "Screen sharing started"
  stopped "notify-send" "Triad" "Screen sharing stopped"
}
```

Triad passes `TRIAD_CAPTURE_EVENT`, `TRIAD_CAPTURE_ACTIVE`,
`TRIAD_CAPTURE_WINDOW_TOTAL`, `TRIAD_CAPTURE_OUTPUT_TOTAL`,
`TRIAD_CAPTURE_TOTAL`, and `TRIAD_CAPTURE_JSON` to these commands.
`triad-capture-hook` is a ready-to-use hook helper installed by
`tools/install_live_session.sh`; from a repo checkout, run
`sh tools/triad-capture-hook.sh`.

```kdl
capture-session {
  started "triad-capture-hook"
  stopped "triad-capture-hook"
}
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

### Theme
Use `theme.accent-color` when you want one active chrome color across Triad:

```kdl
theme {
  accent-color "#7fc8ff"
}
```

The accent color fills active border, active frame-tab, active tab-line, layout
toast ring, and recent-window highlight colors when those fields are not set
directly. Specific color fields still win.

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

  monitor "HDMI-A-1" {
    mode "preferred"
    position "auto-right"
  }
}
```

#### Output mirroring limitation

Native output mirroring is blocked by stock River. River currently exposes each
physical display as a separate logical output and advertises no public protocol
request that lets Triad clone one logical desktop onto another display. The
`mirror "SOURCE"` output field is reserved for a future native implementation;
do not rely on it as a supported monitor configuration on River today.

Triad's existing screencopy presentation prototype is not native mirroring. The
target remains an independent desktop, pointer coordinates are not shared, and
River composes cursor, layer-shell, and session-lock content independently for
the two outputs. Any prototype behavior is unsupported and must not be used as
evidence that River or Triad provides output cloning.

The [native mirroring roadmap](todo.md#native-output-mirroring) records the
required River semantics, upstream issue findings, and the public protocol path
Triad can implement once an unmodified River release advertises it. Triad will
not maintain a River fork or require users to install a private River build.

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

### Cursor visibility

Set `cursor { hide-when-typing #true }` to hide Triad's cursor while typing.
With River window-management protocol v7, a physical non-modifier key hides the
cursor for that seat. With v4 through v6, Triad shortcuts trigger hiding. River
displays Triad's cursor when no application owns pointer focus. Pointer motion
restores it. `hide-after-inactive-ms` also hides the cursor after the configured
period of inactivity.

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

The `bind` directive also accepts these XF86 key names, with or without modifiers:
`XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute`,
`XF86MonBrightnessUp`, `XF86MonBrightnessDown`, `XF86Display`, and `XF86PowerOff`.

Pointer move/resize works for floating windows and for tiled windows in Triad's
built-in/native layouts. Tiled scroller windows can be dragged between columns
or into another column stack using the nearest insertion gap, including visible
scroller workspaces on other outputs. Native layouts support tiled drag targets
and split-ratio resize from window edges.

The move and resize pointer bindings also carry the expected gesture behavior:
right-click while moving toggles whether the dragged window will drop as tiled or
floating, and double-clicking a tiled resize edge triggers the resize-edge
gesture. In scroller layouts, left/right resize-edge double-click toggles a
full-width column and top/bottom double-click resets the window height; vertical
scroller transposes those directions. Binding the same pointer chord to another
command overrides that gesture.

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
