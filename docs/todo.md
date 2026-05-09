# Triad TODO

## Overview

- Add Niri-style overview drag-and-drop as future work. This needs overview
  hit-testing for the window or tag under the pointer, explicit drag target
  state in the model, movement of windows across columns and tags from the
  overview, and pointer scroll/hold behavior modeled after Niri.

## DOD Migration

- Add a future native IPC version that exposes Triad logical window and tag IDs
  explicitly while keeping the current Niri-compatible external ID projection
  stable for existing shells.

- After the adapter-first DOD migration proves parity for snapshots, layouts,
  restore, focus history, and IPC, do the deferred big-bang cleanup pass:
  remove the legacy nested tag/column/window storage, delete compatibility
  adapters, and enforce the `types`/`state`/`entities`/`systems` boundaries
  across the runtime.
