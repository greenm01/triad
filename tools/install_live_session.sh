#!/bin/sh
set -eu

fail() {
  printf '%s\n' "install-live-session: $*" >&2
  exit 1
}

atomic_install() {
  src="$1"
  dst="$2"
  mode="$3"
  tmp="$dst.tmp.$$"

  install -Dm"$mode" "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
config_dir="$HOME/.config/triad"
config_path="$config_dir/config.kdl"
config_target="$repo_dir/config.default.kdl"
desktop_dir="${TRIAD_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"
desktop_path="$desktop_dir/river-triad.desktop"

[ -f "$config_target" ] || fail "missing config: $config_target"
[ -x "$repo_dir/triad" ] || fail "missing built binary: $repo_dir/triad"
[ -x "$repo_dir/triad_niri" ] || fail "missing built binary: $repo_dir/triad_niri"

mkdir -p "$bin_dir" "$config_dir"

atomic_install "$repo_dir/triad" "$bin_dir/triad" 755
atomic_install "$repo_dir/triad_niri" "$bin_dir/triad_niri" 755
atomic_install "$repo_dir/tools/river-triad-session.sh" "$bin_dir/river-triad-session" 755
atomic_install "$repo_dir/tools/triad-manager-loop.sh" "$bin_dir/triad-manager-loop" 755

if [ -e "$config_path" ] || [ -L "$config_path" ]; then
  current_target=""
  if [ -L "$config_path" ]; then
    current_target="$(readlink "$config_path" || true)"
  fi

  if [ "$current_target" != "$config_target" ]; then
    backup="$config_path.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$config_path" "$backup"
    printf '%s\n' "install-live-session: backed up config to $backup"
  fi
fi
ln -sfn "$config_target" "$config_path"

if [ -w "$desktop_dir" ]; then
  install -Dm644 "$repo_dir/tools/river-triad.desktop" "$desktop_path"
else
  sudo -n install -Dm644 "$repo_dir/tools/river-triad.desktop" "$desktop_path"
fi

printf '%s\n' "install-live-session: installed $desktop_path"
printf '%s\n' "install-live-session: select 'River (Triad)' at login"
