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

enable_live_reload_dev_mode() {
  marker="$runtime_dir/triad-live-dev-mode"
  marker_dir="$(dirname -- "$marker")"
  mkdir -p "$marker_dir"
  printf '1\n' > "$marker"
  log_info "enabled one-shot dev mode for replacement daemon via $marker"
}

atomic_install() {
  src="$1"
  dst="$2"
  mode="$3"
  tmp="$dst.tmp.$$"

  install -Dm"$mode" "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

manager_loop_restart_marker() {
  echo "$runtime_dir/triad-manager-loop-restart-required"
}

latest_manager_loop_pid() {
  manager_loop="$1"
  latest=""

  for proc_cmdline in /proc/[0-9]*/cmdline; do
    pid="${proc_cmdline%/cmdline}"
    pid="${pid##*/}"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    case "$exe" in
      */sh|*/bash|*/dash|*/busybox) ;;
      *) continue ;;
    esac

    cmdline="$(tr '\0' ' ' < "$proc_cmdline" 2>/dev/null || true)"
    case "$cmdline" in
      *"$manager_loop"*)
        if [ -z "$latest" ] || [ "$pid" -gt "$latest" ]; then
          latest="$pid"
        fi
        ;;
    esac
  done

  [ -n "$latest" ] || return 1
  echo "$latest"
}

process_started_after_file() {
  pid="$1"
  marker="$2"
  [ -d "/proc/$pid" ] || return 1
  [ -e "$marker" ] || return 1

  python3 - "$pid" "$marker" <<'PY'
import os
import sys

pid = sys.argv[1]
path = sys.argv[2]

try:
    with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as handle:
        proc_stat = handle.read()
    fields_after_comm = proc_stat.rsplit(") ", 1)[1].split()
    start_ticks = int(fields_after_comm[19])
    clock_ticks = os.sysconf(os.sysconf_names["SC_CLK_TCK"])

    boot_time = 0
    with open("/proc/stat", "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("btime "):
                boot_time = int(line.split()[1])
                break
    if boot_time <= 0:
        sys.exit(1)

    proc_start = boot_time + (start_ticks / clock_ticks)
    file_mtime = os.stat(path).st_mtime
except Exception:
    sys.exit(1)

sys.exit(0 if proc_start >= file_mtime else 1)
PY
}

write_manager_loop_restart_marker() {
  marker="$(manager_loop_restart_marker)"
  marker_dir="$(dirname -- "$marker")"
  manager_pid="$(latest_manager_loop_pid "$live_manager_loop" || true)"
  mkdir -p "$marker_dir"
  {
    printf '%s\n' "$live_manager_loop"
    date -Is
    printf 'manager_pid=%s\n' "$manager_pid"
  } > "$marker"
  log_info "marked manager loop restart required via $marker"
}

require_manager_loop_restart_if_pending() {
  marker="$(manager_loop_restart_marker)"
  [ -e "$marker" ] || return 0

  marker_loop="$(sed -n '1p' "$marker" 2>/dev/null || true)"
  if [ -n "$marker_loop" ] && [ "$marker_loop" != "$live_manager_loop" ]; then
    log_info "ignoring manager loop restart marker for different path: $marker_loop"
    return 0
  fi

  manager_pid="$(latest_manager_loop_pid "$live_manager_loop" || true)"
  marker_pid="$(sed -n 's/^manager_pid=//p' "$marker" 2>/dev/null || true)"
  if [ -n "$manager_pid" ] &&
      [ -n "$marker_pid" ] &&
      [ "$manager_pid" != "$marker_pid" ]; then
    rm -f "$marker"
    log_info "manager loop restart marker cleared by manager pid $manager_pid"
    return 0
  fi

  if [ -z "$marker_pid" ] &&
      [ -n "$manager_pid" ] &&
      process_started_after_file "$manager_pid" "$marker"; then
    rm -f "$marker"
    log_info "manager loop restart marker cleared by manager pid $manager_pid"
    return 0
  fi

  if [ -n "$manager_pid" ]; then
    log_error "manager loop was updated, but running manager pid $manager_pid predates the update"
  else
    log_error "manager loop was updated, but no running manager loop was found"
  fi
  log_error "restart the River/Triad session, then retry liveReload"
  fail "refusing live reload until updated manager loop is running"
}

sync_live_manager_loop() {
  if [ -x "$live_manager_loop" ] &&
      cmp -s "$repo_dir/tools/triad-manager-loop.sh" "$live_manager_loop"; then
    return 0
  fi

  if [ -e "$live_manager_loop" ]; then
    log_error "installed manager loop is not the hardened repo version: $live_manager_loop"
  else
    log_error "live manager loop is missing: $live_manager_loop"
  fi

  if ! atomic_install \
      "$repo_dir/tools/triad-manager-loop.sh" "$live_manager_loop" 755; then
    fail "failed to install updated manager loop: $live_manager_loop"
  fi

  write_manager_loop_restart_marker
  log_error "installed updated manager loop: $live_manager_loop"
  log_error "restart the River/Triad session, then retry liveReload"
  fail "updated live manager loop; restart required before live reload"
}

require_running_manager_loop_current() {
  manager_pid="$(latest_manager_loop_pid "$live_manager_loop" || true)"
  [ -n "$manager_pid" ] || return 0

  if process_started_after_file "$manager_pid" "$live_manager_loop"; then
    return 0
  fi

  write_manager_loop_restart_marker
  log_error "installed manager loop is newer than running manager pid $manager_pid"
  log_error "restart the River/Triad session, then retry liveReload"
  fail "refusing live reload until updated manager loop is running"
}

latest_live_triad_pid() {
  latest=""
  for proc_exe in /proc/[0-9]*/exe; do
    pid="${proc_exe%/exe}"
    pid="${pid##*/}"
    exe="$(readlink "$proc_exe" 2>/dev/null || true)"
    if [ "$exe" = "$bin_dir/triad" ] &&
        { [ -z "$latest" ] || [ "$pid" -gt "$latest" ]; }; then
      latest="$pid"
    fi
  done

  [ -n "$latest" ] || return 1
  echo "$latest"
}

perf_status_is_compatible() {
  printf "%s\n" "$1" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if data.get("ok") is True and data.get("type") == "perf-status":
    sys.exit(0)
sys.exit(1)
'
}

running_triad_pid() {
  perf_status="$(timeout 1 "$repo_dir/triad" msg perf-status 2>/dev/null || true)"
  if [ -n "$perf_status" ]; then
    pid="$(
      printf "%s\n" "$perf_status" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
pid = data.get("pid", 0)
if isinstance(pid, int) and pid > 0:
    print(pid)
'
    )"
    if [ -n "$pid" ]; then
      echo "$pid"
      return 0
    fi
    if perf_status_is_compatible "$perf_status"; then
      latest_live_triad_pid
      return $?
    fi
  fi
  return 1
}

