# Triad TODO

## Overview

- Add cyclic overview hidden-window count badges for Deck, Vertical Deck, and
  Monocle.
- Add open-axis scroll indicators for Scroller and Vertical Scroller workspace
  previews.

## Runtime

- (done) Native Triad IPC action surface completed. Logical IDs remain
  internal; external IDs are the stable public projection.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
