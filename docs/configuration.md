# Configuring Triad

Triad uses the KDL configuration format, which is both readable and expressive. You can find your configuration at `$XDG_CONFIG_HOME/triad/config.kdl` (or `~/.config/triad/config.kdl` if the environment variable is unset). If you haven't created one yet, Triad will provide a sensible default when it first starts.

See `examples/config/` for practical examples.

## The Basics

### Command Line Overrides
If you need to test a specific configuration or keep multiple setups, use the `--config` (or `-c`) flag:

```sh
triad --config /path/to/my-config.kdl
```

### Validation
Before applying changes, you can ensure your configuration is syntactically sound without launching the daemon:

```sh
triad validate-config
```

### Hot Reloading
Triad is alive. It watches your configuration files and reloads them instantly whenever you save. This includes any files you've pulled in via the `include` directive.

### Modular Configuration
Keep your configuration tidy by splitting it into multiple files:

```kdl
include "bindings.kdl"
include optional=#true "~/.config/triad/local.kdl"
```

Paths are relative to the file containing the `include`. Use `~/` to refer to your home directory.

---

## Naming Philosophy

Triad’s configuration should read like a set of clear instructions, not a technical manual. We follow a few simple rules to keep things human:

*   **Be Descriptive:** Use `center-focused-column` instead of `cfc`.
*   **Be Verbose:** Prefer `split-ratio` over `mfact`.
*   **Be Positive:** Use `open-floating` instead of `isfloating`.
*   **Use Actions:** Use verbs for commands, like `maximize-column` or `move-window-left`.
*   **Consistency:** Everything is lowercase kebab-case.

---

## Environment & Startup

### Environment Variables
Use the `environment` block to set variables for any process Triad starts (terminals, launchers, etc.).

| Variable Name | Value | Description |
| :--- | :--- | :--- |
| `NAME` | `"Value"` | Sets a literal string value. |
| `NAME` | `#null` | Removes the variable from the environment. |

*Note: Triad does not expand variables like `$HOME` or `~` here; use literal paths.*

### Startup Commands
You can run commands automatically when Triad starts using `spawn-at-startup`.

```kdl
spawn-at-startup "waybar"
spawn-at-startup "nm-applet" "--indicator"
```

### Shell & Bar Profiles
Manage your shell, status bar, or desktop overlays using `shells`. This allows you to switch between different desktop environments (profiles) on the fly.

| Field | Type | Description |
| :--- | :--- | :--- |
| `active` | `String` | The name of the profile to start by default. |
| `cycle` | `List` | Profiles to rotate through when using `cycle-shell`. |
| `watchdog` | `Block` | Settings for monitoring shell health. |

**Example Profile Configuration:**
```kdl
shells {
  active "noctalia"
  cycle "noctalia" "waybar"

  profile "noctalia" {
    launch "noctalia-shell"
    stop "pkill" "-f" "noctalia-shell"
    niri-compat #true 
  }

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
  }
}
```

---

## Layout & Workspaces

