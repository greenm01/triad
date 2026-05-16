#!/bin/sh
set -eu

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="$HOME/.local/bin:$PATH"

river_bin="${TRIAD_RIVER_BIN:-river}"
manager_loop="${TRIAD_MANAGER_LOOP:-$HOME/.local/bin/triad-manager-loop}"

exec "$river_bin" -c "$manager_loop"
