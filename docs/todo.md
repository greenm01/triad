# Triad TODO

## DankMaterialShell Niri Compatibility

- [x] Implement Niri-compatible `MoveWorkspaceToIndex` so DMS workspace
  drag-reorder updates Triad's visible workspace order instead of being a
  no-op.
- [x] Decide the policy for DMS runtime output mutation
  (`niri msg output ... position|mode|vrr|scale|transform`). Triad cannot apply
  compositor monitor configuration without an output-management backend, so the
  Niri CLI shim now fails with a clear unsupported error.
- [x] Wire Niri-compatible monitor power actions to a real backend, or keep
  them explicitly documented and tested as unsupported/no-op until an output
  power protocol or configured command surface exists.
- [x] Expose configured XKB keyboard layout names and implement
  Niri-compatible `SwitchLayout` through River XKB layout switching.
- [x] Emit empty Niri cast state/events so DMS privacy indicators receive an
  explicit "no active casts" state, then replace it with real cast tracking if
  Triad later owns a screencast backend.

## Blocked / Watchlist

- Continue Mango-informed window-rule work only when the needed protocol,
  runtime state, render, or layout substrate exists. See
  `docs/comp/window-rules.md`.
- Keep overlay, global/sticky, and unmanaged-global behavior separate if Triad
  adds more Mango-like floating modes.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
