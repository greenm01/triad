#!/bin/sh
set -eu

fail() {
  printf '%s\n' "deploy-qemu-guest: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

ssh_guest() {
  ssh -F /dev/null \
    -p "$ssh_port" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$known_hosts" \
    "$ssh_user@127.0.0.1" "$@"
}

scp_guest() {
  scp -F /dev/null \
    -P "$ssh_port" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile="$known_hosts" \
    "$@"
}

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
image="${TRIAD_QEMU_IMAGE:-/mnt/storage/triad-qemu/images/void-triad-vt.qcow2}"
image_format="${TRIAD_QEMU_IMAGE_FORMAT:-qcow2}"
ssh_user="${TRIAD_QEMU_SSH_USER:-triad}"
ssh_port="${TRIAD_QEMU_SSH_PORT:-2222}"
memory="${TRIAD_QEMU_MEMORY:-4096}"
cpus="${TRIAD_QEMU_CPUS:-4}"
out_dir="${TRIAD_QEMU_OUT:-/mnt/storage/triad-qemu/logs/headless-deploy}"
known_hosts="${TRIAD_QEMU_KNOWN_HOSTS:-/tmp/triad-qemu-known-hosts}"
host_fuzzel_dir="${TRIAD_HOST_FUZZEL_DIR:-$HOME/.config/fuzzel}"
qemu_pid=""
started_qemu=0

need_cmd ssh
need_cmd scp

[ -d "$repo_dir" ] || fail "repo directory not found: $repo_dir"
[ -f "$repo_dir/config.default.kdl" ] || fail "missing repo config: $repo_dir/config.default.kdl"
[ -d "$host_fuzzel_dir" ] || fail "host fuzzel config directory not found: $host_fuzzel_dir"

mkdir -p "$out_dir"

cleanup() {
  if [ "$started_qemu" -eq 1 ] && [ "${TRIAD_QEMU_KEEP_RUNNING:-0}" != "1" ]; then
    ssh_guest "sudo poweroff" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 30 ] && kill -0 "$qemu_pid" 2>/dev/null; do
      i=$((i + 1))
      sleep 1
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
      kill "$qemu_pid" 2>/dev/null || true
      wait "$qemu_pid" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT INT TERM

if ! ssh_guest true >/dev/null 2>&1; then
  need_cmd qemu-system-x86_64
  [ -f "$image" ] || fail "image does not exist: $image"

  set -- qemu-system-x86_64
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    set -- "$@" -enable-kvm -machine q35,accel=kvm -cpu host
  fi
  set -- "$@" \
    -m "$memory" \
    -smp "$cpus" \
    -drive "file=$image,if=virtio,format=$image_format,cache=none,aio=native" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -fsdev "local,id=triad_src,path=$repo_dir,security_model=none,readonly=on" \
    -device virtio-9p-pci,fsdev=triad_src,mount_tag=triad_src \
    -serial "file:$out_dir/serial.log" \
    -monitor none

  "$@" >"$out_dir/qemu.stdout" 2>"$out_dir/qemu.stderr" &
  qemu_pid="$!"
  started_qemu=1

  printf '%s\n' "deploy-qemu-guest: started headless QEMU pid $qemu_pid"
fi

printf '%s\n' "deploy-qemu-guest: waiting for SSH on 127.0.0.1:$ssh_port"
i=0
while ! ssh_guest true >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    fail "guest SSH did not become ready; see $out_dir/qemu.stderr"
  fi
  sleep 1
done

printf '%s\n' "deploy-qemu-guest: copying host fuzzel config"
tmp_remote="/tmp/triad-fuzzel-config"
ssh_guest "rm -rf '$tmp_remote' && mkdir -p '$tmp_remote'"
scp_guest -r "$host_fuzzel_dir/." "$ssh_user@127.0.0.1:$tmp_remote/"

printf '%s\n' "deploy-qemu-guest: provisioning guest"
ssh_guest "TRIAD_REMOTE_FUZZEL='$tmp_remote' sh -s" <<'GUEST'
set -eu

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

guest_user="$(id -un)"
mnt="/mnt/triad_src"
work="$HOME/src/triad"

run_root mkdir -p "$mnt"
if ! mountpoint -q "$mnt"; then
  run_root mount -t 9p -o trans=virtio,version=9p2000.L,ro triad_src "$mnt"
fi

mkdir -p "$HOME/.config/triad" "$HOME/.config/fuzzel" "$HOME/.config/fish" "$HOME/.local/bin" "$HOME/src"
cp "$mnt/config.default.kdl" "$HOME/.config/triad/config.kdl"

rm -rf "$HOME/.config/fuzzel"
mkdir -p "$HOME/.config/fuzzel"
cp -a "$TRIAD_REMOTE_FUZZEL"/. "$HOME/.config/fuzzel"/

if ! command -v fish >/dev/null 2>&1; then
  run_root xbps-install -Sy fish
fi

fish_path="$(command -v fish)"
if ! grep -qx "$fish_path" /etc/shells 2>/dev/null; then
  printf '%s\n' "$fish_path" | run_root tee -a /etc/shells >/dev/null
fi
if command -v chsh >/dev/null 2>&1; then
  run_root chsh -s "$fish_path" "$guest_user" || true
elif command -v usermod >/dev/null 2>&1; then
  run_root usermod -s "$fish_path" "$guest_user" || true
fi

cat >"$HOME/.config/fish/config.fish" <<'FISH'
function fish_greeting
end

fish_add_path $HOME/.local/bin
fish_add_path $HOME/.nimble/bin

set -gx _JAVA_AWT_WM_NONREPARENTING 1
set -gx GDK_BACKEND wayland

if command -q eza
    alias ls='eza --color=always --group-directories-first --icons'
    alias ll='eza -la --icons --octal-permissions --group-directories-first'
    alias l='eza -bGF --header --git --color=always --group-directories-first --icons'
    alias la='eza --long --all --group --group-directories-first'
    alias lt='eza -T --color=always --group-directories-first'
else
    alias ll='ls -la'
    alias la='ls -A'
end

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias g='git'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline'
alias gd='git diff'

alias nb='nimble build'
alias nt='nimble test'
alias ni='nimble install'

if command -q hx
    alias hx=(command -s hx)
else if command -q helix
    alias hx=(command -s helix)
end

if command -q direnv
    direnv hook fish | source
    set -gx DIRENV_LOG_FORMAT ""
end
FISH

rm -rf "$HOME/src/triad.next"
cp -a "$mnt" "$HOME/src/triad.next"
rm -rf "$HOME/src/triad.prev"
if [ -d "$work" ]; then
  mv "$work" "$HOME/src/triad.prev"
fi
mv "$HOME/src/triad.next" "$work"

cd "$work"
nimble --useSystemNim build --nimcache:"$work/.nimcache"
install -Dm755 triad "$HOME/.local/bin/triad"
install -Dm755 triad_niri "$HOME/.local/bin/triad_niri"

rm -rf "$TRIAD_REMOTE_FUZZEL"
printf '%s\n' "guest provisioned: $work"
GUEST

printf '%s\n' "deploy-qemu-guest: done"
if [ "$started_qemu" -eq 1 ] && [ "${TRIAD_QEMU_KEEP_RUNNING:-0}" != "1" ]; then
  printf '%s\n' "deploy-qemu-guest: powering off headless guest"
fi
