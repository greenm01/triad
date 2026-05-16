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

version_at_least_river_04() {
  version="$1"
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"

  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$minor" in
    ''|*[!0-9]*) return 1 ;;
  esac

  [ "$major" -gt 0 ] || [ "$minor" -ge 4 ]
}

validate_river() {
  candidate="$1"
  [ -x "$candidate" ] || return 1

  version="$("$candidate" -version 2>/dev/null | awk '{print $1}')"
  version_at_least_river_04 "$version" || return 1

  printf '%s\n' "$version"
}

river_candidate_target() {
  candidate="$1"
  [ -n "$candidate" ] && [ -x "$candidate" ] || return 1

  if grep -q 'triad-managed-river-launcher' "$candidate" 2>/dev/null; then
    target="$(sed -n 's/^exec "\([^"]*\)" "\$@"$/\1/p' "$candidate" | head -n 1)"
    [ -n "$target" ] && [ -x "$target" ] || return 1
    printf '%s\n' "$target"
    return 0
  fi

  printf '%s\n' "$candidate"
}

resolve_river_bin() {
  if [ -n "${TRIAD_RIVER_BIN:-}" ]; then
    target="$(river_candidate_target "$TRIAD_RIVER_BIN")" ||
      fail "TRIAD_RIVER_BIN must point at executable River 0.4+: $TRIAD_RIVER_BIN"
    validate_river "$target" >/dev/null ||
      fail "TRIAD_RIVER_BIN must point at executable River 0.4+: $TRIAD_RIVER_BIN"
    printf '%s\n' "$target"
    return 0
  fi

  old_ifs="$IFS"
  IFS=:
  for bin_path in $runtime_path; do
    IFS="$old_ifs"
    target="$(river_candidate_target "$bin_path/river" 2>/dev/null || true)"
    if [ -n "$target" ] && validate_river "$target" >/dev/null; then
      printf '%s\n' "$target"
      return 0
    fi
    IFS=:
  done
  IFS="$old_ifs"

  for candidate in \
    /usr/local/bin/river \
    /usr/bin/river \
    /bin/river \
    "$(command -v river 2>/dev/null || true)"; do
    if [ -z "$runtime_path" ] &&
      grep -q 'triad-managed-river-launcher' "$candidate" 2>/dev/null; then
      continue
    fi
    target="$(river_candidate_target "$candidate" 2>/dev/null || true)"
    if [ -n "$target" ] && validate_river "$target" >/dev/null; then
      printf '%s\n' "$target"
      return 0
    fi
  done

  fail "River 0.4+ not found; run from 'nix develop' or set TRIAD_RIVER_BIN=/path/to/river"
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

write_river_launcher() {
  dst="$1"

  cat >"$river_tmp" <<EOF
#!/bin/sh
# triad-managed-river-launcher
set -eu

export PATH="\$HOME/.local/bin${runtime_path:+:$runtime_path}:\$PATH"
exec "$river_bin" "\$@"
EOF

  atomic_install "$river_tmp" "$dst" 755
}

install_river_launchers() {
  triad_river="$bin_dir/triad-river"
  plain_river="$bin_dir/river"

  write_river_launcher "$triad_river"
  printf '%s\n' "install-live-session: installed $triad_river -> $river_bin"

  if [ ! -e "$plain_river" ] && [ ! -L "$plain_river" ]; then
    write_river_launcher "$plain_river"
    printf '%s\n' "install-live-session: installed $plain_river"
    return 0
  fi

  if grep -q 'triad-managed-river-launcher' "$plain_river" 2>/dev/null; then
    write_river_launcher "$plain_river"
    printf '%s\n' "install-live-session: updated $plain_river"
    return 0
  fi

  printf '%s\n' "install-live-session: leaving existing $plain_river in place"
  printf '%s\n' "install-live-session: use $triad_river for the pinned River launcher"
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
river_tmp="$(mktemp)"
trap 'rm -f "$desktop_tmp" "$session_tmp" "$river_tmp"' EXIT

[ -f "$config_source" ] || fail "missing config: $config_source"

if [ "$(id -u)" -eq 0 ]; then
  fail "run this as your normal user; the installer will use sudo/doas only for the system session file"
fi

command -v nimble >/dev/null 2>&1 ||
  fail "nimble is required to build optimized session binaries"

river_bin="$(resolve_river_bin)"
river_version="$(validate_river "$river_bin")"
printf '%s\n' "install-live-session: using River $river_version at $river_bin"

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
install_river_launchers
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

find_dbus_session_config() {
  for candidate in \\
    /usr/share/dbus-1/session.conf \\
    /etc/dbus-1/session.conf; do
    if [ -r "\$candidate" ] && grep -q '<listen>' "\$candidate" 2>/dev/null; then
      printf '%s\\n' "\$candidate"
      return 0
    fi
  done

  printf '%s\\n' ""
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

river_bin="\${TRIAD_RIVER_BIN:-\$HOME/.local/bin/triad-river}"
manager_loop="\${TRIAD_MANAGER_LOOP:-\$HOME/.local/bin/triad-manager-loop}"
dbus_runner="\$(find_dbus_run_session)"
dbus_config="\$(find_dbus_session_config)"

printf '%s\\n' "river-triad-session: starting at \$(date -Is 2>/dev/null || date)"
printf '%s\\n' "river-triad-session: HOME=\$HOME"
printf '%s\\n' "river-triad-session: XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-}"
printf '%s\\n' "river-triad-session: WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-}"
printf '%s\\n' "river-triad-session: river=\$river_bin"
printf '%s\\n' "river-triad-session: manager=\$manager_loop"

if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "\$dbus_runner" ]; then
  if [ -n "\$dbus_config" ]; then
    printf '%s\\n' "river-triad-session: starting River through \$dbus_runner --config-file=\$dbus_config"
    exec "\$dbus_runner" --config-file="\$dbus_config" -- "\$river_bin" -c "\$manager_loop"
  fi

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

if install -Dm644 "$desktop_tmp" "$desktop_path" 2>/dev/null; then
  :
elif [ -w "$desktop_dir" ]; then
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
