# Tiling window manager categories

This document uses existing window-manager families as vocabulary. They are
not Triad's runtime model. Triad organizes layouts by selected id, runtime
kind, and source so that persistent state stays native while stateless geometry
can live in Janet.

| Category | Description | Who places windows | Examples | Tabbed? |
|---|---|---|---|---|
| **Dynamic** | A layout algorithm is selected; the WM automatically places all windows into it. Windows reflow when others open or close. Layouts (master-stack, grid, monocle, spiral) are predefined and switched as a whole. | The algorithm, on every window event | dwm, xmonad, awesome, qtile, spectrwm, Mango | Partial — awesome has tab layouts; most others don't |
| **Manual / Tree** | The user explicitly splits space, building a binary tree of containers. No algorithm decides placement. Each node in the tree can have its own layout mode (split, tabbed, stacked). Empty containers don't persist. | The user, at split time | i3, Sway, Herbstluftwm | Yes — per-container tab/stack mode |
| **BSP** | Binary Space Partitioning. Each new window bisects the currently focused region geometrically. Splitting is automatic at insertion time, with optional commands to resize, balance, or equalize the tree later. | Geometry, at insertion time | bspwm, Hyprland | No — Hyprland has window groups as a partial exception |
| **Frame-based / Static** | Persistent named containers (frames) exist independently of their contents. The user builds the frame layout in advance; windows are placed into frames which can hold multiple windows as tabs. Frames persist even when empty. | The user builds structure in advance; windows fill it | Notion, Ion, StumpWM | Yes — core feature; frames are inherently tab containers |
| **Scrollable / Strip** | Windows are arranged on a continuously scrollable horizontal strip rather than confined to the screen boundary. Navigation is spatial scrolling rather than workspace switching. No layout algorithm; windows are placed sequentially. | Sequential insertion; user scrolls to navigate | Niri, PaperWM, Cardboard | No — windows are discrete strip nodes |

## Layout index

| Layout | Triad | Algorithm | WM examples | Kind | Intended source |
|---|---|---|---|---|---|
| **scroller** | Yes | Infinite horizontal strip; windows scroll left/right; no fixed screen boundary | Mango, Niri, PaperWM | `lkScrolling` | `lsCore` |
| **vertical-scroller** | Yes | Scroller oriented vertically | Mango | `lkScrolling` | `lsCore` |
| **tile** (master-stack) | Yes | One master window takes a fixed portion; remaining windows stack on the other side | Mango, dwm, dwl, awesome, qtile, spectrwm | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-tile** | Yes | Master on top, stack fills the bottom; portrait orientation of tile | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **right-tile** | Yes | Master on right, stack on left; mirrored tile | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **center-tile** | Yes | Master centered; stack windows flank left and right | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **monocle** | Yes | Single window fills the screen; others hidden behind; cycle to navigate | Mango, dwm, xmonad, awesome | `lkAlgorithmic` | `lsBundledJanet` |
| **grid** | Yes | Windows arranged in equal-area grid cells; adapts to window count | Mango, awesome, qtile | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-grid** | Yes | Grid oriented vertically | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **deck** | Yes | Master window visible; remaining windows stacked behind it as layers | Mango, dwm (patch) | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-deck** | Yes | Deck oriented vertically | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **tgmix** | Yes | Tag-mixed hybrid; windows from multiple tags shown under one layout | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **dwindle** | Yes | Focused-window insertion into a persistent binary split tree; new leaves split the target container and produce spiral-like tiling | Mango, Hyprland | `lkBsp` | `lsBundledJanet` with native `bsp-tree` fallback |
| **master** | Yes | Single master with configurable stack count; similar to tile | Hyprland | `lkAlgorithmic` | `lsBundledJanet` or `lsUserJanet` |
| **spiral** | Yes | qtile-style configurable recursive splits; each new window takes a ratio of the remaining space | xmonad, qtile | `lkAlgorithmic` | `lsBundledJanet` |
| **notion** | Yes | Janet geometry policy over Triad-owned persistent frames and tabs | Notion | `lkFrame` | `lsBundledJanet` with native `frame-tree` fallback |
| **frame-tree** | Yes | Persistent leaf frames hold tabs; split nodes divide space; empty frames survive | Notion, Ion, StumpWM | `lkFrame` | `lsNative` |
| **bsp** | Yes | Janet geometry policy over Triad-owned binary partition tree; new windows split the focused leaf automatically | bspwm, Hyprland | `lkBsp` | `lsBundledJanet` with native `bsp-tree` fallback |
| **bsp-tree** | Yes | Persistent binary partition tree; each leaf owns one tiled window; Triad owns insertion, preselection, directional focus, tree-order cycle, resize, balance/equalize, removal, restore, and fallback projection | bspwm | `lkBsp` | `lsNative` |
| **split h/v** | Yes | User-directed split containers; `splith` divides children left-to-right and `splitv` divides children top-to-bottom | i3, Sway, Herbstluftwm | `lkSplitTree` | `lsNative` |
| **i3** | Yes | Persistent i3/Sway-style container tree; Triad owns split commands, insertion, focus, movement, resize, flattening, removal, restore, and native fallback projection | i3, Sway | `lkSplitTree` | `lsNative` |
| **tabbed** | Yes | Windows stacked as tabs within a split-tree container; no spatial tiling inside that container | i3, Sway | `lkSplitTree` | native `i3` mode |
| **stacked** | Yes | Windows stacked vertically with visible titlebars inside a split-tree container | i3, Sway | `lkSplitTree` | native `i3` mode |
| **float** | Yes | Windows placed at arbitrary positions with no tiling constraint | Openbox, cwm, all WMs as escape hatch | `lkFloat` | window state, not a layout cycle member |