### The Layout Block
Control the geometry and behavior of your windows.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `gaps` | `Pixels` | Gaps around windows (0..512). In native `frame-tree` layouts this is the split gap between frames; the frame tree fills the output usable rect with no extra outer margin. |
| `center-focused-column`| `"never"`, `"always"`, `"on-overflow"` | How to position the active scroller column. |
| `scroller-focus-center`| `Bool` | Keeps the focus at the screen center while scrolling. |
| `scroller-prefer-center`| `Bool` | Attempts to center columns even when not focused. |
| `scroller-proportion-presets` | `Float...` | Presets for `switch-proportion-preset` (0.05..1.0). |
| `default-column-width` | `Block` | Default width for new columns. |
| `default-window-width` | `Block` | Default width for new windows. |
| `default-window-height`| `Block` | Default height for new windows. |
| `master` | `Block` | Configure `count` and `split-ratio` (0.05..0.95). |
| `border` | `Block` | Global `width` (0..64), `active-color`, and `inactive-color`. |
| `frame-tabs` | `Block` | Native frame-tree tab colors: `active-color`, `active-unfocused-color`, `inactive-color`, `active-line-color`, and `active-unfocused-line-color`. |
| `smart-gaps` | `Bool` | Remove gaps when only one window is visible. |
| `enable-animations` | `Bool` | Toggles viewport animations. |
| `animation-speed` | `0.0..1.0` | Speed of camera movement (0.0 is instant). |
| `animation-snap-threshold` | `0.01..64.0` | Pixel distance to snap camera to target. |
| `frame-rate` | `"auto" / Int` | Targeted FPS (24..240, default: "auto"). |
| `layout-cycle` | `List` | Built-in layout ids and declared Janet layout names to rotate through. |

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
    active-unfocused-color "#303846"
    inactive-color "#161a22ee"
    active-line-color "#ffffff"
    active-unfocused-line-color "#62a8ff"
  }
  
  master {
    count 1
    split-ratio 0.6
  }
}
```

### Workspaces
Workspaces are your virtual rooms. You can name them, pin them to specific monitors, and set their default layouts.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `default-count` | `Int` | The minimum number of workspaces to keep open. |
| `default-layout` | `String` | Built-in layout id or declared Janet layout name. |

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

### Output Rules
Configure monitor-specific settings.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `focus-at-startup` | `Flag` | Focus this output on Triad launch. |
| `workspaces` | `Int...` | Pin these workspace IDs to this output. |
| `mode` | `W H Hz` | Set resolution and refresh rate (e.g., `1920 1080 60`). |
| `scale` | `Float` | Output scaling factor (0.01..64.0). |
| `position` | `X Y` | Global coordinate position. |
| `transform` | `String` | Rotation (e.g., `"90"`, `"flipped"`, `"normal"`). |
| `adaptive-sync` | `Bool` | Toggle VRR/Adaptive Sync. |

**Example Output Configuration:**
```kdl
output "HDMI-A-1" {
  mode 1920 1080 144
  position 0 0
  workspaces 1 2 3
  adaptive-sync #true
}

output "DP-1" {
  transform "90"
  position 1920 0
  scale 1.5
}
```

---

## Window Rules

Window rules are the heart of Triad's automation. They allow you to define exactly how windows behave based on their identity or state.

### Matching & Exclusion
Every rule begins with a `match` or `exclude` block. 

| Matcher | Type | Description |
| :--- | :--- | :--- |
| `app-id` | `Regex` | Match based on application ID. |
| `title` | `Regex` | Match based on window title. |
| `is-focused` | `Bool` | Match if the window is currently focused. |
| `is-active` | `Bool` | Match if the window is the active one in its workspace. |
| `is-active-in-column` | `Bool` | Match if it's the active window in its column. |
| `is-floating` | `Bool` | Match based on floating state. |
| `at-startup` | `Bool` | Match if the window opens during Triad's initial startup. |

### Behavior & Placement

| Property | Values | Description |
| :--- | :--- | :--- |
| `open-floating` | `Bool` | Force window to open floating. |
| `open-focused` | `Bool` | Whether to grant focus immediately on open. |
| `open-fullscreen` | `Bool` | Force window into fullscreen mode. |
| `open-maximized` | `Bool` | Open as a full-width column in scroller layouts. |
| `open-maximized-to-edges` | `Bool` | Open in the edge-maximized state. |
| `maximize-policy` | `"edge"`, `"column"`, `"ignore"` | Sets behavior when the maximize command is issued. |
| `default-workspace` | `Int" | Send the window to a specific workspace. |
| `default-workspaces` | `Int...` | Assign window to multiple workspaces. |
| `open-on-output` | `String` | Pin the window to a specific monitor name. |
| `open-named-scratchpad`| `String` | Open hidden in a specific scratchpad pool. |
| `open-on-all-workspaces` | `Bool` | Make the window sticky across all workspaces. |
| `open-overlay` | `Bool` | Keep window above normal windows without floating. |
| `open-unmanaged-global`| `Bool` | Open as a global, layout-independent float. |
| `parented-role` | `"dialog"`, `"tool"`, `"plain"` | How child windows interact with parents. |
| `dialog-viewport-jump` | `Bool` | Allow dialogs to snap the viewport immediately. |

