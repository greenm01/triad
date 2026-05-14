#!/bin/sh
set -eu

live_reload_log_dir() {
  state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
  echo "$state_home/triad/live-reload"
}

live_reload_log_file() {
  echo "$(live_reload_log_dir)/live-reload-$(date +%F).log"
}

log_event() {
  level="$1"
  shift
  log_dir="$(live_reload_log_dir)"
  mkdir -p "$log_dir"
  echo "$(date -Is) [$level] $*" >> "$(live_reload_log_file)"
}

log_info() {
  log_event INFO "$*"
}

log_error() {
  log_event ERROR "$*"
  echo "live-reload: $*" >&2
}

fail() {
  log_error "$*"
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
  echo "$1" |
    sed -n 's/.*"active_tag"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

snapshot_summary() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    state = json.loads(sys.argv[1])
except Exception as exc:
    print(f"unparseable snapshot: {exc}")
    sys.exit(0)

tags = []
for tag in state.get("tags", []):
    if not isinstance(tag, dict):
        continue
    tags.append(
        "tag {id}: layout={layout} focused={focused} columns={columns}".format(
            id=tag.get("id", 0),
            layout=tag.get("layout_mode", ""),
            focused=tag.get("focused_window", 0),
            columns=len(tag.get("columns", [])),
        )
    )

print(
    "active_tag={active} focused_window={focused} windows={windows}".format(
        active=state.get("active_tag", 0),
        focused=state.get("focused_window", 0),
        windows=len(state.get("windows", [])),
    )
)
for tag in tags:
    print("  " + tag)
PY
}