`Triad` means functional coverage, not necessarily an exact layout id. For
example, `master` is covered by `tile`, `tabbed` and `stacked` are i3 modes,
and `float` is window state rather than a layout-cycle member.

## Triad layout model

Triad treats "layout" as a selected descriptor, not as a closed enum of every
geometry formula. The descriptor has three separate concerns:

- **Selection id**: the user-facing name in config, commands, IPC, and restore,
  such as `scroller`, `tile`, `grid`, `frame-tree`, or a user Janet name.
- **Kind**: the runtime behavior and state substrate required by that layout.
- **Source**: where the implementation comes from: core Nim, bundled Janet,
  user Janet, or native state systems.

The scroller is the core built-in fallback. Stateless geometric layouts live in
bundled or user Janet implementations. Native layouts are reserved for layouts
that require reducer-managed persistent state.

```nim
type LayoutKind* = enum
  lkAlgorithmic  ## stateless: fn(windows, rect) -> positions; Janet by default
  lkScrolling    ## infinite strip; owns scroll position state
  lkFrame        ## Triad owns persistent frame entities; routes focus through them
  lkBsp          ## Triad owns partition tree; Janet drives policy via thin API
  lkSplitTree    ## Triad owns i3/Sway-style split containers; Janet may project geometry
  lkFloat        ## arbitrary positions; no layout algorithm
```

```nim
type LayoutSource* = enum
  lsCore          ## minimal non-script core; scroller is the guaranteed fallback
  lsBundledJanet  ## shipped standard formula layouts
  lsUserJanet     ## user-defined formula layouts
  lsNative        ## persistent native substrates such as frame-tree
```

## Fallback policy

Fallback should preserve the state substrate whenever possible:

- `lkAlgorithmic` Janet failure falls back to `scroller`.
- `lkScrolling` falls back to `scroller`.
- `lkFrame` policy failure preserves frame state and uses native frame
  projection.
- `lkBsp` policy failure preserves the BSP tree and uses native `bsp-tree`
  projection.
- `lkSplitTree` policy failure preserves the split container tree and uses
  native `i3` projection.

Existing geometric built-in names such as `tile`, `grid`, `deck`, and
`monocle` continue to work as bundled Janet layout ids. Runtime snapshots expose
the selected layout through `layoutId`; the stored `layoutMode` for these
layouts is the safe fallback (`scroller`). This keeps ordinary configs usable
while shrinking the core built-in surface to scroller and vertical scroller.