### Sizing & Geometry

| Property | Values | Description |
| :--- | :--- | :--- |
| `min-width` / `max-width` | `Pixels` | Effective size boundaries (0..65535). |
| `min-height` / `max-height`| `Pixels` | Effective size boundaries (0..65535). |
| `default-column-width` | `Block` | Initial width proportion for new columns. |
| `scroller-proportion` | `0.05..1.0` | Initial width/height in scroller layouts. |
| `scroller-single-proportion` | `0.05..1.0` | Size when the window is the only one in the scroller. |
| `default-window-width` | `Block` | Initial stored width proportion. |
| `default-window-height`| `Block` | Initial stored height proportion. |
| `respect-size-hints` | `Bool` | Whether to honor the application's requested size. |
| `center-floating` | `Bool` | Center the window on the active screen if floating. |
| `default-floating-position` | `Block` | Set `x`, `y`, and `relative-to` (anchor). |
| `floating` | `Block` | Set custom `x-ratio`, `y-ratio`, `width`, `height`, etc. |

### Advanced State & Integration

| Property | Values | Description |
| :--- | :--- | :--- |
| `terminal` | `Bool` | Mark as a terminal host for swallowing. |
| `allow-swallow` | `Bool` | Whether child windows can be swallowed by this host. |
| `keyboard-shortcuts-inhibit` | `Bool` | Whether to inhibit global shortcuts while focused. |
| `idle-inhibit` | `"none"`, `"focused"`, `"visible"` | Prevent screen idle/sleep. |
| `presentation-mode` | `"default"`, `"vsync"`, `"async"` | Output presentation policy. |
| `tiled-state` | `Bool` | Override the client-visible tiled hint. |
| `forced-layout` | `String` | Force a specific layout for the workspace. |

### Appearance & Rendering

| Property | Values | Description |
| :--- | :--- | :--- |
| `border` | `Block` | Custom `width`, `active-color`, and `inactive-color`. |
| `focus-ring` | `Block` | Custom `width` and `active-color` for focused windows. |
| `clip-to-geometry` | `Bool` | Force visual clipping to the window's layout box. |

**Example Window Rules:**
```kdl
window-rule {
  match app-id="^org\.keepassxc\.KeePassXC$"
  open-floating #true
  center-floating #true
  default-workspace 2
}

window-rule {
  match app-id="^firefox$"
  exclude title="^Picture-in-Picture$"
  default-column-width { proportion 0.6; }
}

window-rule {
  match title="^Picture-in-Picture$"
  open-floating #true
  open-on-all-workspaces #true
  default-floating-position x=32 y=32 relative-to="bottom-right"
}

window-rule {
  match app-id="^steam_app_"
  open-fullscreen #true
  idle-inhibit "visible"
  presentation-mode "async"
}
```

---

## Interaction & Input

### Input Devices
Configure your peripherals with precision. Blocks are available for `keyboard`, `mouse`, `touchpad`, `trackpoint`, and `trackball`.

