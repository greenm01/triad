+++
title = "Basics"
weight = 10
+++

# Configuring Triad

Triad uses the KDL configuration format. Edit your configuration at `$XDG_CONFIG_HOME/triad/config.kdl` (defaulting to `~/.config/triad/config.kdl`). Triad provides a default configuration on first start.

For real-world examples, see the [example configs](https://github.com/greenm01/triad/tree/master/examples/config) in the repository.

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

### Hot Reloading
Triad watches your configuration and reloads instantly when you save, including any files added via the `include` directive.

### Modular Configuration
Split your configuration into multiple files:

```kdl
include "bindings.kdl"
include optional=#true "~/.config/triad/local.kdl"
```

Paths are relative to the including file. Use `~/` for your home directory.

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

For shell and bar configuration — profiles, Waybar, Quickshell, Noctalia,
niri-compat — see [Shell Setup](@/configuration/shell-setup.md).

---

## Layout

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
| `frame-tabs` | `Block` | Colors for frame-tree tabs and empty frames. |
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

For workspace configuration — naming, pinning, dynamic creation — see [Workspaces](@/configuration/workspaces.md). For monitor output setup, see [Monitors](@/configuration/monitors.md).

---

## Window Rules

Declare how windows behave on open — floating state, placement, target workspace.
See [Window Rules](@/configuration/window-rules.md).

---

## Input

Configure keyboards (XKB layout, repeat rate), touchpads, mice, and cursor
theme. See [Input](@/configuration/input.md).

---

## Key Bindings

Bind keyboard shortcuts, mouse buttons, scroll axes, and gestures.
See [Key Bindings](@/configuration/key-bindings.md).

---

## Native Features

**Recent windows (MRU switcher).** Cycle through recently used windows with
`recent-window-next` / `recent-window-prev`. Confirm with
`recent-window-confirm` or cancel with `recent-window-cancel`.

**Hotkey overlay.** A live guide to your current bindings. Bind
`toggle-hotkey-overlay` to show it on demand.

**Scratchpads.** Hidden window pools you toggle as floating overlays.
See [Scratchpads](@/usage/scratchpads.md).

**Overview.** A zoomed-out strip of all workspaces.
See [Overview](@/usage/overview.md).

---

## Janet Scripting

Enable the embedded Janet runtime for event-driven placement and custom layouts:

```kdl
janet {
  enabled #true
  automation-dir "~/.config/triad/automation"
  layout-dir     "~/.config/triad/layouts"
}
```

See [Janet Scripting](@/usage/janet-scripting.md).

---

## Config Notifications

Run a command when the config reloads:

```kdl
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded."
  reload-failed    "notify-send" "Triad" "Config error — check the log."
}
```
