#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
triad="${TRIAD_LIVE_RELOAD_TRIAD_BIN:-$repo_dir/triad}"

if [ ! -x "$triad" ]; then
  printf '%s\n' "live-reload: missing built triad binary: $triad" >&2
  printf '%s\n' "live-reload: run nimble liveReload or build Triad first" >&2
  exit 1
fi

exec "$triad" live-reload "$@"
