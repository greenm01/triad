# Triad TODO

## Overview

- Add cyclic overview hidden-window count badges for Deck, Vertical Deck, and
  Monocle.
- Add open-axis scroll indicators for Scroller and Vertical Scroller workspace
  previews.

## Runtime

- (done) Native Triad IPC action surface completed. Logical IDs remain
  internal; external IDs are the stable public projection.
- (done) Add multi-workspace window-rule placement backed by the DOD tag mask
  model, while keeping public config workspace-oriented.
- Continue Mango-informed window-rule work in priority order:
  P1 terminal swallowing (`isterm`/`noswallow`), P2 unmanaged-global design,
  P3 protocol-dependent gaps such as true output serial matching, urgency,
  cast targets, per-window scroll factor, and global keybinding policy, then
  P4 deferred visual/tabbed/render-target features. Sticky/global workspace
  placement is implemented as `open-on-all-workspaces`; managed overlay is
  implemented as `open-overlay`; named app scratchpad rules are implemented as
  `open-named-scratchpad`; idle inhibit is implemented as `idle-inhibit`.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
