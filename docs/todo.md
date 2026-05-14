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
- Continue Mango-informed window-rule work only when the needed substrate
  exists. Terminal swallowing is implemented as `terminal`/`allow-swallow`;
  sticky/global workspace placement is implemented as
  `open-on-all-workspaces`; managed overlay is implemented as `open-overlay`;
  unmanaged global windows are implemented as `open-unmanaged-global`; named
  app scratchpad rules are implemented as `open-named-scratchpad`; idle inhibit
  is implemented as `idle-inhibit`. Remaining gaps are blocked or deferred by
  missing protocol/data/render/layout support: true output serial matching,
  urgency, cast targets, per-window scroll factor, global keybinding policy,
  visual effects, tabbed display, and render-target blocking.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
