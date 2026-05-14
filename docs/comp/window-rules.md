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
| Matching | `is-active-in-column` | Match active-in-column state | `match is-active-in-column=#true/#false` | Pass | Triad records the last focused tiled window per column and falls back to the first visible admitted window when history is missing or stale. |
| Matching | `is-floating` | Match current floating state | `match is-floating=#true/#false` | Pass | Initial/opening rule evaluation treats unmapped windows as non-floating to avoid a cycle with `open-floating`; dynamic fields refresh after state changes. |
| Matching | `is-window-cast-target` | Match window cast target state | | Gap | |
| Matching | `is-urgent` | Match urgent state | | Gap | |
| Matching | `at-startup` | Match only startup or non-startup windows | `match at-startup=#true/#false` | Pass | Triad follows niri's broad startup phase: true for the first 60 seconds of a daemon process, then dynamic rule effects are recomputed. |
| Opening | `default-column-width` | Set initial column width | `default-column-width { proportion ... }` | Pass | Rule-level value overrides the global layout default for newly created columns. |
| Opening | Scroller initial column proportion | Mango-specific scroller sizing | `scroller-proportion { proportion ... }` | Pass | Scroller-only rule; overrides `default-column-width` for matching newly created columns. |
| Opening | Scroller single-column proportion | Mango-specific one-column scroller sizing | `scroller-single-proportion { proportion ... }` | Pass | Applies only when `Scroller` or `VerticalScroller` has one tiled column; ignored by multi-column scrollers and non-scroller layouts. |
| Opening | `default-window-height` | Set initial tiled window height | `default-window-height { proportion ... }` | Pass | Triad also supports rule-level `default-window-width`. |
| Opening | `open-on-output` | Open matching window on a named output | `open-on-output "<name>"` | Partial | Targets the workspace currently visible on that output. Matches connector names, shell fallback names, niri-style make/model/serial strings with unknown serials, and raw Wayland descriptions. True serial matching remains a gap. |
| Opening | `open-on-workspace` | Open matching window on a named workspace | `default-workspace <n>` | Pass | Triad uses numeric workspace slots. |
| Opening | Multi-workspace placement | Mango-style multi-tag opening placement | `default-workspaces <n>...` | Pass | Triad places one window on multiple workspace tags using normal per-tag placement rows. The first target is the primary snapshot/focus target. |
| Opening | Sticky/global workspace placement | Mango-style global window placement | `open-on-all-workspaces #true/#false` | Pass | Matching top-level windows are marked sticky and synced to every materialized workspace. Sticky-only occupancy does not pin dynamic workspaces; scratchpad clears sticky state. Parented dialogs/tools ignore sticky unless `parented-role "plain"` is set. |
| Opening | Managed overlay stacking | Mango-style overlay/top-layer placement | `open-overlay #true/#false` | Pass | Matching managed windows stay above normal managed windows without becoming floating, sticky, scratchpad, or unmanaged. Focused overlays preserve backing fullscreen/maximized presentation. |
| Opening | `open-maximized` | Open matching window maximized | `open-maximized #true/#false` | Pass | Maps to full-width column in scroller layouts, not client-visible maximize. |
| Opening | `open-maximized-to-edges` | Open matching window maximized to edges | `open-maximized-to-edges #true/#false` | Pass | Uses Triad's client-visible maximized state. |
| Opening | `open-fullscreen` | Open matching window fullscreen | `open-fullscreen #true/#false` | Pass | Fullscreen wins over other opening presentation states. |
| Opening | `open-floating` | Force matching window to open floating or tiled | `open-floating #true/#false` | Pass | Explicit `#false` can override parented dialog floating defaults. |
| Opening | `open-focused` | Allow or prevent initial focus | `open-focused #true/#false` | Pass | |
| Opening | Named scratchpad | Open matching window hidden in a named scratchpad | `open-named-scratchpad "<name>"` | Pass | Triad-specific opening rule. Restore state takes precedence; config reload does not move existing windows. |
| Opening | `default-column-display` | Set normal or tabbed column display | | Gap | Triad has no tabbed-column display mode. |
| Opening | `default-floating-position` | Set initial floating position relative to an edge or corner | `default-floating-position x=<px> y=<px> relative-to="<anchor>"` | Pass | Supports Niri-style corner and single-edge anchors; existing ratio placement remains a fallback. |
| Dynamic | `min-width` | Override effective minimum width | `min-width <px>` | Pass | Rule bounds constrain geometry but do not change tiled/floating placement. |
| Dynamic | `min-height` | Override effective minimum height | `min-height <px>` | Pass | Rule bounds are re-evaluated on metadata, hint, and config changes. |
| Dynamic | `max-width` | Override effective maximum width | `max-width <px>` | Pass | `0` clears a broader matching rule's bound. |
| Dynamic | `max-height` | Override effective maximum height | `max-height <px>` | Pass | Nonzero max below min normalizes to min. |
| Dynamic | Maximize request policy | Mango-style fake or ignored maximize | `maximize-policy "edge"|"column"|"ignore"` | Pass | Applies to maximize actions after open; opening presentation rules remain separate. |
| Dynamic | `variable-refresh-rate` | Opt matching windows into VRR policy | `presentation-mode "default"|"vsync"|"async"` | Partial | Triad lets a focused matching window request River output presentation mode, falling back to the global `presentation-mode`. River exposes output-level policy, not true per-surface VRR. |
| Dynamic | Idle inhibit | Prevent compositor idle while matching windows matter | `idle-inhibit "none"|"focused"|"visible"` | Pass | Uses `zwp_idle_inhibit_manager_v1` when available. `focused` follows active focus or active scratchpad; `visible` follows non-minimized matching windows on output-visible workspaces or active scratchpad. Disabled while locked or while exclusive layer focus is active. |
| Dynamic | `scroll-factor` | Override scroll factor per window | | Gap | |
| Dynamic | `tiled-state` | Control client-visible tiled state | `tiled-state #true/#false` | Pass | Sends River tiled edges as a client hint only; it does not change Triad placement. |
| Visual | `focus-ring` | Override focus ring appearance | `focus-ring { width; active-color }` | Partial | Triad maps focus ring to a focused-only override of River borders. It is not a separate render layer. |
| Visual | `border` | Override border appearance | `border { width; active-color; inactive-color }` | Partial | Triad supports per-window River borders with width and active/inactive colors. Gradients, urgent color, and background drawing remain gaps. |
| Visual | `shadow` | Override shadow appearance | | Gap | |
| Visual | `tab-indicator` | Override tab indicator appearance | | N/A | Triad has no tabbed-column display mode. |
| Visual | `draw-border-with-background` | Draw border with background | | Gap | |
| Visual | `opacity` | Override window opacity | | Gap | |
| Visual | `geometry-corner-radius` | Override assumed corner radius | | Gap | |
| Visual | `clip-to-geometry` | Clip rendering to geometry | `clip-to-geometry #true/#false` | Pass | Uses River clip boxes around Triad's rendered geometry. This does not change placement or sizing. |
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
| Placement and focus | `tags`, `monitor`, `isopensilent`, `istagsilent` | Partial | Single and multi-workspace placement, open focus, name-based output placement, and make/model output identity matching exist; tag-silent semantics and true serial matching remain gaps. |
| Floating geometry | `isfloating`, `width`, `height`, `offsetx`, `offsety`, `no_force_center`, `isnosizehint` | Pass | Triad supports open floating, ratio sizing, fixed pixel sizing, anchored pixel position, opt-in centering, and rule-level client size-hint policy. |
| Scroller proportion | `scroller_proportion`, `scroller_proportion_single` | Pass | `scroller-proportion` sets new scroller column primary-axis size; `scroller-single-proportion` centers a one-column scroller without changing multi-column behavior. |
| Fullscreen and maximize policy | `isfullscreen`, `isfakefullscreen`, `force_fakemaximize`, `ignore_maximize`, `noopenmaximized`, `force_tiled_state` | Pass | Opening fullscreen/maximize rules, `maximize-policy`, and `tiled-state` cover Triad's chosen model. Fake maximize maps to full-width scroller columns. |
| Visual/decor policy | `noblur`, `isnoborder`, `isnoshadow`, `isnoradius`, opacity, animation flags | Partial | Rule-level border, focused-only focus-ring width/colors, and clip-to-geometry exist; shadows, blur, radius, opacity, and per-window animation policy remain gaps. |
| Scratch/global/overlay | `isglobal`, `isoverlay`, `isunglobal`, `isnamedscratchpad`, `single_scratchpad` | Pass | Named scratchpad opening, sticky workspace placement, managed overlay stacking, and unmanaged-global windows exist as separate concepts; do not collapse them into floating. |
| Terminal swallowing | `isterm`, `noswallow` | Pass | Implemented as explicit `terminal` and `allow-swallow` rules. Swallowing requires a terminal host PID and a new child PID that descends from it; missing PID data never guesses. |
| Performance and input policy | `allow_shortcuts_inhibit`, `indleinhibit_when_focus`, `force_tearing`, `globalkeybinding` | Partial | Shortcut inhibit, idle inhibit, and focused-window `presentation-mode` exist. Global keybinding policy remains a gap. |