require_hardened_runtime() {
  live_manager_loop="${TRIAD_MANAGER_LOOP:-$HOME/.local/bin/triad-manager-loop}"

  require_manager_loop_restart_if_pending
  sync_live_manager_loop
  require_running_manager_loop_current

  if ! old_pid="$(running_triad_pid)"; then
    log_error "running Triad daemon does not expose perf-status pid"
    log_error "restart the River/Triad session on the hardened binaries, then retry liveReload"
    fail "refusing live reload with stale running Triad daemon"
  fi

  log_info "hardened live runtime confirmed with manager pid $old_pid"
}

validate_live_config() {
  report="$(mktemp "${TMPDIR:-/tmp}/triad-live-config.XXXXXX")"
  if "$repo_dir/triad" validate-config >"$report" 2>&1; then
    while IFS= read -r line; do
      log_info "config validation $line"
    done < "$report"
    rm -f "$report"
    return 0
  fi

  while IFS= read -r line; do
    log_error "config validation $line"
  done < "$report"
  rm -f "$report"
  fail "live config validation failed; aborting reload before installing binaries"
}

backup_live_binaries() {
  [ -x "$bin_dir/triad" ] ||
    fail "missing installed live binary: $bin_dir/triad"
  [ -x "$bin_dir/triad_niri" ] ||
    fail "missing installed live binary: $bin_dir/triad_niri"

  backup_dir="$(live_reload_log_dir)/rollback-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$backup_dir"
  cp -p "$bin_dir/triad" "$backup_dir/triad"
  cp -p "$bin_dir/triad_niri" "$backup_dir/triad_niri"
  log_info "backed up live binaries to $backup_dir"
}

