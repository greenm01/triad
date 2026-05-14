# Window Rules and Layout Applicability

This document tracks Triad's window-rule direction as a hybrid model. Niri is
the primary reference for rule semantics: ordered matching, open-time behavior,
and per-window rule effects. Mango is a secondary reference for the rule
families that niri does not cover well because niri has one scrolling layout,
while Triad has multiple layout families.

This is not a Mango compatibility target. Mango names are used here only to
identify gaps and layout-policy questions.

Sources:

- Niri documentation:
  https://niri-wm.github.io/niri/Configuration%3A-Window-Rules.html
- Niri source:
  `/home/niltempus/src/niri/niri-config/src/window_rule.rs` and
  `/home/niltempus/src/niri/src/window/mod.rs`
- Mango source:
  `/home/niltempus/src/mango/docs/window-management/rules.md`,
  `/home/niltempus/src/mango/src/mango.c`, and
  `/home/niltempus/src/mango/src/config/parse_config.h`
- Triad source:
  `src/config/parser.nim`, `src/types/runtime_values.nim`,
  `src/state/engine.nim`, and `docs/configuration.md`

Status legend:

- `Pass`: Triad has an equivalent user-facing rule or behavior.
- `Partial`: Triad covers part of the behavior, but the interface or semantics
  differ.
- `Gap`: Triad has no equivalent user-facing rule or behavior.
- `N/A`: Not a Triad target or not meaningful for Triad's current model.

## Hybrid Model

Triad should use niri-style rule semantics as the default design:

- Rules are data that resolve into one window intent before placement.
- Broad app rules and specific title rules should compose in order.
- Public config should use workspace language; runtime state compiles placement
  into tag IDs and tag masks.
- Rule matching and target placement should be layout-agnostic.

Mango fills in the design questions that niri does not answer:

- Which rule categories make sense outside a scrolling layout.
- Which window states are global policy, floating policy, scratchpad policy, or
  layout-family policy.
- Which concepts must stay separate, such as floating, sticky/global,
  unmanaged-global, and overlay.

## Layout Applicability

| Layout family | Triad layouts | Niri-covered rules | Mango-informed gaps | Triad decision |
| :--- | :--- | :--- | :--- | :--- |
| Scroller | `Scroller`, `VerticalScroller` | Matching, workspace placement, open focus, floating, fullscreen, size hints | `scroller_proportion`, `scroller_proportion_single` | Scroller-specific proportion rules belong only here unless Triad defines a layout-neutral size hint. |
| Master-stack | `MasterStack`, `CenterTile`, `RightTile`, `VerticalTile` | Matching, workspace placement, open focus, floating, fullscreen | Master count/ratio interactions, fake maximize, tiled-state hints | Treat as layout policy; do not copy Mango parameters directly. |
| Grid | `Grid`, `VerticalGrid` | Matching, workspace placement, open focus, floating, fullscreen | Cell sizing and forced tiled-state behavior | Rules can choose initial state; grid projection owns cell sizing. |
| Deck | `Deck`, `VerticalDeck` | Matching, workspace placement, open focus, floating, fullscreen | Dialog focus while parent is behind deck, hidden-window policy | Keep parented dialog focus conservative unless explicitly overridden. |
| Monocle | `Monocle` | Matching, workspace placement, open focus, floating, fullscreen | Fake fullscreen and tiled size hints | Tiled size/position hints are mostly irrelevant; floating/dialog/fullscreen rules still apply. |
| Hybrid | `TGMix` | Matching, workspace placement, open focus, floating, fullscreen | Tile-zone vs grid-zone sizing | Follow Triad layout policy per zone; rules should not encode zone-specific Mango parameters. |

Universal rules apply to all layout families: app/title matching, workspace/tag
placement, open focus, floating state, fullscreen state, parented dialog policy,
and shortcut-inhibit policy. Floating geometry applies in every layout only
when the window is floating; the anchoring and visibility policy differs by
layout family.

## Niri Compliance Matrix

