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

The config format, hot reload, modular includes, key bindings, startup
commands, input devices, cursor, and shell/bar setup.

### [Monitors](@/configuration/monitors.md)

Output modes, positions, scaling, VRR, reserved areas, and hotplug behavior.

### [Workspaces](@/configuration/workspaces.md)

Naming workspaces, setting default layouts, pinning to outputs, dynamic
creation, and moving workspaces between monitors.

### [Layouts](@/configuration/layouts.md)

The full layout reference: scroller, BSP, i3, frame-tree, algorithmic layouts,
and custom Janet layouts.
