+++
title = "Key Bindings"
weight = 45
+++

# Key Bindings

Triad supports four binding types: keyboard, pointer buttons, scroll wheel, and
touchpad gestures. All live in the `bindings` block and reload on save.

## Keyboard Bindings

```kdl
bindings {
  bind "Super+Return"       "spawn-terminal"
  bind "Super+Q"            "close-window"
  bind "Super+Space"        "switch-layout"
  bind "Super+F"            "toggle-overview"
  bind "Super+H"            "focus-left"
  bind "Super+L"            "focus-right"
  bind "Super+J"            "focus-down"
  bind "Super+K"            "focus-up"
  bind "Super+Shift+H"      "move-column-left"
  bind "Super+Shift+L"      "move-column-right"
  bind "Super+1"            "focus-workspace 1"
  bind "Super+Shift+1"      "move-to-workspace 1"
}
```

Modifier keys: `Super`, `Ctrl`, `Alt`, `Shift`. Combine with `+`.

Key names follow XKB conventions. Use `xkbcli interactive-wayland` or
`wev` to find the name of any key.

## Pointer Bindings

Bind mouse buttons with `pointer-bind`:

```kdl
bindings {
  pointer-bind "Super+btn-left"   "move"
  pointer-bind "Super+btn-right"  "resize"
  pointer-bind "Super+btn-middle" "toggle-floating"
}
```

Button names: `btn-left`, `btn-right`, `btn-middle`, `btn-side`,
`btn-extra`, `btn-forward`, `btn-back`.

## Scroll Wheel Bindings

Bind scroll axes with `axis-bind`:

```kdl
bindings {
  axis-bind "Super+scroll-up"    "focus-workspace-up"
  axis-bind "Super+scroll-down"  "focus-workspace-down"
}
```

## Gesture Bindings

Bind touchpad swipe gestures with `gesture-bind`:

```kdl
bindings {
  gesture-bind "swipe-left-3"   "focus-tag-left"
  gesture-bind "swipe-right-3"  "focus-tag-right"
  gesture-bind "swipe-up-4"     "toggle-overview"
}
```

Gesture names follow the pattern `swipe-<direction>-<fingers>`. Direction:
`left`, `right`, `up`, `down`. Fingers: `3` or `4`.

## Layout-Scoped Bindings

Bind a key differently depending on the active layout. The layout-specific
binding takes precedence when that layout is active:

```kdl
bindings {
  bind "Super+Alt+H" "move-column-left"

  layout "i3" {
    bind "Super+Alt+H" "split-tree-split-horizontal"
    bind "Super+Alt+V" "split-tree-split-vertical"
    bind "Super+E"     "split-tree-layout-toggle-split"
    bind "Super+S"     "split-tree-layout-stacking"
    bind "Super+W"     "split-tree-layout-tabbed"
  }
}
```

## Spawning Programs

Pass arguments to `spawn` as separate strings:

```kdl
bindings {
  bind "Super+D"        spawn="fuzzel"
  bind "Super+Shift+S"  spawn="grim" "-g" {slurp} "-"
}
```

## Repeating Bindings

By default, bindings trigger once per press. Add `repeat=#true` for bindings
that should fire repeatedly while held:

```kdl
bindings {
  bind "Super+H" "focus-left"  repeat=#true
  bind "Super+L" "focus-right" repeat=#true
}
```

For the full list of commands you can bind, see
[IPC & Commands](@/usage/ipc-commands.md).