## Remaining Gap Triage

This table is the working priority list for future window-rule work. It keeps
blocked compositor/protocol features separate from Triad-native features that
can be implemented with the current runtime model.

| Priority | Gap | Classification | Decision |
| :---: | :--- | :--- | :--- |
| P3 | True output serial matching | Protocol/data blocked | Current output identity stores connector name, make/model, and description. Keep `open-on-output` partial until serial data is available. |
| P3 | Urgent matcher: `is-urgent` | Protocol/data blocked | Native Triad and niri-compatible state currently report urgency as false. Implement only after Triad has a real urgent-window signal. |
| P3 | Cast-target matcher: `is-window-cast-target` | Protocol/data blocked | No current state or protocol source identifies cast targets. |
| P3 | Per-window `scroll-factor` | Protocol-shape blocked | River exposes input-device scroll factor, not a current per-window rule primitive in Triad. Revisit only with a clear input policy design. |
| P3 | Global keybinding policy | Design/protocol needed | Keep separate from shortcut inhibit. Needs a model for app-scoped global shortcuts before adding rules. |
| P4 | Opacity, shadow, blur, radius, background effects, popup visual effects | Protocol/render blocked | River/Triad currently expose borders, decorations, clips, and protocol surfaces, not compositor scene effects for managed windows. |
| P4 | Tabbed column display and tab indicator | Out of scope | Do not add rule fields without a real tabbed-column layout model. |
| P4 | Render-target blocking: `block-out-from` | Out of scope | Screenshot/cast target filtering is not part of the current render model. |

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
- `open-on-all-workspaces` is a Triad-specific sticky-window rule. It is
  intentionally distinct from `default-workspaces`: sticky windows follow
  future materialized workspaces, do not make every workspace occupied for
  dynamic pruning, and lose sticky state when moved to scratchpad.
