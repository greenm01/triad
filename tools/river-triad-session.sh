#!/bin/sh
set -eu

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="$HOME/.local/bin:$PATH"

exec /home/niltempus/src/river/zig-out/bin/river -c "$HOME/.local/bin/triad-manager-loop"
