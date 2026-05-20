# Notion layout conformance

Scope: **frame-tree layout engine** — persistent frame model, tab management, split/unsplit/focus/move/resize
commands against the original notion window manager (`~/src/notion`) and its Wayland adaptation
notion-river (`~/src/notion-river`).

Reference priority: notion-river is the primary behavioral reference for the Wayland context. Notion
proper is referenced for features notion-river retained in full. Features that notion-river itself
dropped (multi-tiling per workspace, Lua scripting, query menus, session management module, X11
window marks/tags bulk-attach) are explicitly out of scope here.

Explicit non-goals: Lua/Janet API parity (Janet serves the scripting role), notion's Mod_SM session
module, context-menu / query-command UI, X11-specific multi-head Xinerama handling, dock/statusbar
protocols, and any feature absent from both notion-river and the full notion that is also absent from
triad's design goals.

---

## Concept mapping

| Notion concept | Notion-river equivalent | Triad implementation | Notes |
|---|---|---|---|
| Frame (empty cell in split tree) | `Frame` struct (`layout.rs`) | `FrameData` (`src/types/model.nim:85`) | ✓ direct match |
| Split node (interior tree node) | `SplitNode::Split { orientation, ratio, children }` | `FrameData` with `kind = Split`, `firstChild`/`secondChild` | ✓ binary tree; triad is binary, notion-river is also binary |
| Tiling (the whole frame tree for a workspace) | `Workspace.root: SplitNode` (`workspace.rs`) | `Model.frameRootsByTag: Table[TagId, FrameId]` | ✓ one frame tree per tag/workspace |
| Tabs (multiple windows in one frame) | `Frame.windows: Vec<WindowRef>` | `Model.windowsByFrame: Table[FrameId, seq[WindowId]]` | ✓ ordered list of windows per leaf frame |
| Active tab | `Frame.active: Option<WindowId>` | `FrameData.activeWindow: WindowId` | ✓ |
| Split ratio (how space is divided) | `ratio: f64` (0.0–1.0, default `default_split_ratio` config) | `FrameData.ratio: float32` (hard-coded 0.5 on split creation) | ✗ no user command to adjust (see §Frame resize) |
| Empty frame | Frame with empty `windows` list, rendered as bordered outline | `FrameData` with `window == NullWindowId`, rendered via `frameEmptyChrome` | ✓ |
| Workspace multiplexing | `Workspace` (multiple per monitor, only one visible) | Tags (one per output at a time, switch via tag commands) | ✓ different naming, same semantics |
| Floating windows | Secondary floating windows auto-floated on admission | `isFloating` flag on `WindowData`; `toggle-floating` command | ✓ |
| App bindings (auto-place by app-id) | `AppBindings` (`app_bindings.rs`): maps app-id → frame location | `window-rule` admission-time placement (target tag/column, not frame) | ✗ no frame-specific placement (see §App bindings) |

---

## Commands and features

### Frame structure

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `SplitHorizontal` — split focused frame left–right | `frame-split-horizontal` → `splitFocusedFrame(Horizontal)` | ✓ | Active window stays in original; new empty sibling created |
| `SplitVertical` — split focused frame top–bottom | `frame-split-vertical` → `splitFocusedFrame(Vertical)` | ✓ | |
| `Unsplit` — remove focused empty frame, promote sibling | `frame-unsplit` → `unsplitFocusedFrame()` | ✓ | Succeeds only when the frame is empty |
| `ToggleSplit` — toggle split orientation H↔V on focused frame's parent | `frame-split-toggle` → `toggleFocusedFrameSplitOrientation` | ✓ |

### Tab navigation

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `FocusNextTab` — advance to next tab in focused frame | `frame-tab-next` → `focusFrameTab(1)` | ✓ | Wraps around |
| `FocusPrevTab` — step back to previous tab | `frame-tab-prev` → `focusFrameTab(-1)` | ✓ | Wraps around |
| Jump to tab by index (notion: `Meta+A/S/D/F` for tabs 0–3) | Not implemented | ✗ P2 | Not in notion-river either; original notion only |
| Tab reordering within frame (notion: `Meta+comma/period`) | Not implemented | ✗ P2 | Not in notion-river either |

### Frame focus

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `FocusDirection(left/right/up/down)` — move focus to adjacent frame | `focus-left/right/up/down` dispatches via `directionalTarget()` → frame target | ✓ | `moveFocusedWindowByDirection` handles both frame and window targets |
| `FocusParent` — shift focus to parent split level | `frame-focus-parent` / `frame-focus-child` → `focusFrameParent` / `focusFrameChild`; directional focus uses bounding rect of the parent's subtree and excludes its leaves from candidates | ✓ |