- `open-overlay` is a managed stacking rule. It does not imply floating,
  sticky, scratchpad, unmanaged-global, or layer-shell behavior; it only keeps
  matching windows above normal managed windows and preserves backing
  fullscreen/maximized presentation while focused.
- `open-unmanaged-global` is an unmanaged-like global rule for desktop pets,
  camera previews, and similar windows. Triad keeps the surface River-managed,
  but excludes it from workspace placement, focus traversal, overview previews,
  and dynamic workspace occupancy while rendering it globally above normal
  managed windows. It does not imply sticky, overlay, scratchpad, or layer-shell
  behavior.
- `dialog-viewport-jump` is a Triad-specific opt-in for parented dialogs that
  should retarget the viewport immediately.
- `keyboard-shortcuts-inhibit` is a Triad-specific rule for shortcut inhibit
  policy, paired with the runtime `toggle-keyboard-shortcuts-inhibit` command.
- `idle-inhibit` is a Triad-specific power policy. Use `"focused"` for media
  and games that should inhibit idle only while focused, and `"visible"` for
  monitoring or playback windows that should inhibit idle while visible on any
  output workspace.
- `presentation-mode` is a focused-window performance policy. It maps matching
  focused windows to River output presentation mode and falls back to the
  global top-level setting when no focused rule applies.
