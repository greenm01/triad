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

active_tag_from_snapshot() {
  printf '%s\n' "$1" |
    sed -n 's/.*"active_tag"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

restore_snapshot_applied() {
  [ -e "$restore_path" ] &&
    grep -q '"restore_status"[[:space:]]*:[[:space:]]*"applied"' \
      "$restore_path"
}

snapshot_suspicious_collapse() {
  previous="$1"
  candidate="$2"

  [ "${TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE:-}" = "1" ] && return 1
  [ -e "$previous" ] || return 1

  python3 - "$previous" "$candidate" <<'PY'
import json
import sys

def read_state(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return None
    if data.get("schema") != "triad-live-restore-v2":
        return None
    return data

def window_ids(state):
    return sorted(
        int(win["id"]) for win in state.get("windows", [])
        if isinstance(win, dict) and isinstance(win.get("id"), int)
    )

def occupied_tags(state):
    tags = set()
    for win in state.get("windows", []):
        if not isinstance(win, dict):
            continue
        tag = win.get("tag_id")
        if isinstance(tag, int) and tag > 0:
            tags.add(tag)
    return tags

previous = read_state(sys.argv[1])
candidate = read_state(sys.argv[2])
if previous is None or candidate is None:
    sys.exit(1)

same_windows = window_ids(previous) == window_ids(candidate)
if (
    same_windows and
    len(window_ids(previous)) > 1 and
    len(occupied_tags(previous)) > 1 and
    len(occupied_tags(candidate)) == 1
):
    sys.exit(0)
sys.exit(1)
PY
}

wait_restore_ready() {
  i=0
  while [ "$i" -lt 100 ]; do
    if restore_snapshot_applied &&
        "$repo_dir/triad_niri" msg -j workspaces >/dev/null 2>&1; then
      current_snapshot="$(
        timeout 1 "$repo_dir/triad" msg dump-live-restore-state \
          2>/dev/null || true
      )"
      current_active_tag="$(active_tag_from_snapshot "$current_snapshot")"
      if [ "$current_active_tag" = "$snapshot_active_tag" ]; then
        return 0
      fi
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

wait_reload_ready() {
  i=0
  while [ "$i" -lt 50 ]; do
    current_pid="$(latest_triad_pid)"
    if [ -n "$current_pid" ] && [ "$current_pid" != "$old_pid" ]; then
      wait_restore_ready ||
        fail "installed binaries and requested reload, but restored workspace state did not become ready"
      ready_pid="$(latest_triad_pid)"
      if [ -z "$ready_pid" ] || [ "$ready_pid" = "$old_pid" ]; then
        fail "restored workspace state became ready, but no replacement triad manager remained"
      fi
      printf '%s\n' "live-reload: installed binaries and reloaded manager pid $old_pid -> $ready_pid; restored active tag $snapshot_active_tag is ready"
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
      snapshot_active_tag="$(active_tag_from_snapshot "$snapshot")"
      if [ -z "$snapshot_active_tag" ]; then
        fail "native live restore snapshot did not include active_tag"
      fi
      restore_dir="$(dirname -- "$restore_path")"
      mkdir -p "$restore_dir"
      tmp="$restore_path.tmp.$$"
      printf '%s\n' "$snapshot" > "$tmp"
      if snapshot_suspicious_collapse "$restore_path" "$tmp"; then
        rm -f "$tmp"
        fail "native live restore snapshot collapsed existing workspaces; set TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE=1 to override"
      fi
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

if "$repo_dir/triad" msg triad-reload; then
  wait_reload_ready ||
    fail "installed binaries and requested reload, but triad did not become ready"
else
  fail "installed binaries, but triad-reload IPC failed"
fi
