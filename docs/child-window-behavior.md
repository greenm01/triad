# Child Window Policy

## Core Principle

The right discriminator for float vs. tile is the **semantic type of the child window**, not the parent's layout state (maximized/fullscreen). `set_parent` alone is not sufficient — it must be read together with window type and size hints:

| Surface type | Window type / size | Behavior |
|---|---|---|
| `xdg_popup` | — | Always float, anchor to parent |
| `xdg_toplevel` + `set_parent` | Dialog/utility intent, or no type with small size | Float, center on parent |
| `xdg_toplevel` + `set_parent` | `NORMAL` or large size hint | Tile as normal surface |
| `xdg_toplevel`, no parent | Any | Tile as normal surface |

## Why "Only Float If Maximized" Is Wrong

Floating children only when the parent is maximized/fullscreen causes child windows to open as new tiled columns in scrolling mode. This breaks UX in several ways:

- **Spatial decoupling** — the child is no longer near its parent in the column strip
- **Semantic mismatch** — a save dialog or file picker is not a peer column; it belongs *to* the parent
- **Broken focus flow** — when the child closes, returning focus to the parent is natural from a float, ambiguous from a column
- **App contract violation** — apps are designed assuming dialogs appear near their parent window

The maximized/fullscreen case is simply the most visible instance of the general rule. Non-maximized tiling is actually where the behavior matters more.

## Positioning

Float the child **centered on the parent column**, not on the full screen. This keeps the spatial relationship legible in a busy scrolling layout.

## Why "Always Float a Child Window" Is Also Wrong

Floating every window that sets `set_parent` is too broad. Some toplevels set a parent for focus-ordering or z-stacking reasons without being true dialogs — floating them unconditionally creates clutter and defeats the tiling layout.

**Cases where a child toplevel should tile:**

- **New primary content windows** — a browser's "open in new window", a detached editor split, a second terminal instance spawned from the first. These are full workspaces that happen to have a logical parent; they belong in the column strip.
- **Apps that misuse `set_parent`** — some toolkits set a parent purely for raise/lower ordering, not to indicate a dialog relationship. Treating these as floats fills the screen with orphaned windows.
- **Large windows with no transient intent** — if the initial size hint is close to the parent's size, the app almost certainly intends a peer surface, not an overlay.

**The correct signal is `set_parent` + window type together**, not `set_parent` alone:

| `set_parent` | Window type | Behavior |
|---|---|---|
| Yes | `DIALOG`, `UTILITY`, unspecified small | Float |
| Yes | `NORMAL`, large size hint | Tile |
| No | Any | Tile |

In Triad's River client, semantic window types such as `xdg_dialog` and XWayland EWMH atoms are not exposed today. Triad can currently use the parent relationship, size hints, app id, title, and window rules; explicit dialog protocol/type signals should be treated as future input if River exposes them.

## Edge Case: Persistent Tool Windows

Some apps set a parent but intend the child as a persistent, sizeable workspace (GIMP tool panels, detached DevTools, secondary editor windows). Signals to watch for:

- Large initial size hints relative to the parent
- `_NET_WM_WINDOW_TYPE_UTILITY` vs `_NET_WM_WINDOW_TYPE_DIALOG` (XWayland)
- A substantial `min_size` hint

For these, consider "float but persist position/size" or allow user promotion to a tile column. `_NET_WM_WINDOW_TYPE_UTILITY` in particular sits in a gray zone — treat it as float by default but expose a window rule override for apps like GIMP where the user may prefer tiling.

## Summary

`set_parent` is a necessary but not sufficient condition for floating. The decision tree is:

1. `xdg_popup` → always float
2. `xdg_toplevel` + `set_parent` + dialog/utility/small intent → float, centered on parent
3. `xdg_toplevel` + `set_parent` + primary-surface intent (NORMAL type, large size) → tile
4. `xdg_toplevel`, no parent → tile

The parent's layout state (maximized, tiled, fullscreen) is irrelevant to this decision. What matters is whether the child signals transient dialog intent or primary workspace intent. The per-layout table below governs where floats are anchored and what edge cases apply per layout; the float/tile decision itself is made upstream of layout entirely.

---

## Applying the Policy Across Layouts

The float/tile decision rules are layout-agnostic — the same signal logic applies everywhere. What varies per layout is **where you anchor the float** and **whether the parent is visible** when the child opens. Layouts fall into five families:

### Master-Stack (Tile, Center Tile, Vertical Tile, Right Tile)

The parent is either the master window or one tile in the stack column. Policy is straightforward: float the child centered on the parent window's actual geometry, not on the master region or the screen. If the parent is a small stack tile, the dialog will appear small and offset — that is correct behavior; do not re-center it on the master area.

### Scroller (Scroller, Vertical Scroller)

Float the child centered on the parent column. If the parent is already focused, normal focus retargeting keeps the parent in view and the child can focus immediately. If a background parent is off-screen, the child stays hidden and pending until the parent naturally becomes visible; it must not hijack the user's viewport. Apps that should demand immediate attention can opt in with a parent-matched `dialog-viewport-jump` window rule.

### Grid (Grid, Vertical Grid)

All cells are equal size and the parent can be any cell. Float the child centered on the parent cell. The grid reflowing around a float is normal and expected. Grids are often used for monitoring dashboards where transient config dialogs or alerts are the most common child surface — the policy applies cleanly.

### Deck (Deck, Vertical Deck)

One master window is visible; others are stacked behind it. Two cases:

