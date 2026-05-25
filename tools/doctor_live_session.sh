#!/bin/sh
set -eu

expected_supervisor_protocol=1

fail() {
  printf '%s\n' "doctor-live: $*" >&2
  exit 1
}

info() {
  printf '%s\n' "doctor-live: $*"
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
bin_dir="${TRIAD_LIVE_BIN_DIR:-$HOME/.local/bin}"
runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="$state_home/triad"
metadata="$state_dir/current-session.json"
live_triad="${TRIAD_LIVE_TRIAD_BIN:-$bin_dir/triad}"
live_manager_loop="${TRIAD_MANAGER_LOOP:-$bin_dir/triad-manager-loop}"
live_session_runner="${TRIAD_SESSION_RUNNER:-$bin_dir/river-triad-session}"
config_path="${TRIAD_CONFIG:-$HOME/.config/triad/config.kdl}"

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
}

restart_required() {
  reason="$1"
  marker="$(manager_loop_restart_marker)"
  write_manager_loop_restart_marker
  fail "$reason; restart the River/Triad session so River execs the current supervisor, then retry nimble liveReload. restart marker: $marker"
}

sync_packaged_script() {
  src="$1"
  dst="$2"
  name="$3"

  [ -f "$src" ] || fail "missing repo $name script: $src"
  if [ -x "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi

  atomic_install "$src" "$dst" 755
  restart_required "installed updated $name at $dst"
}

triad_cli() {
  if [ -n "${TRIAD_DOCTOR_TRIAD_BIN:-}" ]; then
    printf '%s\n' "$TRIAD_DOCTOR_TRIAD_BIN"
  elif [ -x "$repo_dir/triad" ]; then
    printf '%s\n' "$repo_dir/triad"
  elif [ -x "$bin_dir/triad" ]; then
    printf '%s\n' "$bin_dir/triad"
  else
    fail "no triad binary found; build or install Triad first"
  fi
}

check_live_triad_binary() {
  [ -x "$live_triad" ] ||
    fail "installed live triad is missing or not executable: $live_triad; run nimble installSession"

  report="$(mktemp "${TMPDIR:-/tmp}/triad-doctor-live-binary.XXXXXX")"
  if ! "$live_triad" logs --json >"$report" 2>&1; then
    while IFS= read -r line; do
      printf '%s\n' "doctor-live: live triad logs check $line" >&2
    done < "$report"
    rm -f "$report"
    fail "installed live triad is stale or incompatible: $live_triad; it must support offline 'triad logs --json'; run nimble installSession"
  fi
  if ! grep -q '"ok":' "$report"; then
    rm -f "$report"
    fail "installed live triad returned malformed logs JSON: $live_triad; run nimble installSession"
  fi
  rm -f "$report"

  help="$("$live_triad" --help 2>/dev/null || true)"
  case "$help" in
    *"triad session"*|*" session "*) ;;
    *)
      fail "installed live triad is stale: $live_triad; help is missing the session command; run nimble installSession"
      ;;
  esac
  case "$help" in
    *"triad supervise"*|*" supervise "*) ;;
    *)
      fail "installed live triad is stale: $live_triad; help is missing the supervise command; run nimble installSession"
      ;;
  esac
  case "$help" in
    *"triad logs"*|*" logs "*) ;;
    *)
      fail "installed live triad is stale: $live_triad; help is missing the logs command; run nimble installSession"
      ;;
  esac

  info "live triad binary supports native session commands: $live_triad"
}

diagnose_config_failure() {
  report="$1"
  layout_id="$(
    sed -n 's/.*janet layout "\([^"]*\)": no script registered layout.*/\1/p' "$report" |
      head -n 1
  )"
  [ -n "$layout_id" ] || return 0

  example="$repo_dir/examples/janet/layouts/$layout_id.janet"
  [ -f "$example" ] || return 0

  layout_dir="$(
    python3 - "$config_path" <<'PY'
import os
import re
import sys

path = sys.argv[1]
default = "~/.config/triad/layouts"
try:
    lines = open(path, "r", encoding="utf-8").read().splitlines()
except Exception:
    print(os.path.expanduser(default))
    sys.exit(0)

in_janet = False
depth = 0
value = default
for line in lines:
    stripped = line.split("//", 1)[0].strip()
    if not stripped:
        continue
    if not in_janet and re.match(r"^janet\s*\{", stripped):
        in_janet = True
        depth = stripped.count("{") - stripped.count("}")
        continue
    if in_janet:
        match = re.search(r'layout-dir\s+"([^"]+)"', stripped)
        if match:
            value = match.group(1)
            break
        depth += stripped.count("{") - stripped.count("}")
        if depth <= 0:
            break

