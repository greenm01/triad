# Tiling window manager categories

| Category | Description | Who places windows | Examples | Tabbed? |
|---|---|---|---|---|
| **Dynamic** | A layout algorithm is selected; the WM automatically places all windows into it. Windows reflow when others open or close. Layouts (master-stack, grid, monocle, spiral) are predefined and switched as a whole. | The algorithm, on every window event | dwm, xmonad, awesome, qtile, spectrwm, Mango | Partial — awesome has tab layouts; most others don't |
| **Manual / Tree** | The user explicitly splits space, building a binary tree of containers. No algorithm decides placement. Each node in the tree can have its own layout mode (split, tabbed, stacked). Empty containers don't persist. | The user, at split time | i3, Sway, Herbstluftwm | Yes — per-container tab/stack mode |
| **BSP** | Binary Space Partitioning. Each new window bisects the currently focused region geometrically. Splitting is automatic at insertion time. The tree is balanced by area rather than directed by the user. | Geometry, at insertion time | bspwm, Hyprland | No — Hyprland has window groups as a partial exception |
| **Frame-based / Static** | Persistent named containers (frames) exist independently of their contents. The user builds the frame layout in advance; windows are placed into frames which can hold multiple windows as tabs. Frames persist even when empty. | The user builds structure in advance; windows fill it | Notion, Ion, StumpWM | Yes — core feature; frames are inherently tab containers |
| **Scrollable / Strip** | Windows are arranged on a continuously scrollable horizontal strip rather than confined to the screen boundary. Navigation is spatial scrolling rather than workspace switching. No layout algorithm; windows are placed sequentially. | Sequential insertion; user scrolls to navigate | Niri, PaperWM, Cardboard | No — windows are discrete strip nodes |

## Layout index

| Layout | Algorithm | WM examples | `LayoutKind` |
|---|---|---|---|
| **tile** (master-stack) | One master window takes a fixed portion; remaining windows stack on the other side | Mango, dwm, dwl, awesome, qtile, spectrwm | `lkAlgorithmic` |
| **vertical_tile** | Master on top, stack fills the bottom; portrait orientation of tile | Mango | `lkAlgorithmic` |
| **right_tile** | Master on right, stack on left; mirrored tile | Mango | `lkAlgorithmic` |
| **center_tile** | Master centered; stack windows flank left and right | Mango | `lkAlgorithmic` |
| **monocle** | Single window fills the screen; others hidden behind; cycle to navigate | Mango, dwm, xmonad, awesome | `lkAlgorithmic` |
| **grid** | Windows arranged in equal-area grid cells; adapts to window count | Mango, awesome, qtile | `lkAlgorithmic` |
| **vertical_grid** | Grid oriented vertically | Mango | `lkAlgorithmic` |
| **deck** | Master window visible; remaining windows stacked behind it as layers | Mango, dwm (patch) | `lkAlgorithmic` |
| **vertical_deck** | Deck oriented vertically | Mango | `lkAlgorithmic` |
| **tgmix** | Tag-mixed hybrid; windows from multiple tags shown under one layout | Mango | `lkAlgorithmic` |
| **dwindle** | Recursive alternating splits forming a spiral; BSP-shaped but stateless — re-applied on every window event | Mango, Hyprland | `lkAlgorithmic` |
| **master** | Single master with configurable stack count; similar to tile | Hyprland | `lkAlgorithmic` |
| **spiral** | Fibonacci-ratio recursive splits; each new window takes half the remaining space | xmonad, qtile | `lkAlgorithmic` |
| **split h/v** | User-directed binary split; builds a tree of containers each with their own layout mode | i3, Sway, Herbstluftwm | `lkAlgorithmic` |
| **tabbed** | Windows stacked as tabs within a container; no spatial tiling | i3, Sway | `lkAlgorithmic` |
| **stacked** | Windows stacked vertically with visible titlebars; no spatial tiling | i3, Sway | `lkAlgorithmic` |
| **scroller** | Infinite horizontal strip; windows scroll left/right; no fixed screen boundary | Mango, Niri, PaperWM | `lkScrolling` |
| **vertical_scroller** | Scroller oriented vertically | Mango | `lkScrolling` |
| **BSP** | Persistent binary partition tree; each split node independently addressable and adjustable; Nim owns the tree | bspwm | `lkBsp` |
| **frames/tabs** | Persistent named containers holding tabbed windows; containers exist independent of contents | Notion, Ion, StumpWM | `lkFrame` |
| **float** | Windows placed at arbitrary positions with no tiling constraint | Openbox, cwm, all WMs as escape hatch | `lkFloat` |

## Triad `LayoutKind` enum

```nim
type LayoutKind* = enum
  lkAlgorithmic  ## stateless: fn(windows, rect) → positions; Janet or built-in
  lkScrolling    ## infinite strip; owns scroll position state
  lkFrame        ## Triad owns persistent frame entities; routes focus through them
  lkBsp          ## Triad owns partition tree; Janet drives policy via thin API
  lkFloat        ## arbitrary positions; no layout algorithm
```
