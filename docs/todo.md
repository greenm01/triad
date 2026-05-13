# Triad TODO

## Overview

- Add Niri-style overview drag-and-drop as future work. This needs overview
  hit-testing for the window or tag under the pointer, explicit drag target
  state in the model, movement of windows across columns and tags from the
  overview, and pointer scroll/hold behavior modeled after Niri.

## Runtime

- Add a future native IPC version that exposes Triad logical window and tag IDs
  explicitly while keeping the current Niri-compatible external ID projection
  stable for existing shells.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
