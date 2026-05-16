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

resolve_river_bin() {
  if [ -n "${TRIAD_RIVER_BIN:-}" ]; then
    validate_river "$TRIAD_RIVER_BIN" >/dev/null ||
      fail "TRIAD_RIVER_BIN must point at executable River 0.4+: $TRIAD_RIVER_BIN"
    printf '%s\n' "$TRIAD_RIVER_BIN"
    return 0
  fi

  candidate="$(command -v river 2>/dev/null || true)"
  if [ -n "$candidate" ] && validate_river "$candidate" >/dev/null; then
    printf '%s\n' "$candidate"
    return 0
  fi

  fail "River 0.4+ not found; install River from upstream and ensure river is on PATH, or set TRIAD_RIVER_BIN=/path/to/river"
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
config_dir="$HOME/.config/triad"
config_path="$config_dir/config.kdl"
config_source="$repo_dir/config.default.kdl"
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

river_bin="$(resolve_river_bin)"
river_version="$(validate_river "$river_bin")"
printf '%s\n' "install-live-session: using River $river_version at $river_bin"

printf '%s\n' "install-live-session: syncing Nim dependencies"
(cd "$repo_dir" && nimble sync)

printf '%s\n' "install-live-session: building optimized triad binaries"
(cd "$repo_dir" && TRIAD_DEV_MODE=0 nimble build -d:release --opt:speed --passL:-s)

[ -x "$repo_dir/triad" ] || fail "missing built binary: $repo_dir/triad"
[ -x "$repo_dir/triad_niri" ] || fail "missing built binary: $repo_dir/triad_niri"

mkdir -p "$bin_dir" "$config_dir"

atomic_install "$repo_dir/triad" "$bin_dir/triad" 755
atomic_install "$repo_dir/triad_niri" "$bin_dir/triad_niri" 755
atomic_install "$repo_dir/tools/triad-manager-loop.sh" "$bin_dir/triad-manager-loop" 755

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
export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"

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

river_bin="\${TRIAD_RIVER_BIN:-$river_bin}"
manager_loop="\${TRIAD_MANAGER_LOOP:-\$HOME/.local/bin/triad-manager-loop}"
dbus_runner="\$(find_dbus_run_session)"
dbus_config="\$(find_dbus_session_config)"

printf '%s\\n' "river-triad-session: starting at \$(date -Is 2>/dev/null || date)"
printf '%s\\n' "river-triad-session: HOME=\$HOME"
printf '%s\\n' "river-triad-session: XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-}"
printf '%s\\n' "river-triad-session: WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-}"
printf '%s\\n' "river-triad-session: river=\$river_bin"
printf '%s\\n' "river-triad-session: manager=\$manager_loop"

start_river() {
  if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "\$dbus_runner" ]; then
    if [ -n "\$dbus_config" ]; then
      printf '%s\\n' "river-triad-session: starting River through \$dbus_runner --config-file=\$dbus_config"
      "\$dbus_runner" --config-file="\$dbus_config" -- "\$river_bin" -c "\$manager_loop"
      return \$?
    fi

    printf '%s\\n' "river-triad-session: starting River through \$dbus_runner"
    "\$dbus_runner" -- "\$river_bin" -c "\$manager_loop"
    return \$?
  fi

  printf '%s\\n' "river-triad-session: starting River directly"
  "\$river_bin" -c "\$manager_loop"
}

if [ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "\$dbus_runner" ]; then
  :
fi

set +e
start_river
status="\$?"
set -e

if [ "\$status" -ne 0 ] &&
  [ -z "\${WLR_RENDERER:-}" ] &&
  grep -q 'RendererCreateFailed' "\$session_log" 2>/dev/null; then
  printf '%s\\n' "river-triad-session: hardware renderer failed; retrying with WLR_RENDERER=pixman"
  export WLR_RENDERER=pixman
  set +e
  start_river
  status="\$?"
  set -e
fi

exit "\$status"
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
