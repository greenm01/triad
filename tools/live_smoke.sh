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

log="${TRIAD_LIVE_LOG:-triad-live-smoke.log}"
out="${TRIAD_LIVE_OUT:-triad-live-smoke.out}"
startup_wait="${TRIAD_LIVE_STARTUP_WAIT:-2}"
run_seconds="${TRIAD_LIVE_SECONDS:-8}"

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  fail "WAYLAND_DISPLAY is not set; run inside a River-compatible session"
fi

nimble build

: >"$log"
: >"$out"

TRIAD_LOG_LEVEL="${TRIAD_LOG_LEVEL:-debug}" ./triad >"$out" 2>"$log" &
pid="$!"

cleanup() {
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

./triad msg focus-next >/dev/null
./triad msg toggle-overview >/dev/null
./triad_niri msg -j workspaces >/dev/null
./triad_niri msg -j outputs >/dev/null

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
