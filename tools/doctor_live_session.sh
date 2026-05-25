#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
triad="${TRIAD_DOCTOR_TRIAD_BIN:-$repo_dir/triad}"

if [ ! -x "$triad" ]; then
  printf '%s\n' "doctor-live: missing built triad binary: $triad" >&2
  printf '%s\n' "doctor-live: run nimble doctorLive or build Triad first" >&2
  exit 1
fi

exec "$triad" doctor-live "$@"
