#!/bin/sh
set -eu

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/triad"
mkdir -p "$state_dir"
triad_bin="${TRIAD_BIN:-$HOME/.local/bin/triad}"
triad_args=""

case "${TRIAD_DEV_MODE:-}" in
  1|true|TRUE|yes|YES|on|ON)
    triad_args="--dev-mode"
    export TRIAD_DEV_MODE=1
    export TRIAD_BEHAVIOR_LOG="${TRIAD_BEHAVIOR_LOG:-1}"
    ;;
esac

rapid_restarts=0

while :; do
  start_sec="$(date +%s)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  log="$state_dir/triad-$stamp.log"
  latest="$state_dir/triad-latest.log"

  ln -sfn "$log" "$latest" 2>/dev/null || true
  printf '%s\n' "triad-manager-loop: starting triad, log=$log" >&2

  "$triad_bin" $triad_args >>"$log" 2>&1
  status="$?"
  end_sec="$(date +%s)"
  runtime_sec=$((end_sec - start_sec))

  if [ "$runtime_sec" -lt 5 ]; then
    rapid_restarts=$((rapid_restarts + 1))
  else
    rapid_restarts=0
  fi

  if [ "$status" -eq 0 ]; then
    if [ "$rapid_restarts" -ge 3 ]; then
      printf '%s\n' "triad-manager-loop: triad exited cleanly after ${runtime_sec}s; rapid restart count ${rapid_restarts}, backing off" >&2
      sleep 5
    else
      printf '%s\n' "triad-manager-loop: triad exited cleanly after ${runtime_sec}s; restarting" >&2
      sleep 0.2
    fi
  else
    printf '%s\n' "triad-manager-loop: triad exited with status $status; leaving River session" >&2
    exit "$status"
  fi
done