- Rule-level `border` controls the River compositor border for matching
  windows. `width 0` is Triad's simple disable path; Niri-style `on`/`off`
  flags, gradients, urgent colors, and background border drawing are not
  implemented.
- Rule-level `focus-ring` is implemented as a focused-state border override
  because River exposes one compositor border primitive to Triad. It can be
  combined with `border { width 0 }` for active-only rings.
- `clip-to-geometry` maps to River clip boxes around Triad's rendered geometry.
  It is render-only and cannot disable required safety clipping for oversized
  or offscreen cells.
- `tiled-state` controls the client-visible River tiled hint. It does not move
  a window between Triad's tiled and floating placement.
- `respect-size-hints` is a Triad-style positive name for Mango's
  `isnosizehint` capability. `#false` ignores client-provided min, max, and
  fixed-size hints while preserving explicit Triad rule bounds.
- `center-floating` is Triad's opt-in equivalent for Mango's floating
  center-placement behavior. `default-floating-position` remains the more
  specific placement rule and wins when both match.
- `maximize-policy` controls maximize actions after the window exists. `edge`
  keeps the client-visible maximized model, `column` maps maximize to
  full-width scroller columns, and `ignore` refuses maximize-on requests.
- `forced-layout` is a Triad-specific rule that can select the workspace layout
  used for a matching new window.
- `terminal #true` and `allow-swallow #false` are Triad's explicit swallowing
  controls. Triad intentionally does not infer terminal status from desktop
  metadata in v1; a child can be swallowed only when the compositor reports a
  PID and that PID descends from the eligible terminal host PID.
- `open-named-scratchpad` is a Triad-specific opening rule for tools that
  should be available through `toggle-named-scratchpad` without first occupying
  a workspace. It is intentionally opening-only, and live restore wins.
- `open-on-output` is intentionally silent when paired with
  `default-workspace` or `default-workspaces`: it can make a non-primary output
  show the primary target workspace, but it will not switch the active
  workspace or remap parented child windows. Output targets match connector,
  shell fallback, make/model/`Unknown` serial, and raw description strings.
- `default-workspaces` is Triad's workspace-oriented form of Mango-style
  multi-tag placement. It is opening-only; config reload does not move existing
  windows. The first listed workspace remains the canonical snapshot position.
- `default-window-width` is a Triad-specific companion to niri's
  `default-window-height`; it controls the initial stored window width
  proportion.
- `scroller-proportion` and `scroller-single-proportion` are Mango-informed
  Triad names. They are intentionally scoped to `Scroller` and
  `VerticalScroller`; other layouts preserve the stored column value but do not
  consume it.
- Rule-level size bounds are dynamic geometry constraints. They intentionally do
  not participate in Triad's fixed-size floating heuristic. That heuristic uses
  raw client hints only when `respect-size-hints` is enabled.
- Opening presentation states force tiled placement if they conflict with
  `open-floating`. Fullscreen takes precedence over edge maximize, which takes
  precedence over full-width column.
- Fixed-size unparented windows can open floating by policy, similar to niri's
  fixed-height floating default, unless a matching rule disables
  `respect-size-hints`.
- `default-floating-position` controls initial position for unparented,
  `tool`, and `plain` floats and for later toggle-to-floating placement.
  Parented `dialog` windows keep parent-relative placement. `center-floating`
  fills the gap between the default floating ratios and explicit anchored
  placement.
- Lead floating startup windows are handled by Triad policy: a focused
  unparented floating lead window can anchor the first same-app unparented
  normal window without inventing a parent relationship.
