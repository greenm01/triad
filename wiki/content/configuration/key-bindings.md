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
  bind "Super+Return"  "spawn kitty"
  bind "Super+Space"   "spawn fuzzel"
  bind "Super+q"       "close-window"
  bind "Super+o"       "toggle-overview"
  bind "Super+n"       "switch-layout"
  bind "Super+h"       "focus-left"
  bind "Super+l"       "focus-right"
  bind "Super+j"       "focus-down"
  bind "Super+k"       "focus-up"
  bind "Super+Alt+h"   "move-column-left"
  bind "Super+Alt+l"   "move-column-right"
  bind "Super+1"       "focus-workspace 1"
  bind "Super+Ctrl+1"  "move-to-workspace 1"
}
```

Modifier keys: `Super`, `Ctrl`, `Alt`, `Shift`. Combine with `+`.

Key names follow XKB conventions. Use `xkbcli interactive-wayland` or
`wev` to find the name of any key.

## Pointer Bindings

Bind mouse buttons with `pointer-bind`:

```kdl
bindings {
  pointer-bind "Super+left"   "move"
  pointer-bind "Super+right"  "resize"
  pointer-bind "Super+middle" "toggle-maximized"
}
```

Button names: `left`, `right`, `middle`, `side`, `extra`, `forward`, `back`,
`task`.

## Scroll Wheel Bindings

Bind scroll axes with `axis-bind`:

```kdl
bindings {
  axis-bind "Super+wheel-up"    "focus-left"
  axis-bind "Super+wheel-down"  "focus-right"
}
```

## Gesture Bindings

Bind custom touchpad swipe gestures with `gesture-bind`:

```kdl
bindings {
  gesture-bind "Super+swipe-left"   "focus-tag-left"  fingers=3
  gesture-bind "Super+swipe-right"  "focus-tag-right" fingers=3
  gesture-bind "Super+swipe-up"     "toggle-overview" fingers=4
}
```

Gesture names are `swipe-left`, `swipe-right`, `swipe-up`, or `swipe-down`.
Set `fingers=3` or `fingers=4`.

## Layout-Scoped Bindings

Bind a key differently depending on the active layout. The layout-specific
binding takes precedence when that layout is active:

```kdl
bindings {
  bind "Super+Alt+h" "move-column-left"

  layout "i3" {
    bind "Super+Alt+h" "split-tree-split-horizontal"
    bind "Super+Alt+v" "split-tree-split-vertical"
    bind "Super+e"     "split-tree-layout-toggle-split"
    bind "Super+s"     "split-tree-layout-stacking"
    bind "Super+w"     "split-tree-layout-tabbed"
  }
}
```

## Spawning Programs

Use the same command text you would pass to `triad msg`:

```kdl
bindings {
  bind "Super+Space"  "spawn fuzzel"
  bind "Super+Print"  "screenshot --clipboard-only"
}
```

## Repeating Bindings

By default, bindings trigger once per press. Add `repeat=#true` for bindings
that should fire repeatedly while held:

```kdl
bindings {
  bind "Super+h" "focus-left"  repeat=#true
  bind "Super+l" "focus-right" repeat=#true
}
```

For the full list of commands you can bind, see
[IPC & Commands](@/usage/ipc-commands.md).
