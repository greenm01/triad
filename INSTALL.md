# Installing Triad

Triad runs as a River session. River owns the Wayland compositor process;
Triad runs as the window-management client inside that session.

## Quick Start With Nix

On Void, Arch, Debian, Ubuntu, and other non-NixOS systems with the Nix package
manager:

```bash
nix --version
```

If `nix` reports `cannot connect to socket at '/var/nix/daemon-socket/socket'`,
start the Nix daemon before running Triad's installer.

On Void Linux with runit:

```bash
sudo ln -s /etc/sv/nix-daemon /var/service/
sleep 1
sudo sv up nix-daemon
sudo sv status nix-daemon
```

On systemd-based distributions such as Arch, Debian, and Ubuntu:

```bash
sudo systemctl enable --now nix-daemon.socket
```

Some Nix packages use `nix-daemon.service` instead of socket activation:

```bash
sudo systemctl enable --now nix-daemon.service
```

Then build and install Triad like a normal local application:

```bash
git clone https://github.com/greenm01/triad.git
cd triad
mkdir -p ~/.config/nix
grep -qxF 'experimental-features = nix-command flakes' ~/.config/nix/nix.conf 2>/dev/null \
  || printf '%s\n' 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
nix develop
tools/install_live_session.sh
```

Then log out and choose **River (Triad)** from your display manager's session
menu. The installer writes the session entry to
`/usr/share/wayland-sessions/river-triad.desktop` by default, writes the
launcher scripts and optimized Triad binaries to `~/.local/bin`, and uses
`sudo` or `doas` only for the system session file when needed. Run the
installer as your normal user, not with `sudo`, so the binaries and config land
under your home directory.

The Nix shell provides:

- Nim, Nimble, and the native libraries needed to build Triad
- River 0.4+ for the installed session launcher
- nixGL for accelerated River rendering on non-NixOS systems
- Noctalia-shell, DankMaterialShell, and Waybar
- common Wayland session utilities used by the starter config

When run from `nix develop`, `tools/install_live_session.sh` records the shell's
runtime command path in local launchers so display managers and bare TTYs can
start River and the default session utilities without inheriting the dev shell
environment. The installer writes `~/.local/bin/triad-river` as the pinned
River launcher and writes `~/.local/bin/river` when that path is absent or
already Triad-managed. Both launchers pass arguments through to River, so
`river -c other-init` still works. On non-NixOS systems the launcher uses the
Nix shell's `nixGLIntel` wrapper when available so River can use the host GPU
driver stack; set `TRIAD_RIVER_ACCEL=off` to bypass that wrapper. The installer
also pins those Nix store paths with user-local GC roots under
`~/.local/state/triad/nix-gcroots/session-runtime`, so later
`nix-collect-garbage` runs do not remove River or the session utilities that
the login launcher uses. Remove that directory only if you intentionally want a
future garbage collection to reclaim the Nix-provided session runtime.

The installer creates a starter config only when
`~/.config/triad/config.kdl` does not already exist. Existing config files and
symlinks are left in place. The starter config avoids host-specific output and
input policy and only binds applications included in the packaged session; use
`config_examples/niltempus_config.kdl` as an example for a fuller personal
setup with browser, file-manager, and app-specific window rules.

If your Nix already enables flakes, leave `~/.config/nix/nix.conf` alone. If it
does not, add this once before running `nix develop`:

```bash
mkdir -p ~/.config/nix
grep -qxF 'experimental-features = nix-command flakes' ~/.config/nix/nix.conf 2>/dev/null \
  || printf '%s\n' 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

## Add Triad To Your Login Screen

The local installer writes a system session file here:

```bash
/usr/share/wayland-sessions/river-triad.desktop
```

That is the most portable location for display managers on Void, Arch, Debian,
Ubuntu, and similar systems. To install somewhere else:

```bash
TRIAD_WAYLAND_SESSION_DIR=/usr/local/share/wayland-sessions \
  tools/install_live_session.sh
```

User-local session files are still available for display managers that support
them and do not require `sudo`:

```bash
TRIAD_WAYLAND_SESSION_DIR="$HOME/.local/share/wayland-sessions" \
  tools/install_live_session.sh
```

That writes:

```bash
~/.local/share/wayland-sessions/river-triad.desktop
```

Many display managers ignore user-local sessions, so prefer the default system
install unless you know yours scans `$XDG_DATA_HOME/wayland-sessions`.

### NixOS

For NixOS, import the flake module and enable the session declaratively:

```nix
{
  inputs.triad.url = "github:greenm01/triad";

  outputs = { nixpkgs, triad, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        triad.nixosModules.default
        {
          programs.triad.enable = true;
        }
      ];
    };
  };
}
```

Then rebuild your system and log out:

```bash
sudo nixos-rebuild switch --flake .#host
```

After that, select **River (Triad)** from the display manager.

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
~/.local/bin/triad-river
~/.local/bin/river
~/.local/bin/river-triad-session
~/.local/bin/triad-manager-loop
```

It also installs a `River (Triad)` login session. By default that desktop entry
goes to `/usr/share/wayland-sessions` and may require passwordless sudo for the
final install step. The installed binaries are built with Nim release and speed
optimizations. To install the session entry somewhere else:

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
~/.local/bin/river-triad-session
```

Return to your main desktop with `Ctrl+Alt+F1` or `Ctrl+Alt+F2`, depending on
your distribution and display manager.

To start River directly with a custom init, use the installed pass-through
launcher:

```bash
~/.local/bin/river -c ~/.local/bin/triad-manager-loop
```

### Nested Wayland Smoke Test

From an existing Wayland desktop:

```bash
WLR_BACKENDS=wayland ~/.local/bin/river -c ~/.local/bin/triad-manager-loop
```

This is useful for quick smoke testing. A real login session is the better path
for daily use because it gives River direct ownership of the Wayland session.

### Development Diagnostics

Normal sessions keep behavior JSON logs off. For a diagnostic session, enable
dev mode before starting River:

```bash
TRIAD_SESSION_DEV_MODE=1 ~/.local/bin/river-triad-session
```

Installed display-manager sessions clear inherited `TRIAD_DEV_MODE` and
`TRIAD_BEHAVIOR_LOG` so a login session is not accidentally started in
diagnostic mode. To opt a login session into diagnostics, set
`TRIAD_SESSION_DEV_MODE=1` in the session environment before launch.

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

The starter config starts Noctalia first, includes DankMaterialShell and Waybar
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
