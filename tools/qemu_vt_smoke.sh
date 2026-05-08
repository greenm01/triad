#!/bin/sh
set -eu

fail() {
  printf '%s\n' "qemu-vt-smoke: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

ssh_guest() {
  if [ -n "${TRIAD_QEMU_SSH_KEY:-}" ]; then
    ssh -i "$TRIAD_QEMU_SSH_KEY" -p "$ssh_port" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$ssh_user@127.0.0.1" "$@"
  else
    ssh -p "$ssh_port" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "$ssh_user@127.0.0.1" "$@"
  fi
}

image="${TRIAD_QEMU_IMAGE:-}"
[ -n "$image" ] || fail "set TRIAD_QEMU_IMAGE to a prepared guest disk image"
[ -f "$image" ] || fail "image does not exist: $image"

need_cmd qemu-system-x86_64
need_cmd ssh

repo_dir="$(pwd)"
ssh_user="${TRIAD_QEMU_SSH_USER:-triad}"
ssh_port="${TRIAD_QEMU_SSH_PORT:-2222}"
memory="${TRIAD_QEMU_MEMORY:-2048}"
cpus="${TRIAD_QEMU_CPUS:-2}"
display="${TRIAD_QEMU_DISPLAY:-gtk,gl=off}"
image_format="${TRIAD_QEMU_IMAGE_FORMAT:-qcow2}"
out_dir="${TRIAD_QEMU_OUT:-qemu-vt-smoke-out}"
qemu_pid=""

mkdir -p "$out_dir"

cleanup() {
  if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

set -- qemu-system-x86_64
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  set -- "$@" -enable-kvm
fi
set -- "$@" \
  -m "$memory" \
  -smp "$cpus" \
  -drive "file=$image,if=virtio,format=$image_format" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-vga \
  -display "$display" \
  -fsdev "local,id=triad_src,path=$repo_dir,security_model=none,readonly=on" \
  -device virtio-9p-pci,fsdev=triad_src,mount_tag=triad_src \
  -serial "file:$out_dir/serial.log" \
  -monitor none

"$@" >"$out_dir/qemu.stdout" 2>"$out_dir/qemu.stderr" &
qemu_pid="$!"

printf '%s\n' "qemu-vt-smoke: waiting for SSH on 127.0.0.1:$ssh_port"
i=0
while ! ssh_guest true >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    fail "guest SSH did not become ready; see $out_dir/qemu.stderr"
  fi
  sleep 1
done

printf '%s\n' "qemu-vt-smoke: running guest VT smoke"
ssh_guest 'sh -s' <<'GUEST'
set -eu

fail() {
  printf '%s\n' "guest-vt-smoke: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command in guest: $1"
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

need_cmd chvt
need_cmd dbus-run-session
need_cmd mount
need_cmd nimble
need_cmd openvt
need_cmd river
need_cmd runuser
if [ "$(id -u)" -ne 0 ]; then
  need_cmd sudo
fi

guest_user="$(id -un)"
guest_uid="$(id -u)"
guest_gid="$(id -g)"
runtime="/run/user/$guest_uid"
mnt="/mnt/triad_src"
work="/tmp/triad-vt-smoke"

run_root mkdir -p "$mnt" "$runtime"
run_root chown "$guest_uid:$guest_gid" "$runtime"
chmod 700 "$runtime"

if ! mountpoint -q "$mnt"; then
  run_root mount -t 9p -o trans=virtio,version=9p2000.L,ro triad_src "$mnt"
fi

rm -rf "$work"
mkdir -p "$work"
cp -a "$mnt"/. "$work"/
cd "$work"
nimble build

cat >/tmp/triad-river-init.sh <<INIT
#!/bin/sh
set -eu
cd "$work"
printf '%s\n' "XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR" > /tmp/triad-session.env
printf '%s\n' "WAYLAND_DISPLAY=\$WAYLAND_DISPLAY" >> /tmp/triad-session.env
TRIAD_LOG_LEVEL=debug ./triad 2>/tmp/triad-vt.log &
triad_pid="\$!"
printf '%s\n' "\$triad_pid" >/tmp/triad.pid
wait "\$triad_pid"
INIT
chmod 755 /tmp/triad-river-init.sh

rm -f /tmp/triad.pid /tmp/triad-vt.log /tmp/triad-tty.log /tmp/triad-outputs.json
run_root chvt 1 || true
run_root openvt -c 1 -f -- runuser -u "$guest_user" -- \
  env XDG_RUNTIME_DIR="$runtime" dbus-run-session river -c /tmp/triad-river-init.sh

i=0
while [ ! -s /tmp/triad.pid ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    fail "Triad did not write pid in River session"
  fi
  sleep 1
done

triad_pid="$(cat /tmp/triad.pid)"
i=0
while ! kill -0 "$triad_pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 10 ]; then
    fail "Triad exited during River startup"
  fi
  sleep 1
done

"$work/triad" msg focus-next
run_root chvt 3
sleep 1

if env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$runtime" "$work/triad" 2>/tmp/triad-tty.log; then
  fail "bare TTY Triad launch unexpectedly succeeded"
fi

if ! grep -q "Refusing to start outside a Wayland session" /tmp/triad-tty.log; then
  fail "bare TTY launch did not report the session guard"
fi

"$work/triad" msg toggle-overview
run_root chvt 1
sleep 1
"$work/triad_niri" msg -j outputs >/tmp/triad-outputs.json

kill "$triad_pid" 2>/dev/null || true
printf '%s\n' "guest-vt-smoke: ok"
GUEST

ssh_guest 'tar -C /tmp -czf - triad-vt.log triad-tty.log triad-session.env triad-outputs.json 2>/dev/null' \
  >"$out_dir/guest-artifacts.tgz" || true

printf '%s\n' "qemu-vt-smoke: ok"
printf '%s\n' "qemu-vt-smoke: artifacts in $out_dir"
