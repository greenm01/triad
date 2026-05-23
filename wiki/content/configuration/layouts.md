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
  bind "Super+n"       "switch-layout"
  bind "Super+d"       "tile"
  bind "Super+g"       "grid"
  bind "Super+Ctrl+x"  "monocle"
}
```

Or switch at any time via IPC:

```bash
triad msg scroller
triad msg tile
triad msg switch-layout
```

Short layout IDs work in binds and IPC commands for Triad's built-in, bundled,
and native layouts. Use names like `notion`, `dwindle`, `center-tile`,
`spiral`, or `i3` directly.

---

## Scrolling

Windows sit on an infinite horizontal or vertical strip. Navigation is
scrolling, not switching.

| Layout | Description | Model |
|---|---|---|
| `scroller` | Infinite horizontal strip. Windows scroll left and right past the screen edge. | Horizontal strip |
| `vertical-scroller` | Same as scroller, oriented vertically. | Vertical strip |

---

## Algorithmic

The layout algorithm places all windows automatically. Windows reflow when
others open or close. No manual splitting required.

| Layout | Description | Model |
|---|---|---|
| `tile` | One master window takes a fixed portion; the rest stack on the other side. | Master-stack |
| `vertical-tile` | Master on top, stack below. Portrait orientation of tile. | Vertical master-stack |
| `right-tile` | Master on right, stack on left. | Mirrored master-stack |
| `center-tile` | Master centered; stack windows flank left and right. | Centered master-stack |
| `grid` | Windows fill equal-area cells. Adapts as windows open and close. | Grid |
| `vertical-grid` | Grid oriented vertically. | Vertical grid |
| `monocle` | One window fills the screen. Cycle through the rest. | Single-window view |
| `deck` | Master visible; others stacked behind as layers. | Master deck |
| `vertical-deck` | Deck oriented vertically. | Vertical deck |
| `spiral` | Each new window takes a ratio of the remaining space, spiraling inward. | Recursive split |
| `master` | Single master with a configurable number of stack windows. | Master-stack |
| `tgmix` | Shows windows from multiple tags under one layout. | Tag-mixed |

---

## BSP

Each new window bisects the focused region. The tree grows automatically as
windows open; you resize and rebalance after the fact.

| Layout | Description | Model |
|---|---|---|
| `bsp` | New windows split the focused leaf automatically. Janet drives the geometry policy. | Automatic BSP |
| `bsp-tree` | Persistent binary partition tree. Triad owns insertion, preselection, directional focus, resize, and balance. | Native BSP |
| `dwindle` | New windows split the focused container and spiral inward. | Focused split |

---

## Frame-tree

Persistent named frames exist independently of their contents. Build the frame
structure first; windows fill it. Frames survive when empty.

| Layout | Description | Model |
|---|---|---|
| `notion` | Janet geometry policy over Triad-owned persistent frames and tabs. | Frame policy |
| `frame-tree` | Persistent leaf frames hold tabs. Split nodes divide space. Empty frames survive. | Native frame tree |

---

## Split-tree

You build the layout manually by splitting containers. Each container runs in
split, tabbed, or stacked mode independently. The tree persists across window
changes.

| Layout | Description | Model |
|---|---|---|
| `i3` | Persistent split-tree container model. Triad owns splits, insertion, movement, resize, and restore. | Native split tree |
| `tabbed` | Windows stacked as tabs inside a split-tree container. | Tabbed container |
| `stacked` | Windows stacked vertically with visible titlebars inside a split-tree container. | Stacked container |

---

## Custom Layouts

Need something Triad doesn't ship? Write it in Janet. Any layout you define
becomes a first-class layout ID — usable in `layout-cycle`, workspace rules,
and IPC commands. See [Janet Scripting](@/usage/janet-scripting.md) to get
started.
