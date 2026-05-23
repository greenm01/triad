+++
title = "Overview"
weight = 15
+++

# Overview

Overview mode shows all your workspaces at once as a zoomed-out strip. You can
navigate between windows and workspaces without leaving overview.

## Entering and Exiting

Toggle overview with the configured binding (default `Super+o`) or:

```bash
triad msg toggle-overview
```

You can also open overview from configured hot corners. Hot corners are opt-in
and open overview only; they do not close it when overview is already active.

```kdl
overview {
  hot-corners {
    size 12
    top-left
    bottom-right
  }
}
```

Press `Return` to confirm the selected window and exit. Press `Escape` to exit
without changing focus.

## Navigation

Arrow keys navigate spatially within the focused workspace. When you reach the
edge of a workspace, `Up` and `Down` cross to the adjacent workspace preview.
`Left` and `Right` stop at the horizontal boundary of the focused layout.

`PgUp` and `PgDn` jump directly between workspace previews, skipping
intra-workspace navigation.

Overview visits occupied workspaces and the active workspace. Empty dynamic
workspaces are hidden from the strip.

## How Each Layout Renders in Overview

Each workspace renders itself into its assigned thumbnail rect according to its
own layout:

| Layout type | How it appears |
|---|---|
| Scroller / Vertical Scroller | All columns compressed into the rect; a scroll indicator marks offscreen content. |
| Bounded (tile, grid, BSP, i3…) | Rendered at reduced scale; fills the rect. |
| Cyclic (deck, monocle…) | The visible window shown at reduced scale with a window count badge. |

## Binding Example

```kdl
bindings {
  bind "Super+o"       "toggle-overview"
  bind "Alt+Tab"       "recent-window-next"
  bind "Alt+Shift+Tab" "recent-window-prev"
}
```

The MRU switcher (`recent-window-next` / `recent-window-prev`) is separate from
overview — it cycles through your most recently used windows without the
zoomed-out view. Both are available at the same time.
