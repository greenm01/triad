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
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

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

find_dbus_session_config() {
  for candidate in \
    /usr/share/dbus-1/session.conf \
    /etc/dbus-1/session.conf; do
    if [ -r "$candidate" ] && grep -q '<listen>' "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' ""
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

river_bin="${TRIAD_RIVER_BIN:-$(command -v river 2>/dev/null || true)}"
manager_loop="${TRIAD_MANAGER_LOOP:-$HOME/.local/bin/triad-manager-loop}"
dbus_runner="$(find_dbus_run_session)"
dbus_config="$(find_dbus_session_config)"

if [ -z "$river_bin" ]; then
  printf '%s\n' "river-triad-session: river not found; install River 0.4+ or set TRIAD_RIVER_BIN"
  exit 1
fi

printf '%s\n' "river-triad-session: starting at $(date -Is 2>/dev/null || date)"
printf '%s\n' "river-triad-session: HOME=$HOME"
printf '%s\n' "river-triad-session: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
printf '%s\n' "river-triad-session: WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
printf '%s\n' "river-triad-session: river=$river_bin"
printf '%s\n' "river-triad-session: manager=$manager_loop"

start_river() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "$dbus_runner" ]; then
    if [ -n "$dbus_config" ]; then
      printf '%s\n' "river-triad-session: starting River through $dbus_runner --config-file=$dbus_config"
      "$dbus_runner" --config-file="$dbus_config" -- "$river_bin" -c "$manager_loop"
      return $?
    fi

    printf '%s\n' "river-triad-session: starting River through $dbus_runner"
    "$dbus_runner" -- "$river_bin" -c "$manager_loop"
    return $?
  fi

  printf '%s\n' "river-triad-session: starting River directly"
  "$river_bin" -c "$manager_loop"
}

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "$dbus_runner" ]; then
  :
fi

set +e
start_river
status="$?"
set -e

if [ "$status" -ne 0 ] &&
  [ -z "${WLR_RENDERER:-}" ] &&
  grep -q 'RendererCreateFailed' "$session_log" 2>/dev/null; then
  printf '%s\n' "river-triad-session: hardware renderer failed; retrying with WLR_RENDERER=pixman"
  export WLR_RENDERER=pixman
  set +e
  start_river
  status="$?"
  set -e
fi

exit "$status"
