# Shell Compatibility

Triad should not pretend to be Mango for Noctalia-shell by setting
`XDG_CURRENT_DESKTOP=mango`.

Noctalia's Mango backend uses Quickshell's DWL integration as its primary data
source: `DwlIpc.outputs`, per-output tags, layout symbols, and foreign-toplevel
handles. `mmsg` is an alternate control path for a few actions. Triad is a
River layout client, not the compositor, so it cannot expose those DWL Wayland
globals without work outside this repository.

For compatibility today, the viable path is a small Niri-compatible JSON IPC
facade on `$NIRI_SOCKET`. Noctalia's Niri backend reads workspaces, windows,
outputs, overview state, keyboard layouts, and dispatches a small set of actions
through that socket. Triad can supply that contract directly.

This is deliberately a compatibility layer, not Triad's native shell protocol.
Triad also exposes `$TRIAD_SOCKET`, a versioned native JSON IPC surface backed by
Triad's internal shell snapshot. Future deployers and Quickshell themes can hook
into that socket when they want Triad-native concepts such as stable tags,
compact workspace projection, per-tag layout modes, and native state events.
The Niri projection remains in place so existing shells work now while native
integrations can evolve without being constrained by Niri's model.

Triad advertises workspaces dynamically through this facade. The configured
`workspaces.default-count` creates the initial empty floor, and extra tags appear
when they are active or occupied by live windows. Once the last visible workspace
is occupied, Triad also advertises one trailing empty creation workspace.
Empty non-default tags are pruned after focus moves away, and stale output
ownership cannot keep them visible. The JSON `id` remains Triad's stable tag
ID, while `idx` is compacted in visible order so Niri-style bars do not show
holes or every configured tag template.

DankMaterialShell also reads `$NIRI_SOCKET` directly, but it additionally shells
out to `niri msg -j outputs`, `niri validate`, and selected `niri msg action`
commands. Triad ships `triad_niri` for that command-side contract. It is
deliberately not installed as `niri`, because users may have the real compositor
CLI installed.

When Triad starts Quickshell through the `quickshell` config block, it creates a
private runtime environment for that process:

- `$TRIAD_SOCKET` points at Triad's native shell IPC socket.
- `$NIRI_SOCKET` points at a Triad-owned Niri-compatible socket.
- `$XDG_RUNTIME_DIR/triad-compat-bin/niri` points at `triad_niri`.
- `$XDG_RUNTIME_DIR/triad-shell-compat/share` is prepended to `XDG_DATA_DIRS`
  for shell-only desktop entry and icon aliases.
- `PATH` is prefixed only for the spawned Quickshell process.
- `XDG_CURRENT_DESKTOP=triad`, so shells choose the Niri backend and do not
  accidentally select Mango/DWL behavior.

That keeps the real `niri` command untouched for the rest of the system.

Window `app_id` values in the Niri-compatible JSON are shell-facing identities,
not Triad's internal rule keys. Triad keeps the raw River app ID internally, but
maps exported Niri window IDs to desktop-entry-compatible IDs when it can, such
as `brave-origin-nightly.desktop`. Terminal emulators use unique Triad overlay
IDs such as `triad-foot` or `triad-kitty` instead of duplicate system IDs like
`foot.desktop`. This avoids shell-specific precedence rules when Quickshell sees
both the system desktop entry and Triad's runtime overlay. When a value is
mapped, Triad also emits `raw_app_id` as a debugging extension for clients that
ignore unknown fields.

For terminal icons, Triad also generates a private XDG overlay from installed
`.desktop` metadata. Entries advertising the freedesktop `TerminalEmulator`
category get shell-safe desktop/icon aliases in Triad's runtime directory, for
example `triad-foot.desktop` with `Icon=triad-foot`. This is data-driven from the
system desktop database; Triad does not special-case individual terminal apps
except for minimal unresolved app-id aliases.

Screenshot actions are implemented through `grim` and `slurp`:

- `Screenshot` captures an interactively selected region.
- `ScreenshotScreen` captures the primary output geometry known to Triad.
- `ScreenshotWindow` captures the focused window geometry known to Triad.
- Captures copy to the clipboard through `wl-copy --type image/png` by default.
- On disk-backed success Triad emits Niri's `ScreenshotCaptured` event with the
  output path, letting DMS open `satty`, `swappy`, or another configured
  editor.
- Clipboard-only captures emit `ScreenshotCaptured` without a path.

Output mutation commands such as `niri msg output DP-1 scale 1.25` are not
implemented. Triad refuses those rather than pretending to update compositor
monitor state it does not own.

Niri `Quit` actions are mapped to Triad session exit. A plain `Quit` opens
Triad's exit confirmation, while `Quit` with `skip_confirmation` exits
immediately through the same `allow-exit-session` guard used by native Triad
commands. This matches Noctalia-shell's session menu logout action.

The compatibility tests in `tests/tcompat.nim` encode this decision:

- Niri JSON requests return the fields Noctalia reads.
- Niri event streams start with full workspace/window/overview state.
- Basic Niri actions map to Triad messages.
- `triad_niri` translates the `niri msg -j outputs` and common action shapes
  that shell code runs.
- The private Quickshell environment includes Triad's XDG overlay.
- Triad text IPC remains Triad-native and does not claim to implement `mmsg`.
