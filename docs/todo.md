# Triad TODO

## Overview

- Add cyclic overview hidden-window count badges for Deck, Vertical Deck, and
  Monocle.
- Add open-axis scroll indicators for Scroller and Vertical Scroller workspace
  previews.

## Runtime

- (done) Native Triad IPC action surface completed. Logical IDs remain
  internal; external IDs are the stable public projection.
- Add future multi-workspace window-rule placement backed by the DOD tag mask
  model, while keeping public config workspace-oriented.
- Evaluate Mango-informed window-rule gaps for Triad-native equivalents:
  sticky/global windows, unmanaged-global windows, overlay windows, named app
  scratchpad rules, terminal swallowing, per-window tearing/performance policy,
  and layout-family size hints.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