### Window movement

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `MoveDirection(left/right/up/down)` — move window to adjacent frame as a tab | `move-window-left/right/up/down` → `moveFocusedWindowByDirection` → `moveFocusedWindowToFrameTarget` | ✓ | Moves window to target frame; if target has a window, performs a mutual swap |
| `MoveToWorkspace(name)` — move window to named workspace | `move-to-workspace` / `move-window-to-workspace` | ✓ | Different naming, same semantics |
| Cross-monitor move (when no same-workspace neighbor) | Implicit via directional focus crossing output boundary | ✓ | Both notion-river and triad support this |
| Move to specifically chosen frame (not by direction) | No direct command; `group-windows` provides a form of this | ≈ | `group-windows` tabs the focused window and its neighbor into the same frame |

### Frame resize

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `EnterResizeMode` / `ExitResizeMode` | No modal resize state; resize commands bound directly | ≈ | Triad skips the mode layer; users bind `frame-resize-*` as regular keys |
| `Resize(direction)` — adjust split ratio 5% per step (notion-river) | `frame-resize-left/right/up/down` → `adjustFocusedFrameSplit`; optional delta arg, defaults to 5% | ✓ |
| Mouse drag to resize (original notion) | Not applicable (Wayland, no built-in mouse handling for this) | — | Notion-river also relies on keyboard-only resize |
| Frame split ratio at creation | `initial-split-ratio` config option under `layout { ... }` applies via `model.defaultFrameSplitRatio` | ✓ |

### Window and frame lifecycle

| Notion / notion-river | Triad command | Status | Notes |
|---|---|---|---|
| `Close` — close the focused window | `close-window` | ✓ | |
| `ToggleFullscreen` — fullscreen focused window | `toggle-fullscreen` | ✓ | |
| `ToggleFloat` — detach window from frame and float it | `toggle-floating` | ✓ | |
| Detach/reattach (float and return to original frame) | `toggle-floating` always; no frame memory on unfloat | ≈ | Notion: reattach returns window to the exact frame it left. Triad: unfloat returns to tag placement, may not land in the original frame |

### App bindings and auto-placement

| Notion / notion-river | Triad | Status | Notes |
|---|---|---|---|
| `BindApp` — bind focused window's app-id to current frame | `frame-bind-app` → `bindAppToFrame`; stores `appId → FrameId` in `TagData.frameAppBindings`; `addWindowToFrame` checks binding before defaulting to focused frame | ✓ |
| `ToggleBindApp` — add/remove additional frames for same app-id | `frame-unbind-app` → `unbindAppFromFrame`; rebind with `frame-bind-app` to change | ≈ toggle via bind+unbind, not a single toggle command |
| Wildcard app-id matching (`steam_app_*`) | Not implemented — exact app-id only | ✗ P2 | Notion-river: prefix wildcard matching; triad uses exact string keys |
| `window-rule` admission-time placement | Triad has `window-rule` targeting tags/columns | ≈ | Covers the "send app X to workspace Y" use case but not frame-specific targeting |

### Persistence and restore

| Feature | Notion-river | Triad | Status |
|---|---|---|---|
| Frame tree structure persistence | JSON via `state.rs`; restored on restart | `RestoredFrameData` in live-restore JSON | ✓ |
| Active tab per frame persistence | `Frame.active` saved to JSON | `FrameData.activeWindow` saved | ✓ |
| App binding persistence | `AppBindings` serialized | Not applicable (app bindings not implemented) | — |
| Per-monitor EDID workspace memory | `MonitorMemory` (`monitor_memory.rs`): saves last workspace per physical display | Output tracking by name (no EDID keying) | ≈ |

---

## Behavioral divergences

### Frame resize (P0)

**Notion-river:** Keyboard-driven modal resize. `EnterResizeMode` switches input mode; `Resize(dir)` calls `ws.root.resize_frame(frame_id, dir, delta)` adjusting the parent split node's ratio by 5% per key press. `ExitResizeMode` returns to normal mode. Frame ratios are mutable at runtime and persist to disk.

**Triad:** Frame split ratio is set to 0.5 at creation (`frame_ops.nim:316`: `model.frames.mEntity(split).ratio = 0.5'f32`) and never changed thereafter. There are no commands, IPC messages, or config options to adjust it. The ratio field exists in `FrameData` and is respected by the notion Janet layout's geometry computation, but nothing writes to it after initial split.