| Setting | Values | Description |
| :--- | :--- | :--- |
| `off` | `Bool` | Disable the device entirely. |
| `repeat-rate` | `Hz` | Keys repeated per second (0..1000). |
| `repeat-delay` | `ms` | Delay before key repeat starts (0..20000). |
| `natural-scroll` | `Bool` | Reverse scroll direction. |
| `accel-profile` | `"none"`, `"flat"`, `"adaptive"` | Pointer acceleration behavior. |
| `accel-speed` | `-1.0..1.0` | Pointer speed adjustment. |
| `scroll-method` | `"none"`, `"two-finger"`, `"edge"`, `"on-button-down"` | How to trigger scrolling. |
| `scroll-button` | `Int" | Button code for `on-button-down` scrolling. |
| `scroll-button-lock` | `Bool" | Lock scroll mode after button press. |
| `scroll-factor` | `0.0..100.0` | Sensitivity of scrolling. |
| `left-handed` | `Bool` | Swap left and right buttons. |
| `middle-emulation` | `Bool` | Simulate middle click by pressing both buttons. |
| `tap` | `Bool` | (Touchpad) Enable tap-to-click. |
| `tap-button-map` | `"lrm"`, `"lmr"` | Map taps to mouse buttons. |
| `drag` / `drag-lock` | `Bool` | (Touchpad) Tap-to-drag behavior. |
| `dwt` / `dwtp` | `Bool` | Disable while typing (p for palm detection). |
| `click-method` | `"button-areas"`, `"clickfinger"` | How clicks are registered. |
| `disabled-on-external-mouse` | `Bool` | Disable touchpad when a mouse is plugged in. |

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
    dwt #true
  }

  mouse {
    accel-profile "flat"
    accel-speed 0.0
  }
}
```

### Cursor
Customize the pointer behavior.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `theme` | `String` | The cursor theme name. |
| `size` | `Pixels` | Base cursor size (1..512). |
| `shake-to-find` | `Bool` | Briefly enlarge the cursor when shaken. |
| `hide-when-typing` | `Bool` | Hide cursor when a key is pressed. |
| `hide-after-inactive-ms`| `ms` | Hide cursor after stillness. |

---

## Bindings & Events

### Bindings
Triad supports keyboard, pointer, wheel, and gesture bindings.

*   `bind`: Keyboard commands (e.g., `"Super+Return"`).
*   `pointer-bind`: Mouse button commands.
*   `axis-bind`: Scroll wheel commands.
*   `gesture-bind`: Touchpad swipe gestures.

**Options:**
*   `mode`: Restrict a binding to a specific mode (e.g., `mode="overview"`).
*   `on-release`: Run the command when the key is released.
*   `while-locked`: Allow the command to run while the session is locked.
*   `allow-inhibiting`: If `#false`, the binding can bypass client-side shortcut inhibition.
*   `layout`: Force a specific XKB layout index for the binding.
*   `hotkey-overlay-title`: Human-readable label for the hotkey guide.

**Example Bindings:**
```kdl
bindings {
  bind "Super+Return" "spawn-terminal"
  bind "Super+Q" "close-window"
  bind "Super+Space" "toggle-overview"
  
  pointer-bind "Super+btn-left" "move"
  pointer-bind "Super+btn-right" "resize"
  
  axis-bind "Super+wheel-up" "focus-left"
  axis-bind "Super+wheel-down" "focus-right"
  
  gesture-bind "Super+swipe-left" "focus-left" fingers=3
  gesture-bind "Super+swipe-right" "focus-right" fingers=3
}
```

### Switch Events
Handle hardware changes like closing your laptop lid.

| Event | Description |
| :--- | :--- |
| `lid-close` / `lid-open` | Laptop lid actions. |
| `tablet-mode-on` / `off` | Tablet mode transitions. |

---

## Native Features

### Recent Windows (Switcher)
A built-in Most Recently Used (MRU) switcher with native previews.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `enabled` | `Bool` | Toggle the MRU switcher feature. |
| `debounce-ms` | `ms` | Time to wait before a window is recorded. |
| `open-delay-ms` | `ms` | Delay before the preview overlay appears. |
| `highlight` | `Block` | Configure `active-color`, `urgent-color`, etc. |
| `previews` | `Block` | Set `max-height` and `max-scale` for snapshots. |

**Example Switcher Configuration:**
```kdl
recent-windows {
  debounce-ms 500
  open-delay-ms 100
  highlight {
    active-color "#999999"
    padding 20
  }
}
```

