+++
title = "Troubleshooting"
weight = 50
+++

# Troubleshooting

## Check the Session Log

Start with Triad's log summary:

```bash
triad logs
```

Compatibility symlinks point to the live logs. Check the session log first; it
is written earliest in the startup chain and captures River, Triad, and shell
output:

```bash
tail -n 200 ~/.local/state/triad/triad-session-latest.log
```

The daemon log points to the active supervised Triad process:

```bash
tail -n 200 ~/.local/state/triad/triad-latest.log
```

List all session logs:

```bash
ls -lt ~/.local/state/triad/
```

## Validate Your Config

Check for syntax errors without restarting:

```bash
triad validate-config
```

Point at a specific file:

```bash
triad validate-config --config ~/.config/triad/config.kdl
```

## Confirm IPC Is Responding

Inside a running session:

```bash
triad msg state
triad msg workspaces
```

If either hangs, Triad isn't running or the socket is missing:

```bash
ls $XDG_RUNTIME_DIR/triad.sock
```

## Session Doesn't Appear in Display Manager

Check where your display manager reads Wayland session files:

```bash
ls /usr/share/wayland-sessions/
ls ~/.local/share/wayland-sessions/
```

Install the desktop entry to the right location:

```bash
TRIAD_WAYLAND_SESSION_DIR=/usr/share/wayland-sessions \
  tools/install_live_session.sh
```

Many display managers ignore `~/.local/share/wayland-sessions`. Use the system
path unless you know yours supports user-local sessions.

## Shell Doesn't Start

If Triad starts but no bar or shell appears, check the log for failed launch
entries. Verify the shell command is on `PATH`:

```bash
which noctalia-shell
which waybar
```

If a command is missing, install it or update the profile in your config:

```kdl
profile "waybar" {
  launch "waybar"
  stop   "pkill" "-x" "waybar"
}
```

## Config Edit Breaks Startup

If a bad edit prevents Triad from launching, start it with a known-good config:

```bash
triad --config ~/.config/triad/config.kdl.bak
```

Or reset to defaults by moving your config aside — Triad writes a starter
config on first run if none exists.

## Enable Diagnostic Logging

Normal sessions keep behavior logs off. Enable them for a diagnostic session:

```bash
TRIAD_SESSION_DEV_MODE=1 ~/.local/bin/triad session
```

Logs are written to:

```bash
~/.local/state/triad/behavior/
```

Inside a running session, toggle dev mode without restarting:

```bash
triad msg dev-mode on
triad msg dev-mode status
triad msg dev-mode off
```

## Live Reload

To apply a new Triad build without losing your windows:

```bash
nimble liveReload
```

This builds release binaries, captures a restore snapshot, and asks the running
manager to restart. Your windows stay in place.
