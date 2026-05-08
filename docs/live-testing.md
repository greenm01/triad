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
```

Expected startup milestones in `triad.log`:

- `Logging initialized`
- `Triad process starting`
- `Starting Triad IPC server`
- `Bound to river_window_manager_v1`
- `Triad connected to River`
- `Initial config loaded`

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
