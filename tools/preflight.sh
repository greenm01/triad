#!/bin/sh
set -eu

fail() {
  printf '%s\n' "preflight: $*" >&2
  exit 1
}

required_nim_version="2.2.10"

version_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]
}

nim_version="$(nim --version | awk '/Nim Compiler Version/ {print $4; exit}')"
if [ -z "$nim_version" ]; then
  fail "could not determine Nim compiler version"
fi

if ! version_ge "$nim_version" "$required_nim_version"; then
  fail "Nim $required_nim_version or newer is required; found $nim_version"
fi

status="$(git status --short)"
if [ -n "$status" ]; then
  printf '%s\n' "$status" >&2
  fail "working tree must be clean before running preflight"
fi

nimble test
nimble testLiveDoctor
nimble build

if [ "${TRIAD_DAILY_GATE_QEMU:-0}" = "1" ]; then
  sh tools/qemu_vt_smoke.sh
fi

if [ "${TRIAD_DAILY_GATE_LIVE:-0}" = "1" ]; then
  sh tools/live_smoke.sh
fi

nimble tidy

tracked_execs="$(git ls-files -s | awk '$1 ~ /^100755/ {print}')"
if [ -n "$tracked_execs" ]; then
  printf '%s\n' "$tracked_execs" >&2
  fail "tracked executable-mode files found"
fi

remaining_execs="$(find . -path ./.git -prune -o -path ./.nimble -prune -o -type f -perm -111 -print)"
if [ -n "$remaining_execs" ]; then
  printf '%s\n' "$remaining_execs" >&2
  fail "executable files remain after tidy"
fi

status="$(git status --short)"
if [ -n "$status" ]; then
  printf '%s\n' "$status" >&2
  fail "working tree changed during preflight"
fi

printf '%s\n' "preflight: ok"
