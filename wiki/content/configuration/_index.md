+++
title = "Configuration"
sort_by = "weight"
insert_anchor_links = "right"
render = true
+++

# Configuration

Everything lives in `~/.config/triad/config.kdl`. The file reloads on save.
Split it across multiple files with `include` if it grows large.

---

### [Basics](@/configuration/basics.md)

The config format, hot reload, modular includes, environment variables, startup
commands, and the layout block.

### [Monitors](@/configuration/monitors.md)

Output modes, positions, scaling, VRR, reserved areas, and hotplug behavior.

### [Workspaces](@/configuration/workspaces.md)

Naming workspaces, setting default layouts, pinning to outputs, dynamic
creation, and moving workspaces between monitors.

### [Layouts](@/configuration/layouts.md)

The full layout reference: scroller, BSP, i3, frame-tree, algorithmic layouts,
and custom Janet layouts.

### [Window Rules](@/configuration/window-rules.md)

Match windows by app-id or title and control placement, floating state,
workspace assignment, and sizing.

### [Key Bindings](@/configuration/key-bindings.md)

Keyboard, pointer, scroll wheel, and gesture bindings. Layout-scoped bindings
and repeat behavior.

### [Input](@/configuration/input.md)

Keyboard XKB layout and repeat rate, touchpad settings, mouse acceleration, and
cursor theme.

### [Shell Setup](@/configuration/shell-setup.md)

Configure Waybar, Noctalia, DankMaterialShell, and other shell bars. Shell profiles,
niri-compat IPC, and watchdog fallback.
