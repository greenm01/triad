# Live Testing Triad

This runbook is for the first manual test inside a real River session.

## Build

```bash
nimble verify
nimble build
```

`nimble verify` must pass before starting a live compositor test.

## Start In River

Run Triad from inside the River session and capture stderr:

```bash
TRIAD_LOG_LEVEL=debug ./triad 2>triad.log
```

For the scripted smoke check, run:

```bash
sh tools/live_smoke.sh
```

The script builds Triad, starts it in the current River-compatible session,
checks startup milestones, exercises Triad IPC plus the Niri shim, sends the
window workflow commands, reloads config, verifies `event-stream` broadcasts,
watches for fatal log patterns, and stops Triad before exiting. To also launch
one terminal client during the smoke window:

```bash
TRIAD_LIVE_LAUNCH_CLIENTS=1 sh tools/live_smoke.sh
```

If `lockme` is on `PATH`, the smoke script checks its required Wayland
protocols. To do a manual dev-mode lock/unlock pass:

```bash
TRIAD_LIVE_TEST_LOCKME=1 sh tools/live_smoke.sh
```

`lockme --dev-mode` acquires the session lock and exits when you press Esc.

For changes that should pass the daily-driver live gate, run:

```bash
TRIAD_DAILY_GATE_LIVE=1 nimble verify
nimble liveReload
```

`nimble liveReload` writes a native `triad-live-restore-v2` snapshot before it
installs binaries and stops the live manager. If that native snapshot cannot be
captured, the reload aborts rather than falling back to the Niri-compatible
state view, because that view cannot preserve camera offsets or full floating
geometry.

Expected startup milestones in `triad.log`:

- `Logging initialized`
- `Triad process starting`
- `Bound to river_window_manager_v1`
- `Triad connected to River`
- `Initial config loaded`
- `Initial manage completed`
- `Starting Triad IPC server`

Triad starts IPC only after River accepts the first manage pass. That makes live
reload readiness mean restored windows have been managed and decoration policy
has been re-applied, not just that a replacement process exists.

If `river_window_manager_v1` is not advertised, Triad exits with a fatal log.
That means it is not running in a compatible River 0.4+ session.

## Exercise IPC

From another terminal in the same session:

```bash
./triad msg focus-next
./triad msg layout-tile
./triad msg toggle-overview
./triad msg focus-shell-ui
./triad msg warp-pointer 100 100
./triad msg eat-next-key
./triad msg cancel-eat-next-key
./triad_niri msg -j workspaces
./triad_niri msg action focus-workspace 2
```

`triad msg event-stream` writes event data to stdout. Runtime logs stay on
stderr so they do not corrupt stream output.

## Exercise Quickshell Compatibility

When `quickshell { enabled #true }` is configured, Triad starts Quickshell with
a private Niri-compatible environment after the first River manage pass has
restored window/output state. During live reload, the exiting manager leaves its
tracked Quickshell process alive for the handoff; the replacement manager then
stops any stale instance of the configured theme and spawns the new one after
initial manage. To include that in live smoke:

```bash
TRIAD_LIVE_TEST_QUICKSHELL=1 ./tools/live_smoke.sh
```

The smoke gate verifies that Quickshell was spawned, that
`$XDG_RUNTIME_DIR/triad-compat-bin/niri` exists, and that the private shim can
query Triad through the shell-facing `$NIRI_SOCKET`. Triad also prepends
`$XDG_RUNTIME_DIR/triad-shell-compat/share` to Quickshell's `XDG_DATA_DIRS` so
shells can resolve Triad-provided desktop/icon aliases without changing the rest
of the user session.

DMS screenshot actions require `grim`, `slurp`, and `wl-copy`. `satty` or
`swappy` are opened by DMS after Triad emits the Niri-compatible
`ScreenshotCaptured` event for disk-backed captures.

## Exercise Windows

Launch and close a few clients:

```bash
alacritty &
foot &
firefox &
```

Expected log events include discovered windows, titles/app-ids, output
dimensions, IPC client connections, and closed windows. Debug logging may be
verbose; use `TRIAD_LOG_LEVEL=info` for normal sessions.

## Failure Signals

Treat these as hardening bugs to investigate:

- uncaught Nim exception or stack trace
- lost IPC socket without an error log
- window discovered without later layout/render activity
- command output mixed with log lines on stdout
- repeated subscriber failures without clients disconnecting cleanly
