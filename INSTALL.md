# Installing Triad

Triad runs as a River session. River owns the Wayland compositor process;
Triad runs as the window-management client inside that session.

## Quick Start With Nix

```bash
git clone https://github.com/greenm01/triad.git
cd triad
nix develop
nix build .#triad
nix run .#install-session
```

Then log out and choose **River (Triad)** from your display manager's session
menu.

The Nix flake provides:

- Triad and `triad_niri`
- River
- Noctalia-shell, DankMaterialShell, and Waybar
- common Wayland session utilities used by the default config
- a user-local `River (Triad)` desktop entry

`nix run .#install-session` installs a starter config only when
`~/.config/triad/config.kdl` does not already exist.

If your Nix does not enable flakes by default, run commands with:

```bash
nix --extra-experimental-features 'nix-command flakes' build .#triad
nix --extra-experimental-features 'nix-command flakes' run .#install-session
```

## Add Triad To Your Login Screen

The Nix installer writes a user-local session file here:

```bash
~/.local/share/wayland-sessions/river-triad.desktop
```

Most display managers read user-local Wayland sessions. If yours does not, build
the session package and install the desktop entry system-wide:

```bash
nix build .#triadSession
sudo install -Dm644 result/share/wayland-sessions/river-triad.desktop \
  /usr/share/wayland-sessions/river-triad.desktop
```

After that, log out and select **River (Triad)**.

## Local Nim Install

Without Nix, install River 0.4+, Nim 2.2.4+, Nimble, and Triad's Nim package
dependencies. Then build and install the live session helpers:

```bash
nimble build -d:release
tools/install_live_session.sh
```

The installer builds optimized binaries first, then installs:

```bash
~/.local/bin/triad
~/.local/bin/triad_niri
~/.local/bin/river-triad-session
~/.local/bin/triad-manager-loop
```

It also installs a `River (Triad)` login session. By default that desktop entry
goes to `/usr/share/wayland-sessions` and may require passwordless sudo for the
final install step. To install it somewhere else:

```bash
TRIAD_WAYLAND_SESSION_DIR="$HOME/.local/share/wayland-sessions" \
  tools/install_live_session.sh
```

## Try Triad From An Existing Desktop

The safest first live test is a separate TTY. A nested Wayland session can also
work when your current compositor and wlroots backend support it.

### TTY Smoke Test

1. Press `Ctrl+Alt+F3`.
2. Log in.
3. Start River with Triad:

```bash
river -c ~/.local/bin/triad-manager-loop
```

Return to your main desktop with `Ctrl+Alt+F1` or `Ctrl+Alt+F2`, depending on
your distribution and display manager.

### Nested Wayland Smoke Test

From an existing Wayland desktop:

```bash
WLR_BACKENDS=wayland river -c ~/.local/bin/triad-manager-loop
```

This is useful for quick smoke testing. A real login session is the better path
for daily use because it gives River direct ownership of the Wayland session.

### Development Diagnostics

Normal sessions keep behavior JSON logs off. For a diagnostic session, enable
dev mode before starting River:

```bash
TRIAD_DEV_MODE=1 river -c ~/.local/bin/triad-manager-loop
```

Dev mode enables compact behavior JSONL logs unless
`TRIAD_BEHAVIOR_LOG=0` is set. You can also run `triad --dev-mode` directly
when starting the daemon by hand.

In a running Triad session, use `triad msg dev-mode status`,
`triad msg dev-mode on`, `triad msg dev-mode off`, or
`triad msg dev-mode toggle` to inspect or change the live diagnostics mode.

## Test In QEMU

For the most isolated test, run Triad in a VM. This is slower than a TTY smoke
test, but it avoids risking your current graphical session and is better for
checking VT switching, compositor startup, recovery, and session behavior.

See [docs/qemu-vt-smoke.md](docs/qemu-vt-smoke.md) for setup details.

Typical flow:

```bash
sh tools/qemu_vt_smoke.sh
```

## First Checks

Validate the config:

```bash
triad validate-config
```

Check that the IPC socket responds inside a running Triad session:

```bash
triad msg state
triad msg workspaces
triad_niri msg -j workspaces
```

Logs are written under:

```bash
~/.local/state/triad/
```

The manager loop writes `triad-latest.log` as a symlink to the newest session
log.

## Shell Profiles

The default config starts Noctalia first, includes DankMaterialShell and Waybar
as switchable shell profiles, and uses Waybar as the watchdog fallback.

The profile commands are plain argv-style config entries, so users can replace
them with any shell or bar they want:

```kdl
shells {
  active "noctalia"
  cycle "noctalia" "dank" "waybar"

  watchdog {
    enabled #true
    fallback "waybar"
  }
}
```

See [docs/configuration.md](docs/configuration.md) for the full config surface.

## Updating

For a Nix build:

```bash
git pull
nix build .#triad
```

For a local live session:

```bash
git pull
nimble liveReload
```

`nimble liveReload` builds release binaries, installs them into the live binary
directory, captures restore state, and asks the running manager to restart.

## Troubleshooting

If the login session does not appear, check where your display manager reads
Wayland session files and install `river-triad.desktop` there.

If Triad starts but the shell does not, inspect the behavior logs and session log:

```bash
ls -la ~/.local/state/triad/
tail -n 200 ~/.local/state/triad/triad-latest.log
```

If a config edit breaks startup:

```bash
triad validate-config --config ~/.config/triad/config.kdl
```

If a configured shell or helper command is missing from `PATH`, Triad logs the
failed launch. Install the missing program or update the relevant command in
`~/.config/triad/config.kdl`.
