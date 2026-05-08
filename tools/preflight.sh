#!/bin/sh
set -eu

fail() {
  printf '%s\n' "preflight: $*" >&2
  exit 1
}

status="$(git status --short)"
if [ -n "$status" ]; then
  printf '%s\n' "$status" >&2
  fail "working tree must be clean before running preflight"
fi

nimble test
nimble build
nimble tidy

tracked_execs="$(git ls-files -s | awk '$1 ~ /^100755/ {print}')"
if [ -n "$tracked_execs" ]; then
  printf '%s\n' "$tracked_execs" >&2
  fail "tracked executable-mode files found"
fi

remaining_execs="$(find . -path ./.git -prune -o -type f -perm -111 -print)"
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
