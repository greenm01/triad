# Triad Window Manager — Overview Navigation Spec

## Overview

Triad provides 12 window layouts, one per workspace. Each workspace
independently selects and remembers its layout. Overview mode is unified across
all layouts as a workspace-strip view.

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

**Bounded** layouts fill a fixed output rect. **Open** layouts extend
indefinitely along their primary axis (Scroller: horizontal; Vertical Scroller:
vertical). **Cyclic** layouts show one window at a time and cycle through the
rest.

The **Scroller** layout is modeled after niri: windows are arranged in columns,
the strip scrolls horizontally, and the overview is a zoom-out of that strip.
The same overview model now applies to every layout, with each workspace
rendered according to its own selected layout.

---

## Overview Mode

Overview mode is a zoomed-out view of all workspaces. It allows navigation and
window selection without exiting the overview. Overview state lives at the
workspace manager level; no individual layout owns it.

### Workspace Arrangement

Workspaces are arranged as a vertical strip of bounding boxes. Each layout
renders itself into its assigned rect:

- **Open (horizontal)** — Scroller: all columns compressed into the rect, with
  a horizontal scroll indicator for offscreen content.
- **Open (vertical)** — Vertical Scroller: all rows compressed into the rect,
  with a vertical scroll indicator.
- **Bounded** — rendered at reduced scale; already fits the rect.
- **Cyclic** — the visible window is shown at reduced scale with a window count
  badge indicating hidden windows.

---

## Navigation Model

### Core Principle

> Arrow keys navigate spatially within the focused workspace. At the vertical
> boundary of that workspace, Up/Down crosses to the adjacent
> keyboard-selectable workspace preview, wrapping at the ends like a list
> highlight. Left/Right stop at the horizontal boundary of the focused layout.

Every layout implements the same two-method protocol. The overview manager
dispatches uniformly with no per-layout special cases.

### Layout Overview Protocol

```rust
trait LayoutOverview {
    /// Navigate in a direction. Returns the newly focused window,
    /// or signals that the workspace boundary was reached.
    fn navigate(&mut self, dir: Direction) -> NavResult;

    /// Returns the entry window when arriving from an adjacent workspace.
    fn entry_window(&self, from: Direction) -> WindowId;
}

enum NavResult {
    Window(WindowId),
    Boundary(Direction),
}
```

**Boundary semantics per layout:**

- **Scroller**: `Boundary` past the first/last column (left/right) or top/bottom
  window within the focused column (up/down).
- **Vertical Scroller**: `Boundary` past the top/bottom row (up/down) or
  leftmost/rightmost window within the focused row (left/right).
- **Master-Stack (Tile, Center Tile, Vertical Tile, Right Tile)**: `Boundary`
  at the outer edge of the window arrangement in the given direction.
- **Grid / Vertical Grid**: `Boundary` at top row (up), bottom row (down),
  leftmost column (left), rightmost column (right).
- **Deck / Vertical Deck / Monocle**: `Boundary` past the first or last window
  in the cycle stack.
- **TGMix**: `Boundary` at the outer edges of the combined tile+grid
  arrangement.

### Overview Manager Dispatch

```rust
fn handle_direction(&mut self, dir: Direction) {
    match self.focused_ws().layout.navigate(dir) {
        NavResult::Window(w)                  => self.set_focus(w),
        NavResult::Boundary(Direction::Up)    => self.cross_to_adjacent(Direction::Up),
        NavResult::Boundary(Direction::Down)  => self.cross_to_adjacent(Direction::Down),
        NavResult::Boundary(Direction::Left)  => {}
        NavResult::Boundary(Direction::Right) => {}
    }
}

fn handle_pgup_pgdown(&mut self, dir: Direction) {
    // skips intra-workspace navigation entirely
    self.cross_to_adjacent(dir);
}

fn cross_to_adjacent(&mut self, dir: Direction) {
    if let Some(next_ws) = self.adjacent_workspace(dir) {
        let entry = next_ws.layout.entry_window(dir);
        self.set_focused_workspace(next_ws);
        self.set_focus(entry);
    }
}
```

### Entry Points

Arrival direction determines the entry window. Entry should feel spatially
consistent with the direction of travel:

```rust
// Grid / Vertical Grid
fn entry_window(&self, from: Direction) -> WindowId {
    match from {
        Direction::Up    => self.bottom_row_leftmost(),
        Direction::Down  => self.top_row_leftmost(),
        Direction::Left  => self.rightmost_column_topmost(),
        Direction::Right => self.leftmost_column_topmost(),
    }
}

// Deck / Vertical Deck / Monocle
fn entry_window(&self, from: Direction) -> WindowId {
    match from {
        Direction::Up | Direction::Left    => self.last_in_stack(),
        Direction::Down | Direction::Right => self.first_in_stack(),
    }
}
```

---

## PgUp / PgDn — Explicit Workspace Jump

`PgUp` and `PgDn` jump to the previous or next keyboard-selectable workspace
preview from anywhere in overview, bypassing intra-workspace navigation.

Both call `cross_to_adjacent` directly. PgUp/PgDn are a **speed layer** for
workspace preview traversal, while horizontal arrow boundaries remain inert.

Keyboard traversal visits every visible workspace preview. That includes empty
default workspaces, active dynamic empty workspaces, and the trailing dynamic
creation preview because each preview is an actionable overview destination.

---

## Overview Focus State

```rust
enum OverviewFocus {
    Workspace(WorkspaceId),
    Window(WorkspaceId, WindowId),
}
```

Overview enters with `Window` focus on the most recently focused window of the
active workspace. Crossing to an adjacent workspace sets focus to that
workspace's entry window. Overview state is cleared on exit.

---

## Visual Behavior

- **Vertical arrow boundary crossing**: the overview strip scrolls to bring the
  destination workspace into view.
- **Horizontal arrow boundaries**: focus remains in the current workspace.
- **PgUp/PgDn crossing**: same scroll animation; no visual distinction.
- The focused workspace has a distinct border treatment.
- Open-axis layouts show a scroll indicator when content exceeds the thumbnail
  width or height.
- Cyclic layouts (Deck, Vertical Deck, Monocle) show a window count badge.

---

## Constraints and Non-Goals

- Overview is global; it is not scoped to a single workspace.
- Layout selection is per-workspace, never per-output.
- Layout switching does not occur within overview.
- Floating windows are out of scope for this revision.
