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

## Triad layout model

Triad treats "layout" as a selected descriptor, not as a closed enum of every
geometry formula. The descriptor has three separate concerns:

- **Selection id**: the user-facing name in config, commands, IPC, and restore,
  such as `scroller`, `tile`, `grid`, `frame-tree`, or a user Janet name.
- **Kind**: the runtime behavior and state substrate required by that layout.
- **Source**: where the implementation comes from: core Nim, bundled Janet,
  user Janet, or native state systems.

The scroller is the core built-in fallback. Stateless geometric layouts should
move toward bundled or user Janet implementations. Native layouts are reserved
for layouts that require reducer-managed persistent state.

```nim
type LayoutKind* = enum
  lkAlgorithmic  ## stateless: fn(windows, rect) -> positions; Janet by default
  lkScrolling    ## infinite strip; owns scroll position state
  lkFrame        ## Triad owns persistent frame entities; routes focus through them
  lkBsp          ## Triad owns partition tree; Janet drives policy via thin API
  lkFloat        ## arbitrary positions; no layout algorithm
```

```nim
type LayoutSource* = enum
  lsCore          ## minimal non-script core; scroller is the guaranteed fallback
  lsBundledJanet  ## shipped standard formula layouts
  lsUserJanet     ## user-defined formula layouts
  lsNative        ## persistent native substrates such as frame-tree
```

## Layout index

| Layout | Algorithm | WM examples | Kind | Intended source |
|---|---|---|---|---|
| **scroller** | Infinite horizontal strip; windows scroll left/right; no fixed screen boundary | Mango, Niri, PaperWM | `lkScrolling` | `lsCore` |
| **vertical-scroller** | Scroller oriented vertically | Mango | `lkScrolling` | `lsCore` or bundled Janet-derived scrolling policy |
| **tile** (master-stack) | One master window takes a fixed portion; remaining windows stack on the other side | Mango, dwm, dwl, awesome, qtile, spectrwm | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-tile** | Master on top, stack fills the bottom; portrait orientation of tile | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **right-tile** | Master on right, stack on left; mirrored tile | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **center-tile** | Master centered; stack windows flank left and right | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **monocle** | Single window fills the screen; others hidden behind; cycle to navigate | Mango, dwm, xmonad, awesome | `lkAlgorithmic` | `lsBundledJanet` |
| **grid** | Windows arranged in equal-area grid cells; adapts to window count | Mango, awesome, qtile | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-grid** | Grid oriented vertically | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **deck** | Master window visible; remaining windows stacked behind it as layers | Mango, dwm (patch) | `lkAlgorithmic` | `lsBundledJanet` |
| **vertical-deck** | Deck oriented vertically | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **tgmix** | Tag-mixed hybrid; windows from multiple tags shown under one layout | Mango | `lkAlgorithmic` | `lsBundledJanet` |
| **dwindle** | Recursive alternating splits forming a spiral; BSP-shaped but stateless because it is re-applied on every window event | Mango, Hyprland | `lkAlgorithmic` | `lsBundledJanet` or `lsUserJanet` |
| **master** | Single master with configurable stack count; similar to tile | Hyprland | `lkAlgorithmic` | `lsBundledJanet` or `lsUserJanet` |
| **spiral** | Fibonacci-ratio recursive splits; each new window takes half the remaining space | xmonad, qtile | `lkAlgorithmic` | `lsBundledJanet` or `lsUserJanet` |
| **notion** | Janet geometry policy over Triad-owned persistent frames and tabs | Notion | `lkFrame` | `lsBundledJanet` with native `frame-tree` fallback |
| **frame-tree** | Persistent leaf frames hold tabs; split nodes divide space; empty frames survive | Notion, Ion, StumpWM | `lkFrame` | `lsNative` |
| **bsp** | Janet geometry policy over Triad-owned binary partition tree; new windows split the focused leaf automatically | bspwm, Hyprland | `lkBsp` | `lsBundledJanet` with native `bsp-tree` fallback |
| **bsp-tree** | Persistent binary partition tree; each leaf owns one tiled window; Triad owns insertion, directional focus, tree-order cycle, resize, balance/equalize, removal, restore, and fallback projection | bspwm | `lkBsp` | `lsNative` |
| **split h/v** | User-directed binary split; builds a tree of containers each with their own layout mode | i3, Sway, Herbstluftwm | `lkFrame` or `lkBsp` | future native substrate |
| **tabbed** | Windows stacked as tabs within a container; no spatial tiling | i3, Sway | `lkFrame` | `lsNative` substrate behavior |
| **stacked** | Windows stacked vertically with visible titlebars; no spatial tiling | i3, Sway | `lkFrame` | future native substrate behavior |
| **float** | Windows placed at arbitrary positions with no tiling constraint | Openbox, cwm, all WMs as escape hatch | `lkFloat` | window state, not a layout cycle member |

## Fallback policy

Fallback should preserve the state substrate whenever possible:

- `lkAlgorithmic` Janet failure falls back to `scroller`.
- `lkScrolling` falls back to `scroller`.
- `lkFrame` policy failure preserves frame state and uses native frame
  projection.
- `lkBsp` policy failure preserves the BSP tree and uses native `bsp-tree`
  projection.

Existing geometric built-in names such as `tile`, `grid`, `deck`, and
`monocle` should continue to work during migration, but their long-term home is
bundled Janet rather than new closed `LayoutMode` cases. This keeps ordinary
configs usable while shrinking the core built-in fallback surface to scroller.
