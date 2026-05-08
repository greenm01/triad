# Shell Compatibility

Triad should not pretend to be Mango for Noctalia-shell by setting
`XDG_CURRENT_DESKTOP=mango`.

Noctalia's Mango backend uses Quickshell's DWL integration as its primary data
source: `DwlIpc.outputs`, per-output tags, layout symbols, and foreign-toplevel
handles. `mmsg` is only a fallback/control path for a few actions. Triad is a
River layout client, not the compositor, so it cannot expose those DWL Wayland
globals without work outside this repository.

For a Triad-only compatibility layer, the viable path is a small Niri-compatible
JSON IPC facade on `$NIRI_SOCKET`. Noctalia's Niri backend reads workspaces,
windows, outputs, overview state, keyboard layouts, and dispatches a small set
of actions through that socket. Triad can supply that contract directly.

DankMaterialShell also reads `$NIRI_SOCKET` directly, but it additionally shells
out to `niri msg -j outputs`, `niri validate`, and selected `niri msg action`
commands. Triad ships `triad_niri` for that command-side contract. It is
deliberately not installed as `niri`, because users may have the real compositor
CLI installed.

When Triad starts Quickshell through the `quickshell` config block, it creates a
private runtime environment for that process:

- `$NIRI_SOCKET` points at a Triad-owned Niri-compatible socket.
- `$XDG_RUNTIME_DIR/triad-compat-bin/niri` points at `triad_niri`.
- `PATH` is prefixed only for the spawned Quickshell process.
- `XDG_CURRENT_DESKTOP=triad`, so shells choose the Niri backend and do not
  accidentally select Mango/DWL behavior.

That keeps the real `niri` command untouched for the rest of the system.

Screenshot actions are implemented through `grim` and `slurp`:

- `Screenshot` captures an interactively selected region.
- `ScreenshotScreen` captures the primary output geometry known to Triad.
- `ScreenshotWindow` captures the focused window geometry known to Triad.
- On success Triad emits Niri's `ScreenshotCaptured` event with the output path,
  letting DMS open `satty`, `swappy`, or another configured editor.

Output mutation commands such as `niri msg output DP-1 scale 1.25` are not
implemented. Triad refuses those rather than pretending to update compositor
monitor state it does not own.

The compatibility tests in `tests/tcompat.nim` encode this decision:

- Niri JSON requests return the fields Noctalia reads.
- Niri event streams start with full workspace/window/overview state.
- Basic Niri actions map to Triad messages.
- `triad_niri` translates the `niri msg -j outputs` and common action shapes
  that shell code runs.
- Triad text IPC remains Triad-native and does not claim to implement `mmsg`.
