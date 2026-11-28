#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if ! command -v cargo >/dev/null 2>&1; then
  printf '%s\n' 'triad: Cargo is unavailable; skipping the optional Wayland proxy build' >&2
elif ! cargo build --release --locked \
    --manifest-path "$repo_dir/wayland-proxy/Cargo.toml" \
    --target-dir "$repo_dir/wayland-proxy/target"; then
  printf '%s\n' 'triad: optional Wayland proxy build failed' >&2
fi
