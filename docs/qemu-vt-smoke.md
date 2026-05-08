# QEMU VT Smoke Harness

Use this harness for bugs that depend on real virtual terminals, DRM/KMS,
seat handling, or compositor recovery. A container is fine for builds and unit
tests, but it does not own the host TTYs or display stack. QEMU does, so a
failed VT switch is contained inside the guest.

## Guest Image

You need one reusable Linux guest disk image. You do not need to download a new
ISO for every test run.

The guest must provide:

- SSH server reachable on port 22
- passwordless `sudo` for the SSH user
- `chvt`, `openvt`, `runuser`, `mount`, and `dbus-run-session`
- `river`
- Nim, Nimble, and Triad's Nim dependencies
- 9p filesystem support

Void Linux and Artix can both work. Pick the one closest to the session stack
you want to reproduce. Void is usually a small, simple harness base. Artix is a
better fit if you want Arch-like packages without systemd. The script is
image-agnostic so the project does not need to encode either installer.

## Run

Create and provision the image once, then run:

```bash
TRIAD_QEMU_IMAGE=/path/to/triad-vt.qcow2 \
TRIAD_QEMU_SSH_USER=triad \
sh tools/qemu_vt_smoke.sh
```

The script boots the image, shares the current repo into the guest over 9p,
builds Triad in `/tmp`, starts River on VT 1, starts Triad inside River,
sends the navigation/layout/scratchpad workflow commands, switches to VT 3 and
back repeatedly, verifies a bare TTY Triad launch fails before touching the IPC
socket, and checks the Triad/Niri IPC shims after each cycle.

Artifacts are written under `qemu-vt-smoke-out/`, including QEMU stderr,
serial output, and a compressed bundle of guest logs.

Useful overrides:

```bash
TRIAD_QEMU_SSH_PORT=2223
TRIAD_QEMU_SSH_KEY=/path/to/key
TRIAD_QEMU_MEMORY=4096
TRIAD_QEMU_CPUS=4
TRIAD_QEMU_DISPLAY=gtk,gl=off
TRIAD_QEMU_IMAGE_FORMAT=raw
TRIAD_QEMU_VT_CYCLES=3
TRIAD_QEMU_OUT=/tmp/triad-qemu-vt
```

Use `TRIAD_QEMU_DISPLAY=none` only when the guest compositor stack is known to
work headlessly with its virtual GPU.