### Hotkey Overlay
A visual guide to your current keybindings.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `skip-at-startup` | `Bool` | Don't show the guide on Triad launch. |
| `hide-not-bound" | `Bool` | Hide rows that don't have a configured key. |
| `position` | `"top"`, `"center"`, `"bottom"` | Overlay placement on screen. |
| `columns` | `1..4` | Number of columns in the guide. |

### Scratchpads
Persistent, hidden window pools for background applications.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `width-ratio` | `0.1..1.0` | Default width of the scratchpad window. |
| `height-ratio`| `0.1..1.0` | Default height of the scratchpad window. |

### Overview
A birds-eye view of all your workspaces.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `outer-gap` | `Pixels` | Gaps around the overview frame. |
| `inner-gap-multiplier`| `Float` | Multiplier for gaps between previews. |
| `zoom` | `Float" | Scaling factor for previews. |
| `tab-mode` | `Bool` | Enable modifier-hold cycling. |
| `hot-corners` | `Block` | Configure trigger `size` and active corners. |

---

## Integration & Compatibility

### Shell Compatibility
Triad can provide a compatibility layer for existing Wayland shells that expect a specific JSON IPC contract.

| Feature | Description |
| :--- | :--- |
| `niri-compat` | When enabled in a `profile`, Triad sets `$NIRI_SOCKET` and provides a compatible IPC facade. |
| `triad_niri` | A CLI tool that maps standard message commands to Triad's native equivalents. |

**How it works:**
When a shell profile is started with `niri-compat #true`, Triad creates a private runtime environment:
- `$NIRI_SOCKET` points at Triad's compatibility socket.
- `XDG_CURRENT_DESKTOP=triad` is set so shells select the correct backend.
- `PATH` is updated to prioritize Triad's compatibility tools.

### Janet Scripting
Triad includes an embedded Janet runtime for advanced automation. Scripts in
`script-dir` can subscribe to runtime events with `triad/on` and emit normal
Triad commands through `triad/command`.
Named Janet layouts are declared in the same block. A custom layout name is a
bare id that must not collide with a built-in layout id. Each declaration has a
safe fallback used for overview, compatibility projections, and any failed
custom evaluation. The fallback may be a built-in layout id or the native
`frame-tree` layout. A `frame-tree` fallback exposes immutable frame/tab data to
the layout script and lets Triad render the same native frame state when Janet
evaluation fails.

**Example Janet Configuration:**
```kdl
janet {
  enabled #true
  script-dir "~/.config/triad/janet"
  fuel-limit 500000
  layout "spiral" fallback="scroller"
  layout "wide-master" fallback="tile"
  layout "janet-frame-tree" fallback="frame-tree"
}
```

Declared Janet layout names can be used in `layout-cycle`,
`workspaces default-layout`, and `workspace-rules default-layout=...`.
When a layout uses `fallback="frame-tree"`, it may return frame geometry with
`:frame-id` instead of direct `:window-id` geometry. Triad maps each frame rect
to that frame's active visible tab, preserves empty frame rects for native
chrome, and lets the native frame tree fill the output usable rect without
adding the normal outer layout gap.

### Config Notifications
Run custom commands to notify yourself of configuration reload results.

**Example Notification Configuration:**
```kdl
config-notification {
  reload-succeeded "notify-send" "Triad" "Config reloaded"
  reload-failed "notify-send" "Triad" "Syntax error in config"
}
```

### Protocol Surfaces
Advanced control over Wayland protocol-driven surfaces.

| Setting | Format | Description |
| :--- | :--- | :--- |
| `enabled" | `Bool` | Toggle protocol surface management. |
| `visible-debug" | `Bool` | Draw debug boxes around protocol surfaces. |

---

## Global Flags

| Flag | Format | Description |
| :--- | :--- | :--- |
| `presentation-mode`| `"default"`, `"vsync"`, `"async"` | Global output presentation policy. |
| `allow-exit-session`| `Bool` | Whether to allow the `exit-session` command. |
