#!/bin/sh
# Dependency hygiene checks. Usage: sh tools/check_deps.sh [binary...]
#
# Nim's {.dynlib.} loads libraries with dlopen at runtime, so ldd never shows
# them. A missing one only fails on the user's machine (see issue #6, where
# std/re needed PCRE1). These checks catch that before release.
set -eu

fail() {
  printf '%s\n' "check_deps: $*" >&2
  exit 1
}

# std/re and std/nre dlopen PCRE1, which current distros no longer ship.
banned="$(grep -rnE '^\s*(import|from)\s.*\bn?re\b' src --include='*.nim' || true)"
if [ -n "$banned" ]; then
  printf '%s\n' "$banned" >&2
  fail "std/re and std/nre need PCRE1 at runtime; import regex instead"
fi

# Every nimble requirement needs a matching entry in the Nix lock.
lock="nix/triad-nim-lock.json"
for req in $(sed -n 's/^requires "\([^ "]*\).*/\1/p' triad.nimble); do
  [ "$req" = "nim" ] && continue
  name="${req##*/}"
  name="${name#nim-}"
  name="${name%-nim}"
  grep -q "\"$name\"" "$lock" || fail "$req is required but missing from $lock"
done

# Bare shared-library names embedded in the binaries are dlopen targets.
# Full paths (fileExists probes) are ignored.
allowed='^lib(c|m|dl|pthread|rt|wayland-client|xkbcommon)\.so'
for bin in "$@"; do
  [ -f "$bin" ] || fail "binary not found: $bin"
  libs="$(strings "$bin" | grep -vE '/[^ ]*lib[A-Za-z0-9_+-]+\.so' |
    grep -oE 'lib[A-Za-z0-9_+-]+\.so[0-9.()|]*' | sort -u)"
  for lib in $libs; do
    printf '%s\n' "$lib" | grep -qE "$allowed" ||
      fail "$bin loads unexpected runtime library $lib; add it to the allowlist only if every supported distro ships it"
  done
done
