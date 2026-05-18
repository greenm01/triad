# Janet Layouts

This document is a design plan for making Triad flexible enough that users can
define their own layouts. Janet layouts are an additive extension point. The
existing 12 built-in layouts remain unchanged.

## Goal

Triad should let a user define a named layout in Janet without recompiling
Triad, while preserving the current runtime guarantees:

- built-in layout behavior stays stable;
- layout scripts receive immutable projection input;
- layout scripts return data, not side effects;
- model mutation remains inside `Model.update(msg)` and native state systems;
- invalid script output falls back to a safe built-in layout.

The first useful version should support pure geometry layouts: formulas that
read the current workspace projection and return window rectangles.

## Non-Goals

- Do not replace or reinterpret the 12 built-in `LayoutMode` values.
- Do not let Janet mutate `Model`, entity tables, placement indexes, or River
  objects directly.
- Do not hide persistent layout state inside the Janet interpreter.
- Do not require custom layouts for normal Triad operation.
- Do not use Janet to render shell UI, tab bars, empty-frame indicators, or
  client content.

## Current Layout Boundary

Triad currently stores built-in layout choice as `LayoutMode` on each tag. The
projection layer turns a `ProjectedTag`, projected windows, screen geometry,
and gap settings into `RenderInstruction` records. That boundary is the right
shape for Janet layouts because it already treats layout as data in and data
out.

The built-ins should continue to use the existing enum-driven path:

- `Scroller`
- `VerticalScroller`
- `MasterStack`
- `Grid`
- `Monocle`
- `Deck`
- `CenterTile`
- `RightTile`
- `VerticalTile`
- `VerticalGrid`
- `VerticalDeck`
- `TGMix`

Custom layouts should be selected by a separate custom-layout id, not by adding
unbounded user names to `LayoutMode`. This keeps restore, IPC compatibility,
Niri-shaped shell projections, config parsing, and existing layout commands
predictable.

## Additive Layout Selection

Triad has an additive selection layer that can represent either a built-in
layout or a custom layout:

```text
LayoutSelection =
  builtin LayoutMode
  custom  JanetLayoutId + fallback LayoutSelection
  native  NativeLayoutId + fallback LayoutMode
```

- existing commands such as `layout-grid` keep targeting built-ins;
- `layout-custom <name>` selects a declared custom layout;
- `layout-native <name>` selects a native substrate-backed layout;
- layout cycles can include built-ins, declared custom names, and native layout
  ids;
- snapshots expose both the effective layout id and whether it is built-in or
  custom/native;
- restoring an unknown custom layout falls back to the tag's configured safe
  built-in or native fallback layout.

This avoids destabilizing every consumer that already assumes `LayoutMode` is a
small closed set.

## Janet Layout ABI

A Janet layout function should be a pure function from projection data to
placement data. A v1 shape can be:

```janet
(triad/def-layout :my-layout
  (fn [ctx]
    # return a tuple/array of instruction structs
    [{:window-id 10 :x 0 :y 0 :w 960 :h 1080}
     {:window-id 11 :x 960 :y 0 :w 960 :h 1080}]))
```

The input context should include:

- screen rect and usable workspace rect;
- outer and inner gaps after smart-gap policy;
- focused window id;
- active tag id, tag name, and layout state useful to scripts;
- projected columns and their ordered window ids;
- projected windows keyed or listed by id with app id, title, size hints,
  proportions, floating/fullscreen/maximized/minimized flags, and parent id;
- optional projected frame data when a native frame substrate is active;
- optional projected groups once group-aware layout scripts need them.

The return value should be a sequence of placement instructions:

- `:window-id` must refer to a tiled projected window visible to the layout;
- `:x`, `:y`, `:w`, and `:h` are required logical-pixel coordinates;
- optional clip fields can be added after the base geometry path is proven;
- omitted tiled windows should be treated as invalid output for v1.

Janet layout functions should not emit Triad commands. Event scripts can still
use `triad/command`; layout functions are a separate pure projection ABI.

## Validation And Fallback

Triad must validate every custom layout result before applying it. Invalid
results should not partially apply.

Reject and fall back when:

- the script is missing, disabled, or fails to load;
- evaluation exceeds the Janet fuel budget;
- the return value is not a sequence of instruction structs;
- an instruction references an unknown, floating, minimized, unmanaged, or
  duplicate window;
- an instruction has non-positive dimensions;
- required tiled windows are missing;
- coordinates overflow practical `int32` geometry.

The fallback should be a configured safe layout, defaulting to `Scroller`.
Native fallbacks such as `frame-tree` may render native substrate state when the
custom script fails. Behavior logs should record the custom layout id, failure
reason, window count, instruction count, duration, and fallback layout.

## Native Frame/Tab Substrate

Frame/tab state is useful, but it should be native Triad state rather than
Janet-owned interpreter state.

A native frame/tab substrate would help several layout families:

