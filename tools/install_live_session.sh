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
      fail "TRIAD_RIVER_BIN must point at executable upstream River 0.4+: $TRIAD_RIVER_BIN"
    printf '%s\n' "$TRIAD_RIVER_BIN"
    return 0
  fi

  candidate="$(command -v river 2>/dev/null || true)"
  if [ -n "$candidate" ] && validate_river "$candidate" >/dev/null; then
    printf '%s\n' "$candidate"
    return 0
  fi

  fail "upstream River 0.4+ not found; install River from upstream and ensure river is on PATH, or set TRIAD_RIVER_BIN=/path/to/river"
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
config_dir="$HOME/.config/triad"
config_path="$config_dir/config.kdl"
config_source="$repo_dir/config.default.kdl"
desktop_dir="${TRIAD_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"
desktop_path="$desktop_dir/river-triad.desktop"
desktop_tmp="$(mktemp)"
trap 'rm -f "$desktop_tmp"' EXIT

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
atomic_install "$repo_dir/tools/river-triad-session.sh" "$bin_dir/river-triad-session" 755

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
Exec=$bin_dir/triad session
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
