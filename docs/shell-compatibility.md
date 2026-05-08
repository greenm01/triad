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

The compatibility tests in `tests/tcompat.nim` encode this decision:

- Niri JSON requests return the fields Noctalia reads.
- Niri event streams start with full workspace/window/overview state.
- Basic Niri actions map to Triad messages.
- Triad text IPC remains Triad-native and does not claim to implement `mmsg`.
