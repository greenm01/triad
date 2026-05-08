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
out to `niri msg -j outputs` and `niri validate`. Triad ships an opt-in
`triad_niri` shim for that command-side contract. It is deliberately not
installed as `niri`, because users may have the real compositor CLI installed.
Expose it as `niri` only in the shell process environment:

```sh
mkdir -p "$XDG_RUNTIME_DIR/triad-compat-bin"
ln -sf "$(command -v triad_niri)" "$XDG_RUNTIME_DIR/triad-compat-bin/niri"
env PATH="$XDG_RUNTIME_DIR/triad-compat-bin:$PATH" qs -c dms
```

That keeps the real `niri` command untouched for the rest of the system.

The compatibility tests in `tests/tcompat.nim` encode this decision:

- Niri JSON requests return the fields Noctalia reads.
- Niri event streams start with full workspace/window/overview state.
- Basic Niri actions map to Triad messages.
- `triad_niri` translates the `niri msg -j outputs` and common action shapes
  that shell code runs.
- Triad text IPC remains Triad-native and does not claim to implement `mmsg`.