write_restore_mismatch_log() {
  expected_file="$1"
  actual_file="$2"
  report_file="$3"
  log_dir="$(live_reload_log_dir)"
  mkdir -p "$log_dir"
  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$log_dir/restore-mismatch-$stamp-$$"
  cp "$expected_file" "$base.expected.json"
  cp "$actual_file" "$base.actual.json"
  cp "$report_file" "$base.report.txt"
  echo "$base"
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

compare_restore_snapshots() {
  expected="$1"
  actual="$2"

  python3 - "$expected" "$actual" <<'PY'
import json
import sys

VOLATILE_WINDOW_FIELDS = {
    "pid",
    "title",
    "actual_w",
    "actual_h",
}

def read_state(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)

def rounded(value):
    if isinstance(value, float):
        return round(value, 3)
    return value

def normalize_columns(columns):
    result = []
    for column in columns or []:
        if not isinstance(column, dict):
            continue
        result.append({
            "windows": column.get("windows", []),
            "width_proportion": rounded(column.get("width_proportion", 0.0)),
            "scroller_single_proportion": rounded(
                column.get("scroller_single_proportion", 0.0)
            ),
            "is_full_width": bool(column.get("is_full_width", False)),
        })
    return result

def normalize_tags(state):
    result = {}
    for tag in state.get("tags", []):
        if not isinstance(tag, dict):
            continue
        tag_id = tag.get("id")
        if not isinstance(tag_id, int):
            continue
        result[tag_id] = {
            "name": tag.get("name", ""),
            "layout_mode": tag.get("layout_mode", 0),
            "columns": normalize_columns(tag.get("columns", [])),
            "focused_window": tag.get("focused_window", 0),
            "target_viewport_x_offset": rounded(
                tag.get("target_viewport_x_offset", 0.0)
            ),
            "current_viewport_x_offset": rounded(
                tag.get("current_viewport_x_offset", 0.0)
            ),
            "target_viewport_y_offset": rounded(
                tag.get("target_viewport_y_offset", 0.0)
            ),
            "current_viewport_y_offset": rounded(
                tag.get("current_viewport_y_offset", 0.0)
            ),
            "master_count": tag.get("master_count", 0),
            "master_split_ratio": rounded(tag.get("master_split_ratio", 0.0)),
        }
    return result

def normalize_windows(state):
    result = {}
    for window in state.get("windows", []):
        if not isinstance(window, dict):
            continue
        win_id = window.get("id")
        if not isinstance(win_id, int):
            continue
        normalized = {}
        for key, value in window.items():
            if key in VOLATILE_WINDOW_FIELDS:
                continue
            if isinstance(value, float):
                normalized[key] = rounded(value)
            elif isinstance(value, dict):
                normalized[key] = {
                    child_key: rounded(child_value)
                    for child_key, child_value in value.items()
                }
            else:
                normalized[key] = value
        result[win_id] = normalized
    return result

def normalize_output_tags(state):
    output_tags = []
    for entry in state.get("output_tags", []):
        if isinstance(entry, dict):
            output_tags.append((entry.get("output_id", 0), entry.get("tag_id", 0)))
    return sorted(output_tags)

def normalize_focus_history(state):
    return state.get("focus_history", [])

def normalized(state):
    return {
        "active_tag": state.get("active_tag", 0),
        "focused_window": state.get("focused_window", 0),
        "tags": normalize_tags(state),
        "windows": normalize_windows(state),
        "output_tags": normalize_output_tags(state),
        "focus_history": normalize_focus_history(state),
        "workspace_history": state.get("workspace_history", []),
    }

expected = normalized(read_state(sys.argv[1]))
actual = normalized(read_state(sys.argv[2]))

ok = True
for key in ["active_tag", "focused_window", "output_tags", "focus_history", "workspace_history"]:
    if expected[key] != actual[key]:
        ok = False
        print(f"{key} mismatch")
        print(f"  expected: {expected[key]}")
        print(f"  actual:   {actual[key]}")

if expected["tags"] != actual["tags"]:
    ok = False
    print("tag/layout state mismatch")
    expected_ids = set(expected["tags"].keys())
    actual_ids = set(actual["tags"].keys())
    for tag_id in sorted(expected_ids | actual_ids):
        if expected["tags"].get(tag_id) != actual["tags"].get(tag_id):
            print(f"  tag {tag_id}")
            print(f"    expected: {expected['tags'].get(tag_id)}")
            print(f"    actual:   {actual['tags'].get(tag_id)}")

if expected["windows"] != actual["windows"]:
    ok = False
    print("window placement/state mismatch")
    expected_ids = set(expected["windows"].keys())
    actual_ids = set(actual["windows"].keys())
    for win_id in sorted(expected_ids | actual_ids):
        if expected["windows"].get(win_id) != actual["windows"].get(win_id):
            print(f"  window {win_id}")
            print(f"    expected: {expected['windows'].get(win_id)}")
            print(f"    actual:   {actual['windows'].get(win_id)}")

sys.exit(0 if ok else 1)
PY
}

wait_restore_ready() {
  i=0
  current_snapshot=""
  while [ "$i" -lt 100 ]; do
    if restore_snapshot_applied &&
        "$repo_dir/triad_niri" msg -j workspaces >/dev/null 2>&1; then
      current_snapshot="$(
        timeout 1 "$repo_dir/triad" msg dump-live-restore-state \
          2>/dev/null || true
      )"
      current_active_tag="$(active_tag_from_snapshot "$current_snapshot")"
      if [ "$current_active_tag" = "$snapshot_active_tag" ]; then
        current_tmp="$restore_path.current.$$"
        report_tmp="$restore_path.compare.$$"
        echo "$current_snapshot" > "$current_tmp"
        if compare_restore_snapshots "$snapshot_tmp" "$current_tmp" >"$report_tmp"; then
          rm -f "$current_tmp" "$report_tmp"
          return 0
        fi
        log_base="$(write_restore_mismatch_log "$snapshot_tmp" "$current_tmp" "$report_tmp")"
        rm -f "$current_tmp" "$report_tmp"
        log_error "restored manager is running, but restored state differs from captured snapshot"
        log_error "mismatch log written to $log_base.*"
        return 1
      fi
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if [ -n "$current_snapshot" ]; then
    current_tmp="$restore_path.current-timeout.$$"
    report_tmp="$restore_path.timeout-report.$$"
    echo "$current_snapshot" > "$current_tmp"
    {
      echo "restore readiness timed out before active tag and structure matched"
      echo "expected active_tag: $snapshot_active_tag"
      echo "last observed active_tag: $(active_tag_from_snapshot "$current_snapshot")"
    } > "$report_tmp"
    log_base="$(write_restore_mismatch_log "$snapshot_tmp" "$current_tmp" "$report_tmp")"
    rm -f "$current_tmp" "$report_tmp"
    log_error "restore readiness timed out; mismatch log written to $log_base.*"
  fi
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
      log_info "installed binaries and reloaded manager pid $old_pid -> $ready_pid; restored active tag $snapshot_active_tag is ready"
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
    if echo "$snapshot" |
        grep -q '"schema"[[:space:]]*:[[:space:]]*"triad-live-restore-v2"'; then
      snapshot_active_tag="$(active_tag_from_snapshot "$snapshot")"
      if [ -z "$snapshot_active_tag" ]; then
        fail "native live restore snapshot did not include active_tag"
      fi
      restore_dir="$(dirname -- "$restore_path")"
      mkdir -p "$restore_dir"
      tmp="$restore_path.tmp.$$"
      echo "$snapshot" > "$tmp"
      if snapshot_suspicious_collapse "$restore_path" "$tmp"; then
        rm -f "$tmp"
        fail "native live restore snapshot collapsed existing workspaces; set TRIAD_LIVE_RELOAD_ALLOW_COLLAPSE=1 to override"
      fi
      snapshot_tmp="$tmp"
      mv -f "$tmp" "$restore_path"
      snapshot_tmp="$restore_path"
      window_count="$(echo "$snapshot" | tr ',' '\n' | grep -c '"id"' || true)"
      log_info "snapshotted native state for $window_count item(s) to $restore_path"
      summary_tmp="$restore_path.summary.$$"
      snapshot_summary "$snapshot" > "$summary_tmp"
      while IFS= read -r line; do
        log_info "captured $line"
      done < "$summary_tmp"
      rm -f "$summary_tmp"
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
