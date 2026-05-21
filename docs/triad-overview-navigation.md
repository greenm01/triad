# Triad Window Manager — Overview Navigation Spec

## Overview

Triad provides 12 window layouts, one per workspace. Each workspace independently selects and remembers its layout. Overview mode is unified across all layouts as a workspace-strip view.

---

## Layouts

| Layout            | Group        | Topological character |
|-------------------|--------------|-----------------------|
| Tile              | Master-Stack | Bounded               |
| Center Tile       | Master-Stack | Bounded               |
| Vertical Tile     | Master-Stack | Bounded               |
| Right Tile        | Master-Stack | Bounded               |
| Scroller          | Scroller     | Open (horizontal)     |
| Vertical Scroller | Scroller     | Open (vertical)       |
| Grid              | Grid         | Bounded               |
| Vertical Grid     | Grid         | Bounded               |
| Deck              | Deck         | Bounded (cyclic)      |
| Vertical Deck     | Deck         | Bounded (cyclic)      |
| Monocle           | —            | Bounded (cyclic)      |
| TGMix             | —            | Bounded               |

**Bounded** layouts fill a fixed output rect. **Open** layouts extend indefinitely along their primary axis (Scroller: horizontal; Vertical Scroller: vertical). **Cyclic** layouts show one window at a time and cycle through the rest.

The **Scroller** layout allows windows to be arranged in columns; the strip scrolls horizontally, and the overview provides a zoomed-out view of that strip. This model applies to every layout, with each workspace rendered according to its own selected layout.

---

## Overview Mode

Overview mode is a zoomed-out view of the workspaces visible on each connected output. It allows navigation and window selection without exiting the overview. Overview state lives at the workspace manager level; no individual layout owns it.

### Workspace Arrangement

On every connected output, that output's workspaces are arranged as a vertical strip of bounding boxes. Each layout renders itself into its assigned rect:

- **Open (horizontal)** — Scroller: all columns compressed into the rect, with a horizontal scroll indicator for offscreen content.
- **Open (vertical)** — Vertical Scroller: all rows compressed into the rect, with a vertical scroll indicator.
- **Bounded** — rendered at reduced scale; already fits the rect.
- **Cyclic** — the visible window is shown at reduced scale with a window count badge indicating hidden windows.

---

## Navigation Model

### Core Principle

> Arrow keys navigate spatially within the focused workspace. At the vertical boundary of that workspace, Up/Down crosses to the adjacent keyboard-selectable workspace preview, wrapping at the ends like a list highlight. Left/Right stop at the horizontal boundary of the focused layout.

Every layout implements a consistent navigation protocol. The overview manager dispatches uniformly, treating each layout as a provider of spatial targets.

### Layout Overview Interface

```nim
type
  NavResultKind = enum
    nrWindow, nrBoundary

  NavResult = object
    case kind: NavResultKind
    of nrWindow: window: WindowId
    of nrBoundary: direction: Direction

  LayoutOverview = concept l
    proc navigate(l: var Layout, dir: Direction): NavResult
    proc entryWindow(l: Layout, fromDir: Direction): WindowId
```

**Boundary semantics per layout:**

- **Scroller**: `nrBoundary` past the first/last column (left/right) or top/bottom window within the focused column (up/down).
- **Vertical Scroller**: `nrBoundary` past the top/bottom row (up/down) or leftmost/rightmost window within the focused row (left/right).
- **Master-Stack (Tile, Center Tile, Vertical Tile, Right Tile)**: `nrBoundary` at the outer edge of the window arrangement in the given direction.
- **Grid / Vertical Grid**: `nrBoundary` at top row (up), bottom row (down), leftmost column (left), rightmost column (right).
- **Deck / Vertical Deck / Monocle**: `nrBoundary` past the first or last window in the cycle stack.
- **TGMix**: `nrBoundary` at the outer edges of the combined tile+grid arrangement.

### Overview Manager Dispatch

```nim
proc handleDirection(mgr: var OverviewManager, dir: Direction) =
  let res = mgr.focusedWs.layout.navigate(dir)
  case res.kind
  of nrWindow:
    mgr.setFocus(res.window)
  of nrBoundary:
    case res.direction
    of dUp, dDown:
      mgr.crossToAdjacent(res.direction)
    else:
      discard # Horizontal boundaries are inert in overview

proc handlePgUpPgDn(mgr: var OverviewManager, dir: Direction) =
  # Skips intra-workspace navigation entirely
  mgr.crossToAdjacent(dir)

proc crossToAdjacent(mgr: var OverviewManager, dir: Direction) =
  if let nextWs = mgr.adjacentWorkspace(dir):
    let entry = nextWs.layout.entryWindow(dir)
    mgr.setFocusedWorkspace(nextWs)
    mgr.setFocus(entry)
```

### Entry Points

Arrival direction determines the entry window. Entry feels spatially consistent with the direction of travel:

```nim
# Grid / Vertical Grid
proc entryWindow(l: GridLayout, fromDir: Direction): WindowId =
  case fromDir
  of dUp:    l.bottomRowLeftmost()
  of dDown:  l.topRowLeftmost()
  of dLeft:  l.rightmostColumnTopmost()
  of dRight: l.leftmostColumnTopmost()

# Deck / Vertical Deck / Monocle
proc entryWindow(l: DeckLayout, fromDir: Direction): WindowId =
  case fromDir
  of dUp, dLeft:    l.lastInStack()
  of dDown, dRight: l.firstInStack()
```

---

## PgUp / PgDn — Explicit Workspace Jump

`PgUp` and `PgDn` jump to the previous or next keyboard-selectable workspace preview from anywhere in overview, bypassing intra-workspace navigation.

Both call `crossToAdjacent` directly. PgUp/PgDn are a **speed layer** for workspace preview traversal, while horizontal arrow boundaries remain inert.

Keyboard traversal visits the active workspace preview and occupied workspace previews. Inactive empty default workspaces and trailing dynamic creation workspaces are hidden from overview, so traversal skips them.

---

## Overview Focus State

```nim
type
  OverviewFocusKind = enum
    ofWorkspace, ofWindow

  OverviewFocus = object
    case kind: OverviewFocusKind
    of ofWorkspace: wsId: WorkspaceId
    of ofWindow: 
      wsId: WorkspaceId
      winId: WindowId
```

Overview enters with `ofWindow` focus on the most recently focused window of the active workspace. Crossing to an adjacent workspace sets focus to that workspace's entry window. Overview state is cleared on exit.

---

## Visual Behavior

- **Vertical arrow boundary crossing**: the overview strip scrolls to bring the destination workspace into view.
- **Horizontal arrow boundaries**: focus remains in the current workspace.
- **PgUp/PgDn crossing**: same scroll animation; no visual distinction.
- The focused workspace has a distinct border treatment.
- Open-axis layouts show a scroll indicator when content exceeds the thumbnail width or height.
- Cyclic layouts (Deck, Vertical Deck, Monocle) show a window count badge.

---

## Constraints and Non-Goals

- Overview is global; it is not scoped to a single workspace or output, but each output renders its own workspace strip.
- Layout selection is per-workspace, never per-output.
- Layout switching does not occur within overview.
- Floating windows are out of scope for this revision.
