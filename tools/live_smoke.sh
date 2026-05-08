#!/bin/sh
set -eu

fail() {
  printf '%s\n' "live-smoke: $*" >&2
  if [ -f "$log" ]; then
    printf '%s\n' "--- triad log ---" >&2
    tail -n 80 "$log" >&2 || true
  fi
  exit 1
}

require_log() {
  pattern="$1"
  if ! grep -q "$pattern" "$log"; then
    fail "missing log milestone: $pattern"
  fi
}

triad_msg() {
  ./triad msg "$@" >/dev/null
}

log="${TRIAD_LIVE_LOG:-triad-live-smoke.log}"
out="${TRIAD_LIVE_OUT:-triad-live-smoke.out}"
events="${TRIAD_LIVE_EVENTS:-triad-live-smoke.events}"
startup_wait="${TRIAD_LIVE_STARTUP_WAIT:-2}"
run_seconds="${TRIAD_LIVE_SECONDS:-8}"
lockme_bin="${TRIAD_LOCKME_BIN:-}"
lockme_pid=""
event_stream_pid=""
tmpdir=""

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  fail "WAYLAND_DISPLAY is not set; run inside a River-compatible session"
fi

nimble build

: >"$log"
: >"$out"

TRIAD_LOG_LEVEL="${TRIAD_LOG_LEVEL:-debug}" ./triad >"$out" 2>"$log" &
pid="$!"

cleanup() {
  if [ -n "$lockme_pid" ] && kill -0 "$lockme_pid" 2>/dev/null; then
    kill "$lockme_pid" 2>/dev/null || true
    wait "$lockme_pid" 2>/dev/null || true
  fi
  if [ -n "$event_stream_pid" ] && kill -0 "$event_stream_pid" 2>/dev/null; then
    kill "$event_stream_pid" 2>/dev/null || true
    wait "$event_stream_pid" 2>/dev/null || true
  fi
  if [ -n "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

sleep "$startup_wait"

if ! kill -0 "$pid" 2>/dev/null; then
  fail "triad exited during startup"
fi

require_log "Logging initialized"
require_log "Triad process starting"
require_log "Starting Triad IPC server"
require_log "Bound to river_window_manager_v1"
require_log "Triad connected to River"

if [ -z "$lockme_bin" ] && command -v lockme >/dev/null 2>&1; then
  lockme_bin="$(command -v lockme)"
fi

if [ -n "$lockme_bin" ]; then
  "$lockme_bin" --check-protocols >/dev/null
fi

triad_msg focus-next
triad_msg focus-left
triad_msg focus-right
triad_msg focus-up
triad_msg focus-down
triad_msg focus-last
triad_msg focus-tag-left
triad_msg focus-tag-right
triad_msg focus-occupied-tag-left
triad_msg focus-occupied-tag-right
triad_msg move-to-tag-left
triad_msg move-to-tag-right
triad_msg switch-layout
triad_msg layout-deck
triad_msg layout-center-tile
triad_msg layout-right-tile
triad_msg layout-vertical-tile
triad_msg layout-vertical-grid
triad_msg layout-vertical-deck
triad_msg move-to-named-scratchpad live-smoke
triad_msg toggle-named-scratchpad live-smoke
triad_msg restore-scratchpad
triad_msg config-reload
./triad_niri msg -j workspaces >/dev/null
./triad_niri msg -j outputs >/dev/null

if [ -n "${NIRI_SOCKET:-}" ] && [ ! -e "$NIRI_SOCKET" ]; then
  niri_socket="$NIRI_SOCKET"
else
  niri_socket="$XDG_RUNTIME_DIR/triad-niri.sock"
fi

env NIRI_SOCKET="$niri_socket" ./triad_niri msg -j workspaces >/dev/null
env NIRI_SOCKET="$niri_socket" ./triad_niri msg -j outputs >/dev/null

if [ "${TRIAD_LIVE_TEST_QUICKSHELL:-0}" = "1" ]; then
  require_log "Spawned Quickshell"
  compat_bin="$XDG_RUNTIME_DIR/triad-compat-bin"
  if [ ! -x "$compat_bin/niri" ]; then
    fail "missing private niri shim at $compat_bin/niri"
  fi
  env NIRI_SOCKET="$niri_socket" PATH="$compat_bin:$PATH" niri msg -j workspaces >/dev/null
  env NIRI_SOCKET="$niri_socket" PATH="$compat_bin:$PATH" niri msg -j outputs >/dev/null
fi

: >"$events"
./triad msg event-stream >"$events" &
event_stream_pid="$!"
sleep 1

if ! kill -0 "$event_stream_pid" 2>/dev/null; then
  fail "event-stream subscriber exited before receiving events"
fi

triad_msg toggle-overview

waited=0
while ! grep -q "OverviewOpenedOrClosed" "$events"; do
  if ! kill -0 "$event_stream_pid" 2>/dev/null; then
    fail "event-stream subscriber exited before overview event"
  fi
  if [ "$waited" -ge 30 ]; then
    fail "event-stream did not receive overview event"
  fi
  waited=$((waited + 1))
  sleep 0.1
done

kill "$event_stream_pid" 2>/dev/null || true
wait "$event_stream_pid" 2>/dev/null || true
event_stream_pid=""

if [ "${TRIAD_LIVE_TEST_LOCKME:-0}" = "1" ]; then
  if [ -z "$lockme_bin" ]; then
    fail "TRIAD_LIVE_TEST_LOCKME=1 requires lockme on PATH or TRIAD_LOCKME_BIN"
  fi
  tmpdir="$(mktemp -d)"
  ready_file="$tmpdir/lockme-ready"
  : >"$ready_file"
  "$lockme_bin" --dev-mode --ready-fd 3 3>"$ready_file" >/dev/null 2>&1 &
  lockme_pid="$!"
  waited=0
  while [ ! -s "$ready_file" ] && kill -0 "$lockme_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -s "$ready_file" ]; then
    kill "$lockme_pid" 2>/dev/null || true
    wait "$lockme_pid" 2>/dev/null || true
    fail "lockme did not report session lock readiness"
  fi
  printf '%s\n' "live-smoke: lockme dev-mode acquired the session; press Esc to unlock" >&2
  wait "$lockme_pid"
  lockme_pid=""
  rm -rf "$tmpdir"
  tmpdir=""
fi

if [ "${TRIAD_LIVE_LAUNCH_CLIENTS:-0}" = "1" ]; then
  clients="${TRIAD_LIVE_CLIENTS:-foot alacritty xterm}"
  for client in $clients; do
    if command -v "$client" >/dev/null 2>&1; then
      "$client" >/dev/null 2>&1 &
      break
    fi
  done
fi

sleep "$run_seconds"

if ! kill -0 "$pid" 2>/dev/null; then
  fail "triad exited before smoke window closed"
fi

if grep -Eq "Traceback|unhandled exception|fatal|protocol error" "$log"; then
  fail "fatal error pattern found in log"
fi

printf '%s\n' "live-smoke: ok"
