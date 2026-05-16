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

pin_nix_runtime() {
  [ -n "$runtime_path" ] || return 0

  command -v nix-store >/dev/null 2>&1 ||
    fail "nix-store is required to pin the Nix session runtime"

  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/triad"
  gc_root_dir="$state_dir/nix-gcroots/session-runtime"
  mkdir -p "$gc_root_dir"
  find "$gc_root_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  old_ifs="$IFS"
  IFS=:
  for bin_path in $runtime_path; do
    IFS="$old_ifs"
    if [ -n "$bin_path" ]; then
      case "$bin_path" in
        /nix/store/*/bin)
          store_path="${bin_path%/bin}"
          ;;
        /nix/store/*)
          store_path="$bin_path"
          ;;
        *)
          store_path=""
          ;;
      esac

      if [ -n "$store_path" ]; then
        root_name="$(basename "$store_path")"
        nix-store --add-root "$gc_root_dir/$root_name" --indirect --realise \
          "$store_path" >/dev/null ||
          fail "failed to pin Nix runtime path: $store_path"
      fi
    fi
    IFS=:
  done
  IFS="$old_ifs"

  printf '%s\n' "install-live-session: pinned Nix runtime at $gc_root_dir"
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
config_dir="$HOME/.config/triad"
config_path="$config_dir/config.kdl"
config_source="$repo_dir/config.default.kdl"
runtime_path="${TRIAD_INSTALL_RUNTIME_PATH:-${TRIAD_NIX_RUNTIME_PATH:-}}"
desktop_dir="${TRIAD_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"
desktop_path="$desktop_dir/river-triad.desktop"
desktop_tmp="$(mktemp)"
session_tmp="$(mktemp)"
trap 'rm -f "$desktop_tmp" "$session_tmp"' EXIT

[ -f "$config_source" ] || fail "missing config: $config_source"

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
pin_nix_runtime

cat >"$session_tmp" <<EOF
#!/bin/sh
set -eu

state_dir="\${XDG_STATE_HOME:-\$HOME/.local/state}/triad"
mkdir -p "\$state_dir"
stamp="\$(date +%Y%m%d-%H%M%S)"
session_log="\$state_dir/river-triad-session-\$stamp.log"
latest_log="\$state_dir/river-triad-session-latest.log"
ln -sfn "\$session_log" "\$latest_log" 2>/dev/null || true
exec >>"\$session_log" 2>&1

export XDG_CURRENT_DESKTOP=river
export XDG_SESSION_DESKTOP=river-triad
export XDG_SESSION_TYPE=wayland
export PATH="\$HOME/.local/bin${runtime_path:+:$runtime_path}:\$PATH"

find_dbus_run_session() {
  for candidate in \\
    /usr/bin/dbus-run-session \\
    /bin/dbus-run-session \\
    /usr/sbin/dbus-run-session \\
    /sbin/dbus-run-session; do
    if [ -x "\$candidate" ]; then
      printf '%s\\n' "\$candidate"
      return 0
    fi
  done

  command -v dbus-run-session 2>/dev/null || true
}

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
dbus_runner="\$(find_dbus_run_session)"

printf '%s\\n' "river-triad-session: starting at \$(date -Is 2>/dev/null || date)"
printf '%s\\n' "river-triad-session: HOME=\$HOME"
printf '%s\\n' "river-triad-session: XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-}"
printf '%s\\n' "river-triad-session: WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-}"
printf '%s\\n' "river-triad-session: river=\$river_bin"
printf '%s\\n' "river-triad-session: manager=\$manager_loop"

if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "\$dbus_runner" ]; then
  printf '%s\\n' "river-triad-session: starting River through \$dbus_runner"
  exec "\$dbus_runner" -- "\$river_bin" -c "\$manager_loop"
fi

printf '%s\\n' "river-triad-session: starting River directly"
exec "\$river_bin" -c "\$manager_loop"
EOF
atomic_install "$session_tmp" "$bin_dir/river-triad-session" 755

if [ ! -e "$config_path" ] && [ ! -L "$config_path" ]; then
  install -Dm644 "$config_source" "$config_path"
  printf '%s\n' "install-live-session: installed default config at $config_path"
else
  printf '%s\n' "install-live-session: leaving existing config at $config_path"
fi

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
