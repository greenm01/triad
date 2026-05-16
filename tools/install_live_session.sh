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
runtime_path="${TRIAD_INSTALL_RUNTIME_PATH:-${TRIAD_NIX_RUNTIME_PATH:-}}"
desktop_dir="${TRIAD_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"
desktop_path="$desktop_dir/river-triad.desktop"
desktop_tmp="$(mktemp)"
session_tmp="$(mktemp)"
trap 'rm -f "$desktop_tmp" "$session_tmp"' EXIT

[ -f "$config_target" ] || fail "missing config: $config_target"

if [ "$(id -u)" -eq 0 ]; then
  fail "run this as your normal user; the installer will use sudo/doas only for the system session file"
fi

command -v nimble >/dev/null 2>&1 ||
  fail "nimble is required to build optimized session binaries"

printf '%s\n' "install-live-session: syncing Nim dependencies"
(cd "$repo_dir" && nimble sync)

printf '%s\n' "install-live-session: building optimized triad binaries"
(cd "$repo_dir" && nimble build -d:release --opt:speed --passL:-s)

[ -x "$repo_dir/triad" ] || fail "missing built binary: $repo_dir/triad"
[ -x "$repo_dir/triad_niri" ] || fail "missing built binary: $repo_dir/triad_niri"

mkdir -p "$bin_dir" "$config_dir"

atomic_install "$repo_dir/triad" "$bin_dir/triad" 755
atomic_install "$repo_dir/triad_niri" "$bin_dir/triad_niri" 755
atomic_install "$repo_dir/tools/triad-manager-loop.sh" "$bin_dir/triad-manager-loop" 755

cat >"$session_tmp" <<EOF
#!/bin/sh
set -eu

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="\$HOME/.local/bin${runtime_path:+:$runtime_path}:\$PATH"

case "\${TRIAD_SESSION_DEV_MODE:-}" in
  1|true|TRUE|yes|YES|on|ON)
    export TRIAD_DEV_MODE=1
    ;;
  *)
    unset TRIAD_DEV_MODE
    unset TRIAD_BEHAVIOR_LOG
    ;;
esac

river_bin="\${TRIAD_RIVER_BIN:-river}"
manager_loop="\${TRIAD_MANAGER_LOOP:-\$HOME/.local/bin/triad-manager-loop}"

exec "\$river_bin" -c "\$manager_loop"
EOF
atomic_install "$session_tmp" "$bin_dir/river-triad-session" 755

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

cat >"$desktop_tmp" <<EOF
[Desktop Entry]
Name=River (Triad)
Comment=River Wayland compositor with the Triad window manager
Exec=$bin_dir/river-triad-session
Type=Application
DesktopNames=river
EOF

if [ -w "$desktop_dir" ]; then
  install -Dm644 "$desktop_tmp" "$desktop_path"
elif command -v sudo >/dev/null 2>&1; then
  sudo install -Dm644 "$desktop_tmp" "$desktop_path"
elif command -v doas >/dev/null 2>&1; then
  doas install -Dm644 "$desktop_tmp" "$desktop_path"
else
  fail "cannot write $desktop_path; install sudo/doas or set TRIAD_WAYLAND_SESSION_DIR"
fi

printf '%s\n' "install-live-session: installed $desktop_path"
printf '%s\n' "install-live-session: select 'River (Triad)' at login"
