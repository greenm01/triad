#!/bin/sh
set -eu

fail() {
  printf '%s\n' "live-reload: $*" >&2
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

latest_triad_pid() {
  pgrep -n -x triad 2>/dev/null || true
}

wait_niri_ready() {
  i=0
  while [ "$i" -lt 50 ]; do
    if "$repo_dir/triad_niri" msg -j workspaces >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

wait_restarted() {
  i=0
  while [ "$i" -lt 50 ]; do
    new_pid="$(latest_triad_pid)"
    if [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ]; then
      wait_niri_ready ||
        fail "installed binaries and restarted manager pid $old_pid -> $new_pid, but Niri-compatible IPC did not become ready"
      printf '%s\n' "live-reload: installed binaries and restarted manager pid $old_pid -> $new_pid; Niri-compatible IPC is ready"
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

snapshot_restore_state() {
  restore_path="$1"
  snapshot=""

  if snapshot="$(timeout 3 "$repo_dir/triad" msg dump-live-restore-state 2>/dev/null)"; then
    if printf '%s\n' "$snapshot" |
        grep -q '"schema"[[:space:]]*:[[:space:]]*"triad-live-restore-v2"'; then
      restore_dir="$(dirname -- "$restore_path")"
      mkdir -p "$restore_dir"
      tmp="$restore_path.tmp.$$"
      printf '%s\n' "$snapshot" > "$tmp"
      mv -f "$tmp" "$restore_path"
      window_count="$(printf '%s\n' "$snapshot" | tr ',' '\n' | grep -c '"id"' || true)"
      printf '%s\n' "live-reload: snapshotted native state for $window_count item(s) to $restore_path"
      return 0
    fi
    fail "native live restore snapshot had an unsupported schema; aborting reload to preserve state"
  else
    fail "native live restore snapshot timed out or failed; aborting reload to preserve state"
  fi
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="${TRIAD_LIVE_BIN_DIR:-$HOME/.local/bin}"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
restore_path="${TRIAD_LIVE_RESTORE_PATH:-$runtime_dir/triad-live-restore.json}"
old_pid="$(latest_triad_pid)"

[ -x "$repo_dir/triad" ] || fail "missing built binary: $repo_dir/triad"
[ -x "$repo_dir/triad_niri" ] || fail "missing built binary: $repo_dir/triad_niri"

snapshot_restore_state "$restore_path"

mkdir -p "$bin_dir"

atomic_install "$repo_dir/triad" "$bin_dir/triad" 755
atomic_install "$repo_dir/triad_niri" "$bin_dir/triad_niri" 755

if "$repo_dir/triad" msg stop-manager; then
  wait_restarted ||
    fail "installed binaries and requested restart, but no new triad pid appeared"
else
  fail "installed binaries, but stop-manager IPC failed"
fi