| Category | Niri rule/matcher | Niri behavior | Triad surface | Status | Notes |
| :--- | :--- | :--- | :--- | :---: | :--- |
| Matching | `match app-id` | Match app id by regex | `match app-id=...` | Pass | Regex search semantics; anchor patterns for exact matching. |
| Matching | `match title` | Match title by regex | `match title=...` | Pass | Regex search semantics; anchor patterns for exact matching. |
| Matching | Multiple `match` entries | Rule applies if any `match` child matches | repeat `match` children | Pass | Fields inside one matcher are AND-ed; matchers are OR-ed. |
| Matching | `exclude` | Skip a rule when any exclude matcher matches | repeat `exclude` children | Pass | Uses the same app/title matcher shape as `match`. |
| Matching | `is-active` | Match active window state | `match is-active=#true/#false` | Pass | Matches the focused window of any workspace the window belongs to. |
| Matching | `is-focused` | Match focused state | `match is-focused=#true/#false` | Pass | Matches Triad's single active-focus window; layer-shell exclusive focus makes this false. |
| Matching | `is-active-in-column` | Match active-in-column state | `match is-active-in-column=#true/#false` | Partial | Triad derives one visible tiled candidate per column from workspace focus or the first visible admitted window; it does not yet persist last-focused-per-column history. |
| Matching | `is-floating` | Match current floating state | `match is-floating=#true/#false` | Pass | Initial/opening rule evaluation treats unmapped windows as non-floating to avoid a cycle with `open-floating`; dynamic fields refresh after state changes. |
| Matching | `is-window-cast-target` | Match window cast target state | | Gap | |
| Matching | `is-urgent` | Match urgent state | | Gap | |
| Matching | `at-startup` | Match only startup or non-startup windows | | Gap | |
| Opening | `default-column-width` | Set initial column width | `default-column-width { proportion ... }` | Pass | Rule-level value overrides the global layout default for newly created columns. |
| Opening | `default-window-height` | Set initial tiled window height | `default-window-height { proportion ... }` | Pass | Triad also supports rule-level `default-window-width`. |
| Opening | `open-on-output` | Open matching window on a named output | `open-on-output "<name>"` | Partial | Targets the workspace currently visible on that output; it does not move workspaces between outputs. |
| Opening | `open-on-workspace` | Open matching window on a named workspace | `default-workspace <n>` | Pass | Triad uses numeric workspace slots. |
| Opening | `open-maximized` | Open matching window maximized | `open-maximized #true/#false` | Pass | Maps to full-width column in scroller layouts, not client-visible maximize. |
| Opening | `open-maximized-to-edges` | Open matching window maximized to edges | `open-maximized-to-edges #true/#false` | Pass | Uses Triad's client-visible maximized state. |
| Opening | `open-fullscreen` | Open matching window fullscreen | `open-fullscreen #true/#false` | Pass | Fullscreen wins over other opening presentation states. |
| Opening | `open-floating` | Force matching window to open floating or tiled | `open-floating #true/#false` | Pass | Explicit `#false` can override parented dialog floating defaults. |
| Opening | `open-focused` | Allow or prevent initial focus | `open-focused #true/#false` | Pass | |
| Opening | `default-column-display` | Set normal or tabbed column display | | Gap | Triad has no tabbed-column display mode. |
| Opening | `default-floating-position` | Set initial floating position relative to an edge or corner | `default-floating-position x=<px> y=<px> relative-to="<anchor>"` | Pass | Supports Niri-style corner and single-edge anchors; existing ratio placement remains a fallback. |
| Dynamic | `min-width` | Override effective minimum width | `min-width <px>` | Pass | Rule bounds constrain geometry but do not change tiled/floating placement. |
| Dynamic | `min-height` | Override effective minimum height | `min-height <px>` | Pass | Rule bounds are re-evaluated on metadata, hint, and config changes. |
| Dynamic | `max-width` | Override effective maximum width | `max-width <px>` | Pass | `0` clears a broader matching rule's bound. |
| Dynamic | `max-height` | Override effective maximum height | `max-height <px>` | Pass | Nonzero max below min normalizes to min. |
| Dynamic | `variable-refresh-rate` | Opt matching windows into VRR policy | `presentation-mode` | Gap | Triad has global presentation mode, not per-window VRR. |
| Dynamic | `scroll-factor` | Override scroll factor per window | | Gap | |
| Dynamic | `tiled-state` | Control client-visible tiled state | `tiled-state #true/#false` | Pass | Sends River tiled edges as a client hint only; it does not change Triad placement. |
| Visual | `focus-ring` | Override focus ring appearance | `layout.border` | Gap | Triad border/focus colors are global. |
| Visual | `border` | Override border appearance | `layout.border` | Gap | Triad border config is global. |
| Visual | `shadow` | Override shadow appearance | | Gap | |
| Visual | `tab-indicator` | Override tab indicator appearance | | N/A | Triad has no tabbed-column display mode. |
| Visual | `draw-border-with-background` | Draw border with background | | Gap | |
| Visual | `opacity` | Override window opacity | | Gap | |
| Visual | `geometry-corner-radius` | Override assumed corner radius | | Gap | |
| Visual | `clip-to-geometry` | Clip rendering to geometry | | Gap | |
| Visual | `baba-is-float` | Apply niri's floating visual effect | | N/A | Not a Triad target. |
| Visual | `block-out-from` | Block window from selected render targets | | Gap | |
| Visual | `background-effect` | Configure background blur/effects | | Gap | |
| Popups | `popups { opacity }` | Override popup opacity | | Gap | Triad has popup policy, not popup visual rules. |
| Popups | `popups { geometry-corner-radius }` | Override popup corner radius | | Gap | |
| Popups | `popups { background-effect }` | Configure popup background effects | | Gap | |

