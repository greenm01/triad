#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="${TMPDIR:-/tmp}/triad-live-doctor-test.$$"
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
state="$tmp/state"
runtime="$tmp/run"
bin="$tmp/bin"
mkdir -p "$home" "$state/triad" "$runtime" "$bin" "$home/.config/triad"

install -m 0755 "$repo_dir/tools/triad-manager-loop.sh" "$bin/triad-manager-loop"
install -m 0755 "$repo_dir/tools/river-triad-session.sh" "$bin/river-triad-session"
printf '%s\n' 'janet { layout-dir "~/.config/triad/layouts" }' > "$home/.config/triad/config.kdl"

fake_triad="$tmp/triad"
cat > "$fake_triad" <<'SH'
#!/bin/sh
set -eu

if [ "$1" = "validate-config" ]; then
  if [ "${TRIAD_FAKE_CONFIG_INVALID:-0}" = "1" ]; then
    printf '%s\n' 'triad: config invalid: janet layout "janet-grid": no script registered layout "janet-grid"' >&2
    exit 1
  fi
  printf '%s\n' "triad: config valid: $3"
  exit 0
fi

if [ "$1" = "msg" ] && [ "$2" = "perf-status" ]; then
  printf '{"ok":true,"type":"perf-status","pid":%s}\n' "$TRIAD_FAKE_DAEMON_PID"
  exit 0
fi

exit 1
SH
chmod +x "$fake_triad"

write_metadata() {
  cat > "$state/triad/current-session.json" <<EOF
{"version":1,"claim_id":"test","session_id":"test","session_pid":$$,"supervisor_pid":$$,"daemon_pid":$$,"state_dir":"$state/triad","session_log":"$tmp/session.log","daemon_log":"$tmp/daemon.log","started_at":"2026-05-25T00:00:00-04:00","supervisor_protocol":1}
EOF
}

doctor_env() {
  HOME="$home" \
    XDG_STATE_HOME="$state" \
    XDG_RUNTIME_DIR="$runtime" \
    TRIAD_LIVE_BIN_DIR="$bin" \
    TRIAD_DOCTOR_TRIAD_BIN="$fake_triad" \
    TRIAD_FAKE_DAEMON_PID="$$" \
    sh "$repo_dir/tools/doctor_live_session.sh"
}

write_metadata
doctor_env > "$tmp/valid.out"
grep -q "live session doctor passed" "$tmp/valid.out"

TRIAD_FAKE_CONFIG_INVALID=1 doctor_env > "$tmp/invalid.out" 2>&1 && {
  printf '%s\n' "expected invalid config to fail" >&2
  exit 1
}
grep -q "examples/janet/layouts/janet-grid.janet" "$tmp/invalid.out"
grep -q "install -m 0644" "$tmp/invalid.out"

rm -f "$state/triad/current-session.json"
doctor_env > "$tmp/missing-metadata.out" 2>&1 && {
  printf '%s\n' "expected missing metadata to fail" >&2
  exit 1
}
grep -q "missing supervisor metadata" "$tmp/missing-metadata.out"

printf '%s\n' "tlive_doctor: ok"