- **Focused (master) window spawns a child** — float centered on the master area. Normal case.
- **Background (stacked) window spawns a child** — defer the child focus and projection until the parent becomes the active deck item. Do not promote a background parent by default; that steals context from the user's current deck window. A parent-matched `dialog-viewport-jump` rule can opt specific apps into the aggressive behavior.

### Monocle

Single fullscreen window. This is the canonical maximized case the policy was explicitly designed to handle. Float always, center on screen. No special handling needed; it is the obvious case.

### TGMix

Hybrid tile + grid. Follow master-stack rules for windows in the master zone and grid rules for windows in the stack/grid zone. The anchor is always the parent window's geometry regardless of which zone it occupies.

---

### Per-Layout Policy Table

| Layout | Family | Dialog/popup child | Large/primary child | Float anchor | Notes |
|---|---|---|---|---|---|
| Tile | Master-Stack | Float | Tile | Parent window geometry | Stack tiles can be small; do not re-center on master area |
| Center Tile | Master-Stack | Float | Tile | Parent window geometry | Master is centered; float appears naturally central if parent is master |
| Vertical Tile | Master-Stack | Float | Tile | Parent window geometry | Same rules, vertical axis; stack windows are horizontally narrow |
| Right Tile | Master-Stack | Float | Tile | Parent window geometry | Mirror of Tile; no behavioral difference |
| Scroller | Scroller | Float | Tile | Parent column center | Background off-screen children defer focus; `dialog-viewport-jump` opts in to immediate camera movement |
| Vertical Scroller | Scroller | Float | Tile | Parent row center | Same deferred default as Scroller on the vertical axis |
| Grid | Grid | Float | Tile | Parent cell center | Grid reflowing around a float is expected and fine |
| Vertical Grid | Grid | Float | Tile | Parent cell center | Same as Grid; vertical split priority doesn't change child policy |
| Deck | Deck | Float | Tile | Master window | Background children defer by default; parent rule can opt in to immediate promotion |
| Vertical Deck | Deck | Float | Tile | Master window | Same deferred default as Deck; vertical axis only |
| Monocle | Monocle | Float | Tile (hidden until layout change) | Screen center | Canonical fullscreen case; parent and screen center coincide |
| TGMix | Hybrid | Float | Tile | Parent window geometry | Master zone: follow master-stack rules; grid zone: follow grid rules |

---

## Triad Compliance Tracker

| Policy item | Triad status | Notes |
|---|---|---|
| Store parent id for child windows | Pass | River parent events are persisted in runtime, shell snapshots, and live restore. |
| Parent layout state does not decide float/tile | Pass | Parented child policy ignores whether the parent is tiled, maximized, or fullscreen. |
| `xdg_popup` always floats and anchors | Protocol-owned | True xdg_popup anchoring is handled by River/compositor xdg-shell plumbing; Triad policy begins with managed `river_window_v1` windows. |
| Dialog/utility/small parented toplevel floats | Pass | Parented River windows float by default unless explicit rules or large primary-surface hints tile them. |
| Normal/large parented toplevel tiles | Pass | Large parented primary surfaces tile via River dimensions hints; window rules remain explicit overrides. |
| Unparented toplevels tile | Partial | Normal unparented windows tile; fixed-size unparented utility windows intentionally float. |
| Child centered on parent geometry | Pass | Floating children anchor to the parent's projected render rectangle. |
| Larger/wider child behavior | Pass | Wider children remain centered and clamped; screen-sized children shrink to screen. |
| Child stays in parent workspace/view | Pass | Parented children default to the parent workspace unless an explicit rule overrides it. |
| Scroller parent visibility | Pass | Focused-parent children use normal retargeting; background off-screen children defer focus instead of hijacking the camera. |
| Background child focus deferral | Pass | Parented floating children queue focus until the parent is render-visible. |
| Parent-matched viewport jump escape hatch | Pass | `window-rule dialog-viewport-jump #true` opts specific parent apps into immediate focus and viewport snap. |
| Hide popup when focus leaves popup tree | Pass | Only the active popup tree is projected. |
| Popup focus tree/history | Pass | Closing children and returning to a parent use popup-tree focus history. |
| Newer or recently focused popups cover older ones | Pass | Popup stacking follows descendant order, then focus/open history. |
| Deck background parent behavior | Pass | Deck projection uses the popup root as layout focus so the parent is visible first. |
| TGMix behavior | Pass | Popups anchor to the parent in both the tile-sized and grid-sized TGMix projections. |

---

## References

- **xdg-shell protocol** — defines `xdg_toplevel`, `xdg_popup`, and `set_parent`
  https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/stable/xdg-shell/xdg-shell.xml

- **xdg-dialog protocol** — explicit dialog hint for xdg-shell toplevels, removing size/type ambiguity
  https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/xdg-dialog/xdg-dialog.xml

- **river-layout v3 protocol** — layout protocol used by River 0.4+
  https://codeberg.org/river/river/src/branch/master/protocol/river-layout-v3.xml

- **river 0.4 release notes** — changelog covering protocol and compositor changes
  https://codeberg.org/river/river/releases

- **Extended Window Manager Hints (EWMH)** — `_NET_WM_WINDOW_TYPE` atoms including `DIALOG`, `UTILITY`, `NORMAL` (relevant for XWayland clients)
  https://specifications.freedesktop.org/wm-spec/latest/

- **Wayland protocol documentation** — reference for all core Wayland interfaces
  https://wayland.freedesktop.org/docs/html/
