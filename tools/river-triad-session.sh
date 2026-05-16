#!/bin/sh
set -eu

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/triad"
mkdir -p "$state_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
session_log="$state_dir/river-triad-session-$stamp.log"
latest_log="$state_dir/river-triad-session-latest.log"
ln -sfn "$session_log" "$latest_log" 2>/dev/null || true
exec >>"$session_log" 2>&1

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="$HOME/.local/bin:$PATH"

find_dbus_run_session() {
  for candidate in \
    /usr/bin/dbus-run-session \
    /bin/dbus-run-session \
    /usr/sbin/dbus-run-session \
    /sbin/dbus-run-session; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  command -v dbus-run-session 2>/dev/null || true
}

case "${TRIAD_SESSION_DEV_MODE:-}" in
  1|true|TRUE|yes|YES|on|ON)
    export TRIAD_DEV_MODE=1
    ;;
  *)
    unset TRIAD_DEV_MODE
    unset TRIAD_BEHAVIOR_LOG
    ;;
esac

river_bin="${TRIAD_RIVER_BIN:-river}"
manager_loop="${TRIAD_MANAGER_LOOP:-$HOME/.local/bin/triad-manager-loop}"
dbus_runner="$(find_dbus_run_session)"

printf '%s\n' "river-triad-session: starting at $(date -Is 2>/dev/null || date)"
printf '%s\n' "river-triad-session: HOME=$HOME"
printf '%s\n' "river-triad-session: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
printf '%s\n' "river-triad-session: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
printf '%s\n' "river-triad-session: river=$river_bin"
printf '%s\n' "river-triad-session: manager=$manager_loop"

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "$dbus_runner" ]; then
  printf '%s\n' "river-triad-session: starting River through $dbus_runner"
  exec "$dbus_runner" -- "$river_bin" -c "$manager_loop"
fi

printf '%s\n' "river-triad-session: starting River directly"
exec "$river_bin" -c "$manager_loop"
