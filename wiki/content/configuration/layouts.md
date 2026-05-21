+++
title = "Layouts"
weight = 35
+++

# Layouts

Every workspace in Triad picks its own layout. Switch one without touching the
others. Change layout mid-session with a binding or `triad msg`.

## Selecting a Layout

Define the cycle for `switch-layout` and add per-layout bindings in your config:

```kdl
layout {
  layout-cycle "scroller" "tile" "monocle"
}

bindings {
  bind "Super+Space" "switch-layout"
  bind "Super+S"     "layout-scroller"
  bind "Super+T"     "layout-tile"
  bind "Super+M"     "layout-monocle"
}
```

Or switch at any time via IPC:

```bash
triad msg layout-scroller
triad msg layout-tile
triad msg switch-layout
```

---

## Scrolling

If you've used Niri or PaperWM, this will feel familiar. Windows sit on an
infinite horizontal (or vertical) strip. Navigation is scrolling, not switching.

| Layout | Description | You might know it from |
|---|---|---|
| `scroller` | Infinite horizontal strip. Windows scroll left and right past the screen edge. | Niri, PaperWM, Hyprland, Mango |
| `vertical-scroller` | Same as scroller, oriented vertically. | Mango |

---

## Algorithmic

The layout algorithm places all windows automatically. Windows reflow when
others open or close. No manual splitting required.

| Layout | Description | You might know it from |
|---|---|---|
| `tile` | One master window takes a fixed portion; the rest stack on the other side. | dwm, awesome, qtile |
| `vertical-tile` | Master on top, stack below. Portrait orientation of tile. | Mango |
| `right-tile` | Master on right, stack on left. | Mango |
| `center-tile` | Master centered; stack windows flank left and right. | Mango |
| `grid` | Windows fill equal-area cells. Adapts as windows open and close. | awesome, qtile |
| `vertical-grid` | Grid oriented vertically. | Mango |
| `monocle` | One window fills the screen. Cycle through the rest. | dwm, xmonad |
| `deck` | Master visible; others stacked behind as layers. | dwm (patch) |
| `vertical-deck` | Deck oriented vertically. | Mango |
| `spiral` | Each new window takes a ratio of the remaining space, spiraling inward. | xmonad, qtile |
| `master` | Single master with a configurable number of stack windows. | Hyprland |
| `tgmix` | Shows windows from multiple tags under one layout. | Mango |

---

## BSP

Each new window bisects the focused region. The tree grows automatically as
windows open; you resize and rebalance after the fact.

| Layout | Description | You might know it from |
|---|---|---|
| `bsp` | New windows split the focused leaf automatically. Janet drives the geometry policy. | bspwm, Hyprland |
| `bsp-tree` | Persistent binary partition tree. Triad owns insertion, preselection, directional focus, resize, and balance. | bspwm |
| `dwindle` | New windows split the focused container and spiral inward. | Hyprland, Mango |

---

## Frame-tree

Persistent named frames exist independently of their contents. Build the frame
structure first; windows fill it. Frames survive when empty. If you've used
Notion or StumpWM, this model will feel familiar.

| Layout | Description | You might know it from |
|---|---|---|
| `notion` | Janet geometry policy over Triad-owned persistent frames and tabs. | Notion |
| `frame-tree` | Persistent leaf frames hold tabs. Split nodes divide space. Empty frames survive. | Notion, Ion, StumpWM |

---

## Split-tree

You build the layout manually by splitting containers. Each container runs in
split, tabbed, or stacked mode independently. The tree persists across window
changes.

| Layout | Description | You might know it from |
|---|---|---|
| `i3` | Persistent i3-style container tree. Triad owns splits, insertion, movement, resize, and restore. | i3, Sway |
| `tabbed` | Windows stacked as tabs inside a split-tree container. | i3, Sway |
| `stacked` | Windows stacked vertically with visible titlebars inside a split-tree container. | i3, Sway |

---

## Custom Layouts

Need something Triad doesn't ship? Write it in Janet. Any layout you define
becomes a first-class layout ID — usable in `layout-cycle`, workspace rules,
and IPC commands. See [Janet Scripting](@/usage/janet-scripting.md) to get
started.