## Mango Gap Coverage

Mango window-rule fields are grouped here by the Triad capability they suggest.
These are gap-analysis categories, not target config names.

| Mango rule family | Examples | Triad status | Layout note |
| :--- | :--- | :---: | :--- |
| Placement and focus | `tags`, `monitor`, `isopensilent`, `istagsilent` | Partial | Workspace placement and open focus exist; monitor placement and tag-silent semantics are gaps. |
| Floating geometry | `isfloating`, `width`, `height`, `offsetx`, `offsety`, `no_force_center`, `isnosizehint` | Partial | Triad supports open floating, ratio sizing, fixed pixel sizing, and anchored pixel position; no-center policy and size-hint bypass are gaps. |
| Scroller proportion | `scroller_proportion`, `scroller_proportion_single` | Gap | Applies only to scroller layouts unless generalized into Triad size hints. |
| Fullscreen and maximize policy | `isfullscreen`, `isfakefullscreen`, `force_fakemaximize`, `ignore_maximize`, `noopenmaximized`, `force_tiled_state` | Partial | Triad has runtime fullscreen/maximize commands but few rule-level equivalents. |
| Visual/decor policy | `noblur`, `isnoborder`, `isnoshadow`, `isnoradius`, opacity, animation flags | Gap | Mostly compositor/render policy; Triad has global border and animation config. |
| Scratch/global/overlay | `isglobal`, `isoverlay`, `isunglobal`, `isnamedscratchpad`, `single_scratchpad` | Gap | Keep these as separate concepts; do not collapse into floating. |
| Terminal swallowing | `isterm`, `noswallow` | Gap | Not part of current Triad lifecycle policy. |
| Performance and input policy | `allow_shortcuts_inhibit`, `indleinhibit_when_focus`, `force_tearing`, `globalkeybinding` | Partial | Shortcut inhibit exists; per-window idle, tearing, and global keybinding policy are gaps. |

## Triad-Specific Notes

- Rule matching uses regex search semantics. All matching rules are merged in
  order, so broad app rules can provide defaults and later title-specific rules
  can override individual fields. Invalid regex patterns reject strict config
  reloads instead of silently changing policy.
- Parented dialog behavior is policy-driven. Parented windows float by default,
  adopt the parent workspace unless an explicit `default-workspace` overrides
  it, and anchor to the parent's projected geometry.
- Window policy is centralized: rules provide declarative defaults, fixed-size
  and parented-window heuristics provide conservative built-ins, and IPC/scripts
  remain the escape hatch for conditional behavior.
- `parented-role "dialog"|"tool"|"plain"` is a Triad-specific rule that
  separates transient dialogs from persistent parented floats.
- `dialog-viewport-jump` is a Triad-specific opt-in for parented dialogs that
  should retarget the viewport immediately.
- `keyboard-shortcuts-inhibit` is a Triad-specific rule for shortcut inhibit
  policy, paired with the runtime `toggle-keyboard-shortcuts-inhibit` command.
- `tiled-state` controls the client-visible River tiled hint. It does not move
  a window between Triad's tiled and floating placement.
- `forced-layout` is a Triad-specific rule that can select the workspace layout
  used for a matching new window.
- `default-window-width` is a Triad-specific companion to niri's
  `default-window-height`; it controls the initial stored window width
  proportion.
- Rule-level size bounds are dynamic geometry constraints. They intentionally do
  not participate in Triad's fixed-size floating heuristic; that heuristic
  still uses raw client hints.
- Opening presentation states force tiled placement if they conflict with
  `open-floating`. Fullscreen takes precedence over edge maximize, which takes
  precedence over full-width column.
- Fixed-size unparented windows can open floating by policy, similar to niri's
  fixed-height floating default.
- `default-floating-position` controls initial position for unparented,
  `tool`, and `plain` floats and for later toggle-to-floating placement.
  Parented `dialog` windows keep parent-relative placement.
- Lead floating startup windows are handled by Triad policy: a focused
  unparented floating lead window can anchor the first same-app unparented
  normal window without inventing a parent relationship.
