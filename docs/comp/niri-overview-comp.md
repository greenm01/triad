# Niri Overview Compatibility

This document tracks Triad's compatibility target for Niri-style overview
behavior. Triad now uses one workspace-preview overview model across layouts,
with scroller and vertical scroller preserving the closest Niri camera behavior.

## Baseline

The baseline for this audit is `~/src/niri` at commit `90366886`. Niri treats
overview as a zoomed compositor view of normal workspaces and windows, not as a
separate rearranged grid. Keyboard shortcuts remain active, pointer actions work
against the zoomed workspace stack, and camera/view offsets are ordinary
workspace state.

The Triad implementation target is the scroller overview behavior after
`780dfa6 Fix Niri-style scroller overview behavior`, with focused horizontal
and vertical scroller content centered in the overview camera and clipped to the
workspace preview area.

## Compatibility Matrix

Status values:

- `Compliant`: Triad matches the Niri behavior for the applicable overview path.
- `Partial`: Triad implements the core behavior, but known details differ.
- `Not Supported`: Triad has no equivalent input or runtime feature yet.
- `Intentional Difference`: Triad intentionally keeps a different behavior.

| Area | Expected Niri Behavior | Triad Status | Notes |
| --- | --- | --- | --- |
| Overview scope | Overview is a zoomed view of workspaces and windows, not a separate grid. | Compliant | All layouts use workspace previews. |
| Non-scroller fallback | Niri has one overview model. | Compliant | Triad no longer falls back to a Mango-style grid overview for non-scroller layouts. |
| Zoom default and clamp | Default zoom is `0.5`, clamped to `0.0001..0.75`. | Compliant | Triad config matches the Niri range and default. |
| Preview geometry | Workspace preview size is output size multiplied by overview zoom. | Compliant | Implemented in workspace-strip overview geometry. |
| Workspace gap | Workspace stack gap is output height multiplied by `0.1` and overview zoom. | Compliant | Matches Niri workspace stack spacing. |
| Active workspace position | Active workspace is centered and the stack moves by active workspace index. | Compliant | Triad previews derive from the active workspace slot. |
| Camera snapshot | Closing overview does not restore a saved camera snapshot. | Compliant | Triad leaves Niri-style camera changes intact. |
| Camera retarget | Focus changes in overview update workspace camera/view targets. | Compliant | Projection emits viewport targets while overview is open, and scroller overview rendering centers the focused column or row without mutating the saved viewport. |
| Right-drag camera pan | Right-drag pans the hovered workspace view offset. | Partial | Triad pans the preview; Niri-style inertial and snap settling are not fully modeled. |
| Wheel in overview | Unmodified vertical wheel switches workspaces, horizontal wheel focuses columns, and Shift+vertical focuses columns. | Compliant | Triad listens to raw `wl_pointer` wheel-axis events while overview is open and routes them through the unified overview navigation reducer. |
| Touchpad overview scroll | Two-finger overview scrolling maps vertical movement to workspaces and horizontal movement to view offset. | Not Supported | Triad has live 3-/4-finger `gesture-bind` swipes, but not Niri-style continuous two-finger overview scrolling. |
| Left-click window | Clicking a window activates that workspace/window and closes overview if it was not a drag. | Compliant | Covered by core overview regression tests. |
| Blank-click workspace | Clicking empty workspace area activates that workspace and closes overview. | Compliant | Covered by core overview regression tests. |
| Drag window release | Releasing a dragged window moves it without closing overview. | Compliant | Covered by core overview regression tests. |
| Hold-to-activate | Holding a dragged item over a workspace activates it and closes overview. | Partial | Behavior exists, but Triad timing is tick-based rather than Niri's 750 ms timer. |
| DnD edge workspace switch | Dragging near the top or bottom overview edge scrolls the workspace stack. | Not Supported | Future runtime/input feature. |
| Drop into new workspace or gap | Drag can create or move to a new workspace above, below, or between existing workspaces. | Partial | Dynamic gap targeting exists; add explicit regression coverage. |
| Keyboard shortcuts | Normal keyboard shortcuts continue to work while overview is open, with Escape/Return and arrow-key overview fallbacks. | Compliant | Triad keeps configured bindings active and adds overview fallback keys when the user has not bound those key slots. |
| Niri IPC workspace actions | `FocusWorkspace*` actions work while overview is open. | Compliant | Covered by compatibility tests. |
| Hot corner | Default top-left hot corner toggles overview. | Not Supported | Triad has no hot-corner input feature. |
| Multi-output overview | Niri renders and manages overview per output. | Partial | Triad remains primary-output oriented. |

## Implementation Notes

The unified overview should use Niri camera semantics. Opening overview may zoom
and reframe the visible previews, but it must not introduce a separate camera
state that is restored on close. Focus, pointer, drag, and IPC workspace changes
made while overview is open should retarget normal workspace camera state.

The main remaining gaps are input-surface gaps rather than layout math gaps:
continuous touchpad overview gestures, DnD edge scrolling, hot corner
activation, and multi-output parity.
