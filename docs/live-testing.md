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
installs binaries and sends `triad-reload` to the live manager. The replacement
manager rewrites that same snapshot with `restore_status: "applied"` after
River accepts the restore manage pass, so the file remains available for
postmortem debugging without being replayed on the next start. If that native
snapshot cannot be captured, the reload aborts rather than falling back to the
Niri-compatible state view, because that view cannot preserve camera offsets or
full floating geometry.

`nimble liveReload` also writes a one-shot runtime marker so the replacement
daemon starts in dev mode and behavior JSONL logging is available immediately
after the reload. A direct `triad-reload` command, including the default
`Ctrl+Alt+r` binding, only preserves dev mode when the running daemon was
already in dev mode.

Compact behavior JSONL logs are off by default for normal sessions. Enable
them for a focused investigation with `triad --dev-mode`, `TRIAD_DEV_MODE=1`,
or `TRIAD_BEHAVIOR_LOG=1`. They are written outside the repository under
`${XDG_STATE_HOME:-$HOME/.local/state}/triad/behavior`, roll daily, cap each
day at 5 MiB, and keep seven days. `TRIAD_BEHAVIOR_LOG=0` disables behavior
logs even when dev mode is enabled. Override `TRIAD_BEHAVIOR_LOG_DIR`,
`TRIAD_BEHAVIOR_LOG_MAX_BYTES`, and `TRIAD_BEHAVIOR_LOG_KEEP_DAYS` to redirect
or tune the log files. Runtime update logs keep compact summaries and tracked
windows instead of full before/after window lists. Repeated identical layout
projection logs are suppressed and reported on the next emitted projection with
`suppressed_count`. A `memory_trim` event is emitted when Triad trims allocator
memory after a destructive close burst.

For an already-running session, use `triad msg dev-mode on`,
`triad msg dev-mode off`, `triad msg dev-mode toggle`, or
`triad msg dev-mode status`. The live `off` command disables both
`TRIAD_DEV_MODE` and behavior JSONL logging for the current daemon process.

Expected startup milestones in `triad.log`:

- `Logging initialized`
- `Triad process starting`
- `Bound to river_window_manager_v1`
- `Initial config loaded`
- `Triad connected to River`
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

When `shells { enabled #true }` is configured, Triad starts the active shell
profile with a private Niri-compatible environment when that profile has
`niri-compat #true`. Startup still waits until the first River manage pass has
restored window/output state. During live reload, the exiting manager leaves its
tracked shell process alive for the handoff; the replacement manager then runs
configured stop commands for shell profiles and spawns the active profile after
initial manage. To include that in live smoke:

```bash
TRIAD_LIVE_TEST_QUICKSHELL=1 ./tools/live_smoke.sh
```

The smoke gate verifies that a compatible shell profile was spawned, that
`$XDG_RUNTIME_DIR/triad-compat-bin/niri` exists, and that the private shim can
query Triad through the shell-facing `$NIRI_SOCKET`. Triad also prepends
`$XDG_RUNTIME_DIR/triad-shell-compat/share` to the shell profile's
`XDG_DATA_DIRS` so shells can resolve Triad-provided desktop/icon aliases
without changing the rest of the user session.

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
