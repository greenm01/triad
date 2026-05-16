#!/bin/sh
set -eu

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="$HOME/.local/bin:$PATH"

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

exec "$river_bin" -c "$manager_loop"