restore_live_binaries() {
  if [ -z "${backup_dir:-}" ]; then
    log_error "no live binary backup is available for rollback"
    return 1
  fi
  if [ ! -x "$backup_dir/triad" ] || [ ! -x "$backup_dir/triad_niri" ]; then
    log_error "live binary backup is incomplete: $backup_dir"
    return 1
  fi

  atomic_install "$backup_dir/triad" "$bin_dir/triad" 755
  atomic_install "$backup_dir/triad_niri" "$bin_dir/triad_niri" 755
  log_info "restored live binaries from $backup_dir"
}

rollback_and_fail() {
  message="$1"
  log_error "$message"
  if restore_live_binaries; then
    rollback_start_pid="$(running_triad_pid || true)"
    if "$bin_dir/triad" msg triad-reload >/dev/null 2>&1; then
      log_info "requested reload after restoring previous live binaries"
      if wait_rollback_ready "$rollback_start_pid"; then
        log_info "rollback reload became ready"
      else
        log_error "rollback reload did not become ready"
      fi
    else
      log_error "restored previous live binaries, but rollback reload IPC failed"
    fi
  fi
  exit 1
}

wait_rollback_ready() {
  previous_pid="$1"
  i=0
  while [ "$i" -lt 50 ]; do
    current_pid="$(running_triad_pid || true)"
    if [ -n "$current_pid" ] &&
        { [ -z "$previous_pid" ] || [ "$current_pid" != "$previous_pid" ]; }; then
      wait_restore_ready || return 1
      log_info "rollback manager pid $current_pid restored active tag $snapshot_active_tag"
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
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

def windows_by_id(state):
    result = {}
    for window in state.get("windows", []):
        if not isinstance(window, dict):
            continue
        win_id = window.get("id")
        if isinstance(win_id, int):
            result[win_id] = window
    return result

def app_pid_counts(state):
    result = {}
    for window in state.get("windows", []):
        if not isinstance(window, dict):
            continue
        app_id = window.get("app_id", "")
        pid = window.get("pid", 0)
        if app_id and isinstance(pid, int) and pid > 0:
            key = (app_id, pid)
            result[key] = result.get(key, 0) + 1
    return result

def canonical_maps(expected_state, actual_state):
    expected_windows = windows_by_id(expected_state)
    actual_windows = windows_by_id(actual_state)
    expected_app_pid_counts = app_pid_counts(expected_state)
    actual_app_pid_counts = app_pid_counts(actual_state)

    def canonical_id(window, counts):
        identifier = window.get("identifier", "")
        if identifier:
            return "identifier:" + identifier
        app_id = window.get("app_id", "")
        pid = window.get("pid", 0)
        if (
            app_id and isinstance(pid, int) and pid > 0 and
            counts.get((app_id, pid), 0) == 1
        ):
            return "app-pid:{0}:{1}".format(app_id, pid)
        return "id:" + str(window.get("id", 0))

    expected_map = {
        win_id: canonical_id(window, expected_app_pid_counts)
        for win_id, window in expected_windows.items()
    }
    actual_map = {
        win_id: canonical_id(window, actual_app_pid_counts)
        for win_id, window in actual_windows.items()
    }
    return expected_map, actual_map

def rounded(value):
    if isinstance(value, float):
        return round(value, 3)
    return value

def canonical_ref(value, id_map):
    if isinstance(value, int) and value in id_map:
        return id_map[value]
    return value

def normalize_columns(columns, id_map):
    result = []
    for column in columns or []:
        if not isinstance(column, dict):
            continue
        result.append({
            "windows": [
                canonical_ref(win_id, id_map)
                for win_id in column.get("windows", [])
            ],
            "width_proportion": rounded(column.get("width_proportion", 0.0)),
            "scroller_single_proportion": rounded(
                column.get("scroller_single_proportion", 0.0)
            ),
            "is_full_width": bool(column.get("is_full_width", False)),
        })
    return result

def normalize_tags(state, id_map, active_tag):
    result = {}
    for tag in state.get("tags", []):
        if not isinstance(tag, dict):
            continue
        tag_id = tag.get("id")
        if not isinstance(tag_id, int):
            continue
        normalized = {
            "name": tag.get("name", ""),
            "layout_mode": tag.get("layout_mode", 0),
            "columns": normalize_columns(tag.get("columns", []), id_map),
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
        if tag_id == active_tag:
            normalized["focused_window"] = canonical_ref(
                tag.get("focused_window", 0),
                id_map
            )
        result[tag_id] = normalized
    return result

def normalize_windows(state, id_map):
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
            if key == "id":
                continue
            if key in {"parent_id", "swallowed_by", "swallowing"}:
                normalized[key] = canonical_ref(value, id_map)
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
        result[id_map.get(win_id, "id:" + str(win_id))] = normalized
    return result

def normalize_output_tags(state):
    tags = []
    for entry in state.get("output_tags", []):
        if isinstance(entry, dict):
            tag_id = entry.get("tag_id", 0)
            if isinstance(tag_id, int):
                tags.append(tag_id)
    return sorted(tags)

def output_tags_preserved(expected_tags, actual_tags):
    remaining = list(actual_tags)
    for tag_id in expected_tags:
        try:
            remaining.remove(tag_id)
        except ValueError:
            return False
    return True

def normalize_focus_history(state, id_map):
    return [canonical_ref(win_id, id_map) for win_id in state.get("focus_history", [])]

def same_members(expected_values, actual_values):
    return sorted(expected_values) == sorted(actual_values)

def normalized(state, id_map):
    active_tag = state.get("active_tag", 0)
    return {
        "active_tag": active_tag,
        "focused_window": canonical_ref(state.get("focused_window", 0), id_map),
        "tags": normalize_tags(state, id_map, active_tag),
        "windows": normalize_windows(state, id_map),
        "output_tags": normalize_output_tags(state),
        "focus_history": normalize_focus_history(state, id_map),
        "workspace_history": state.get("workspace_history", []),
    }

expected_raw = read_state(sys.argv[1])
actual_raw = read_state(sys.argv[2])
expected_id_map, actual_id_map = canonical_maps(expected_raw, actual_raw)
expected = normalized(expected_raw, expected_id_map)
actual = normalized(actual_raw, actual_id_map)

ok = True
for key in ["active_tag", "focused_window", "workspace_history"]:
    if expected[key] != actual[key]:
        ok = False
        print(f"{key} mismatch")
        print(f"  expected: {expected[key]}")
        print(f"  actual:   {actual[key]}")

if not same_members(expected["focus_history"], actual["focus_history"]):
    ok = False
    print("focus_history membership mismatch")
    print(f"  expected: {expected['focus_history']}")
    print(f"  actual:   {actual['focus_history']}")

if not output_tags_preserved(expected["output_tags"], actual["output_tags"]):
    ok = False
    print("output_tags mismatch")
    print(f"  expected: {expected['output_tags']}")
    print(f"  actual:   {actual['output_tags']}")

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
    current_pid="$(running_triad_pid)"
    if [ -n "$current_pid" ] && [ "$current_pid" != "$old_pid" ]; then
      wait_restore_ready || return 1
      ready_pid="$(running_triad_pid)"
      if [ -z "$ready_pid" ] || [ "$ready_pid" = "$old_pid" ]; then
        log_error "restored workspace state became ready, but no replacement triad manager remained"
        return 1
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

if [ "${1:-}" = "--compare-restore-snapshots" ]; then
  if [ "$#" -ne 3 ]; then
    fail "usage: tools/live_reload.sh --compare-restore-snapshots EXPECTED ACTUAL"
  fi
  compare_restore_snapshots "$2" "$3"
  exit $?
fi

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin_dir="${TRIAD_LIVE_BIN_DIR:-$HOME/.local/bin}"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
restore_path="${TRIAD_LIVE_RESTORE_PATH:-$runtime_dir/triad-live-restore.json}"
backup_dir=""
old_pid=""

[ -x "$repo_dir/triad" ] || fail "missing built binary: $repo_dir/triad"
[ -x "$repo_dir/triad_niri" ] || fail "missing built binary: $repo_dir/triad_niri"

require_hardened_runtime
validate_live_config
snapshot_restore_state "$restore_path"
enable_live_reload_dev_mode

mkdir -p "$bin_dir"
backup_live_binaries

atomic_install "$repo_dir/triad" "$bin_dir/triad" 755
atomic_install "$repo_dir/triad_niri" "$bin_dir/triad_niri" 755

if "$repo_dir/triad" msg triad-reload; then
  wait_reload_ready ||
    rollback_and_fail "installed binaries and requested reload, but triad did not become ready"
else
  rollback_and_fail "installed binaries, but triad-reload IPC failed"
fi
