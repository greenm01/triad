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
- Add Mango-style per-window geometry escape hatches for rules that need
  explicit floating size, offset, or no-force-center behavior. Keep names
  Triad/Niri-style instead of copying Mango's state-shaped option names.

## Layouts

- Implement TGMix as a hybrid master/grid layout. When it lands, add
  child-window policy tests for parented dialogs anchored in both the master
  zone and the grid zone.