- Notion/Ion-style static split trees;
- tabbed columns, including Mango-like `default-column-display` follow-ups;
- BSP and other manual split layouts;
- IDE-style persistent panes with app targeting;
- deck-per-frame layouts;
- frame-aware Janet layouts that only provide geometry policy.

It is not required for simple formula layouts such as grids, spirals,
monocle-like stacks, or basic master-stack variants.

Triad's native `frame-tree` layout provides this substrate. Its frame tree fills
the output usable rect, applies `layout.gaps` only between split frames, insets
occupied clients below the tab strip and configured border, and renders native
chrome for visible tabs plus empty frames. It follows the existing DOD split:

- frame and tab records live in `types/model.nim`;
- indexes and persistence live in `state` and `entities`;
- split, unsplit, tab focus, directional frame focus, and window-to-frame
  movement are reducer commands;
- projection receives immutable frame data and emits render instructions;
- Janet can observe frame projection data and optionally calculate frame
  geometry, but cannot directly mutate frames.

## notion-river Feasibility Notes

`~/src/notion-river` is a useful reference because it separates the easy part
from the hard part.

The easy part is the recursive split geometry: given a split tree, a screen
rect, and a gap, calculate a rect for each leaf frame. That is scriptable and
is shipped as the bundled `notion` Janet layout, with
`examples/janet/layouts/notion.janet` kept as an editable reference.

The hard part is that notion-river's layout is not only a geometry formula. Its
core model includes:

- persistent empty frames;
- windows stored inside frames as tabs;
- active tab per frame;
- focused frame independent from focused window;
- split and unsplit commands;
- ratio resizing by keyboard and pointer;
- app/frame targeting;
- state save and restore;
- visible empty-frame and tab decorations.

A faithful Notion-style Triad mode therefore uses native frame/tab state for
behavior. Janet helps with custom frame geometry or placement policy only.

## Implementation Phases

### Phase 1: Pure Custom Geometry

- Add an internal custom layout registry backed by Janet scripts via
  `triad/def-layout`.
- Add an internal layout evaluation path beside the built-in projection path;
  do not wire it into config, IPC, `LayoutMode`, or normal layout selection.
- Accept only stateless projection input and validated render instructions.
- Keep all built-ins and their commands unchanged.
- Add behavior-log evidence for success, fallback, and timing.

Phase 1 is complete when tests can evaluate a named Janet layout directly and
observe either validated instructions or a typed fallback result. It is not
complete user-facing layout selection; that belongs to Phase 2.

### Phase 2: Configuration And IPC

Implemented.

- Config supports `janet { layout "<name>" fallback="<builtin>" }`.
- `layout-cycle`, `workspaces default-layout`, and
  `workspace-rules default-layout=...` accept declared custom names.
- `layout-custom <name>` selects a custom layout for the active workspace.
- `set-layout-for-workspace <tag> <layout>` accepts built-in ids or custom
  names.
- Native IPC `request:"set-layout"` accepts declared custom names and exposes
  `layout`, `layout_kind`, and `fallback_layout` in layout snapshots.
- The active normal workspace evaluates custom Janet geometry; overview and
  Niri-compatible projections keep using the safe built-in fallback.
- Live restore persists custom selection and clears unknown custom names on
  restore/config reload.

### Phase 3: Native Frame/Tab Substrate

Initial implementation is in place.

- Add native frame/tab records, indexes, reducer commands, and projection
  structs.
- Implement `frame-tree` as the first native frame-aware layout to prove the
  substrate.
- Support native layout selection through config layout selections, IPC,
  `layout-native`, and layout snapshots without adding a 13th `LayoutMode`.
- Add frame reducer commands for split, unsplit, next tab, and previous tab.
- Expose immutable projected frame data to Janet layout functions.
- Allow custom Janet layouts to declare `fallback="frame-tree"` so native
  frame/tab state survives invalid or missing script output.
- Persist native frame topology, active tabs, focused frame, and native layout
  selection through live restore.

### Phase 4: Frame-Aware Janet Layouts

Implemented.

- Janet functions can calculate frame rects or window rects from native frame
  projection data.
- Frame-aware scripts may return `:frame-id` instructions; Triad maps each leaf
  frame rect to that frame's active visible tab.
- Frame-aware evaluation retains all returned frame instructions, including
  empty frames, so native tab and empty-frame chrome can be rendered from the
  script's full frame geometry rather than only occupied windows.
- Frame mutation remains in native commands.
- A 25-frame Janet evaluation test records behavior-log evidence for substrate,
  target kind, frame count, and instruction count.

## Testing And Acceptance Criteria

- Built-in layout tests pass unchanged.
- Existing config, IPC, restore, overview, and layout-cycle behavior for the 12
  built-ins is unchanged.
- A valid custom Janet layout can place all tiled windows on the active tag.
- Invalid custom output falls back without partially applying placement.
- Missing scripts and fuel exhaustion produce behavior-log evidence.
- Layout evaluation stays within an acceptable frame budget at 20+ tiled
  windows.
- Live reload keeps the selected built-in or custom layout stable, or falls
  back with explicit diagnostics when the custom layout disappears.
