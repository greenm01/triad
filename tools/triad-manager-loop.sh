#!/bin/sh
set -eu

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/triad"
mkdir -p "$state_dir"
export TRIAD_BEHAVIOR_LOG="${TRIAD_BEHAVIOR_LOG:-1}"

while :; do
  stamp="$(date +%Y%m%d-%H%M%S)"
  log="$state_dir/triad-$stamp.log"
  latest="$state_dir/triad-latest.log"

  ln -sfn "$log" "$latest" 2>/dev/null || true
  printf '%s\n' "triad-manager-loop: starting triad, log=$log" >&2

  "$HOME/.local/bin/triad" >>"$log" 2>&1
  status="$?"

  if [ "$status" -eq 0 ]; then
    printf '%s\n' "triad-manager-loop: triad exited cleanly; restarting" >&2
    sleep 0.2
  else
    printf '%s\n' "triad-manager-loop: triad exited with status $status; leaving River session" >&2
    exit "$status"
  fi
done
