# Triad TODO

## Runtime

- (done) Native Triad IPC action surface completed. Logical IDs remain
  internal; external IDs are the stable public projection.
- If Triad exposes Mango-like floating modes, keep overlay, global/sticky, and
  unmanaged-global behavior separate instead of collapsing them into one flag.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
