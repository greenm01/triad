# Daily Driver Gates

These gates are for changes that could affect compositor liveness, IPC,
virtual-terminal recovery, session locking, or startup safety. Unit tests alone
do not cover the display stack, so run the narrowest gate that matches the risk.

## Fast Gate

Run before ordinary commits:

```bash
nimble test
nimble build
nimble tidy
```

Use `nimble verify` when the working tree is clean. It runs the fast gate and
checks that no build artifacts or executable-mode source files remain.

## Live Gate

Run from inside a River-compatible session:

```bash
sh tools/live_smoke.sh
```

The live smoke starts Triad, checks River startup milestones, sends the
navigation/layout/scratchpad workflow commands, reloads config, verifies the
Niri shim, subscribes to `event-stream`, and confirms `toggle-overview`
produces an `OverviewOpenedOrClosed` event.

Useful optional passes:

```bash
TRIAD_LIVE_LAUNCH_CLIENTS=1 sh tools/live_smoke.sh
TRIAD_LIVE_TEST_LOCKME=1 sh tools/live_smoke.sh
```

To fold this into preflight:

```bash
TRIAD_DAILY_GATE_LIVE=1 nimble verify
```

## QEMU VT Gate

Run this for bugs involving Ctrl-Alt-Fn, DRM/KMS, bare TTY startup, or
compositor recovery:

```bash
TRIAD_QEMU_IMAGE=/mnt/storage/triad-qemu/images/void-triad-vt.qcow2 \
TRIAD_QEMU_SSH_USER=triad \
TRIAD_QEMU_SSH_KEY=/home/niltempus/.ssh/id_x13 \
TRIAD_QEMU_VT_CYCLES=3 \
TRIAD_QEMU_OUT=/mnt/storage/triad-qemu/out/latest \
sh tools/qemu_vt_smoke.sh
```

The QEMU gate boots the reusable guest image, builds Triad inside the guest,
starts River on VT 1, sends the workflow IPC commands, switches away and back
repeatedly, verifies IPC after each switch, checks the bare TTY session guard,
and captures guest logs.

To fold this into preflight:

```bash
TRIAD_DAILY_GATE_QEMU=1 \
TRIAD_QEMU_IMAGE=/mnt/storage/triad-qemu/images/void-triad-vt.qcow2 \
TRIAD_QEMU_SSH_USER=triad \
TRIAD_QEMU_SSH_KEY=/home/niltempus/.ssh/id_x13 \
nimble verify
```

## Release Gate

Before treating Triad as daily-driver ready for a session:

```bash
nimble verify
TRIAD_QEMU_IMAGE=/mnt/storage/triad-qemu/images/void-triad-vt.qcow2 sh tools/qemu_vt_smoke.sh
```

Then run one manual River session with `TRIAD_LOG_LEVEL=debug ./triad
2>triad.log`, launch and close several clients, and confirm there are no Nim
tracebacks, fatal logs, protocol errors, or lost IPC responses.
