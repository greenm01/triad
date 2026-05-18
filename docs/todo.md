# Triad TODO

## Visible Frame Tabs For frame-tree plan

- Follow-ups: empty-frame chrome, drag/drop between frames,
  app-to-frame targeting, and existing `group-windows` command behavior.

## BSP layout follow-ups

- Add focused split resize controls for native `bsp-tree`.
- Add focused window/node swap controls for native `bsp-tree`.

## Blocked / Watchlist

- Janet follow-ups: user-facing custom layout selection, custom layout config,
  and additional prelude helpers as real scripts need them.
- Continue Mango-informed window-rule work only when the needed protocol,
  runtime state, render, or layout substrate exists. See
  `docs/comp/window-rules.md`.
- Keep overlay, global/sticky, and unmanaged-global behavior separate if Triad
  adds more Mango-like floating modes.
- Revisit target-viewport layout projection only if compositor-owned animation
  or another projection consumer needs final-position coordinates.