print(os.path.expanduser(value))
PY
  )"
  target="$layout_dir/$layout_id.janet"

  printf '%s\n' "doctor-live: matching example layout exists: $example" >&2
  printf '%s\n' "doctor-live: repair with:" >&2
  printf '%s\n' "doctor-live:   mkdir -p '$layout_dir'" >&2
  printf '%s\n' "doctor-live:   install -m 0644 '$example' '$target'" >&2
}

validate_config() {
  cli="$(triad_cli)"
  report="$(mktemp "${TMPDIR:-/tmp}/triad-doctor-config.XXXXXX")"
  if "$cli" validate-config --config "$config_path" >"$report" 2>&1; then
    while IFS= read -r line; do
      info "config validation $line"
    done < "$report"
    rm -f "$report"
    return 0
  fi

  while IFS= read -r line; do
    printf '%s\n' "doctor-live: config validation $line" >&2
  done < "$report"
  diagnose_config_failure "$report"
  rm -f "$report"
  fail "config validation failed; fix config/assets before live reload"
}

running_triad_pid() {
  cli="$(triad_cli)"
  perf_status="$(timeout 1 "$cli" msg perf-status 2>/dev/null || true)"
  [ -n "$perf_status" ] || return 1

  printf "%s\n" "$perf_status" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
pid = data.get("pid", 0)
if isinstance(pid, int) and pid > 0:
    print(pid)
    sys.exit(0)
sys.exit(1)
'
}

metadata_field() {
  field="$1"
  python3 - "$metadata" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)
value = data.get(field, 0)
if isinstance(value, int):
    print(value)
elif isinstance(value, str):
    print(value)
else:
    sys.exit(1)
PY
}

check_restart_marker() {
  marker="$(manager_loop_restart_marker)"
  [ -e "$marker" ] || return 0

  marker_loop="$(sed -n '1p' "$marker" 2>/dev/null || true)"
  if [ -n "$marker_loop" ] && [ "$marker_loop" != "$live_manager_loop" ]; then
    info "ignoring restart marker for different manager loop: $marker_loop"
    return 0
  fi

  manager_pid="$(latest_manager_loop_pid "$live_manager_loop" || true)"
  marker_pid="$(sed -n 's/^manager_pid=//p' "$marker" 2>/dev/null || true)"
  if [ -n "$manager_pid" ] &&
      [ -n "$marker_pid" ] &&
      [ "$manager_pid" != "$marker_pid" ]; then
    rm -f "$marker"
    info "cleared stale restart marker after manager pid changed to $manager_pid"
    return 0
  fi

  if [ -z "$marker_pid" ] &&
      [ -n "$manager_pid" ] &&
      process_started_after_file "$manager_pid" "$marker"; then
    rm -f "$marker"
    info "cleared stale restart marker after manager pid $manager_pid"
    return 0
  fi

  fail "restart still required after support script update; restart the River/Triad session, then retry"
}

check_supervisor_metadata() {
  [ -f "$metadata" ] ||
    fail "missing supervisor metadata: $metadata; restart the River/Triad session before live reload"

  protocol="$(metadata_field supervisor_protocol || true)"
  supervisor_pid="$(metadata_field supervisor_pid || true)"
  daemon_pid_record="$(metadata_field daemon_pid || true)"

  case "$protocol" in
    ''|*[!0-9]*) fail "invalid supervisor protocol in $metadata" ;;
  esac
  if [ "$protocol" -lt "$expected_supervisor_protocol" ]; then
    restart_required "supervisor protocol $protocol is older than required $expected_supervisor_protocol"
  fi

  case "$supervisor_pid" in
    ''|*[!0-9]*) fail "invalid supervisor pid in $metadata" ;;
  esac
  [ -d "/proc/$supervisor_pid" ] ||
    fail "supervisor pid $supervisor_pid from $metadata is not running; restart the River/Triad session"

  daemon_pid="$(running_triad_pid || true)"
  [ -n "$daemon_pid" ] ||
    fail "running Triad daemon does not answer perf-status; restart the River/Triad session"

  if [ "$daemon_pid_record" != "$daemon_pid" ]; then
    fail "supervisor metadata daemon pid $daemon_pid_record does not match live daemon pid $daemon_pid; restart the River/Triad session"
  fi

  info "supervisor metadata valid: supervisor=$supervisor_pid daemon=$daemon_pid protocol=$protocol"
}

sync_packaged_script "$repo_dir/tools/triad-manager-loop.sh" "$live_manager_loop" "manager loop"
sync_packaged_script "$repo_dir/tools/river-triad-session.sh" "$live_session_runner" "session runner"
check_restart_marker
check_live_triad_binary
validate_config
check_supervisor_metadata

info "live session doctor passed"