**Consequence:** A user who splits into three frames ends up with a fixed 25%/50%/25% column distribution (left frame gets half the first split, right two frames share the other half each at 50/50). There is no way to give one frame more screen real estate without unsplitting and re-splitting in a different order.

**Fix target (P0):** Add `adjustFocusedFrameRatio(model, orientation, delta)` in `src/entities/frame_ops.nim` mirroring the pattern from `adjustFocusedSplitTreeSplit` (`split_tree_ops.nim:840`). Walk ancestors of the focused frame for a split node whose orientation matches the requested direction; adjust ratio ± delta clamped to [0.05, 0.95]. Expose via new `CidFrameResizeLeft/Right/Up/Down` commands (or a single `CidFrameResize` with direction+delta payload). Wire in `update_commands.nim`.

### Reattach-to-original-frame on unfloat (≈)

**Notion:** When a window is detached (floated), notion records which frame it came from. Reattaching returns it to that exact frame regardless of what has changed in the layout since.

**Triad:** `toggle-floating` on an already-floating window re-admits the window to the tag's general pool. `syncTagFramesFromPlacement` distributes it to an available frame (the root frame or wherever the admission logic places it), not necessarily the frame the window was floated from. There is no "home frame" concept stored on `WindowData`.

---

## Gap remediation

### P0 — Behavioral completeness

1. ~~**Frame split ratio resize**~~ ✓ — `frame-resize-left/right/up/down` added;
   `adjustFocusedFrameSplit` walks the parent chain and clamp-adjusts the split ratio ±delta
   (default 5%, matching notion-river). `CidFrameResizeLeft/Right/Up/Down` wired through
   `ipc_commands.nim`, `runtime_messages.nim`, `ipc/commands.nim`, `update_commands.nim`.

### P1 — Missing useful features

2. ~~**App bindings**~~ ✓ — `frame-bind-app` / `frame-unbind-app` added. `TagData.frameAppBindings:
   Table[string, FrameId]` stores per-tag bindings, persisted in live-restore JSON as
   `frame_app_bindings`. `addWindowToFrame` checks bindings before falling back to focused frame.
   Stale frame IDs dropped silently on restore. Wildcard matching not implemented (exact app-id only).

3. ~~**`default_split_ratio` config option**~~ ✓ — `initial-split-ratio` KDL option parsed under
   `layout { ... }`, stored as `model.defaultFrameSplitRatio`, applied in `splitFocusedFrame`
   (previously hard-coded 0.5).

### P2 — Nice to have

4. ~~**`frame-split-toggle`**~~ ✓ — `CidFrameSplitToggle` → `toggleFocusedFrameSplitOrientation`
   in `frame_ops.nim`; reads focused leaf's parent split orientation and flips it.
   Mirrors `ToggleSplit` from notion-river (`toggle_orientation(frame_id)` on the parent split
   node). Cheap to add: new `CidFrameSplitToggle` that reads the parent's orientation and calls
   `splitFocusedFrame` with the opposite. No new data model needed.

5. ~~**`focus parent` for frame-tree**~~ ✓ — `CidFrameFocusParent` / `CidFrameFocusChild` added.
   `focusedParentFrame: FrameId` on `TagData` (cleared by `setTagFocus`). `frameNeighborTarget`
   uses the bounding rect of the parent's leaf descendants and excludes them from candidates.

6. **Tab reordering within frame** — move the active tab to an earlier or later position in the
   frame's window list. `windowsByFrame[frameId]` is a `seq[WindowId]`; reordering is a simple
   index swap. Notion provides `Meta+comma/period`; notion-river does not implement this. Low
   priority since users can unsplit and re-add in order.

### Won't do (dropped by notion-river; not aligned with triad's design goals)

- **Multiple tilings per workspace** — notion allows several independent split trees on one
  workspace simultaneously. Notion-river dropped this; triad's tag model has one frame tree per
  tag. No user pain reported.
- **Lua scripting** — notion's Lua configuration model. Triad uses Janet for the same purpose;
  API differences are not a conformance gap.
- **Query / menu system** — notion's interactive `Meta+J` command line, ssh/file queries.
  Not a WM layout concern; rofi/launcher integration serves this.
- **Tag-based bulk window attachment** — notion's `Meta+N` attach tagged objects. Not implemented
  in notion-river either.
- **Session management module** (`mod_sm`) — X11-specific; no Wayland equivalent needed.
