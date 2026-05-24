# Installing Triad

Triad runs inside a River session. River owns the Wayland compositor process;
Triad is the window-management client.

## Recommended Local Install

Install River 0.4+ using the upstream River instructions:

https://codeberg.org/river/river

Triad does not install River for you. River owns the compositor, the GPU
boundary, and the login session, so install and test River before installing
Triad. After installation, `river -version` must report 0.4 or newer. For
daily use, install a release-optimized River build rather than an unoptimized
development binary.

Recommended local River build:

```bash
git clone https://codeberg.org/river/river.git
cd river
zig build -Doptimize=ReleaseSafe -Dcpu=baseline -Dstrip -Dpie \
  -Dxwayland --prefix "$HOME/.local" install
river -version
```

`-Doptimize=ReleaseSafe` keeps Zig runtime safety checks enabled while still
building an optimized binary. `-Dcpu=baseline` avoids a host-specific
`-march=native` build, and `-Dstrip -Dpie` match River's packaging
recommendations. `-Dxwayland` enables support for X11 applications through
Xwayland.

Fedora packages for a local River source build:

```bash
sudo dnf install git zig pkgconf wayland-devel wayland-protocols-devel \
  wlroots-devel libxkbcommon-devel libevdev-devel pixman-devel scdoc
```

Install Triad's local build dependencies:

- Nim 2.2.4 or newer
- Nimble
- `pkg-config`
- Wayland development headers
- `libxkbcommon`
- `pixman`

For example:

```bash
# Void Linux
sudo xbps-install -S nim nimble pkg-config wayland-devel libxkbcommon-devel pixman-devel

# Arch Linux
sudo pacman -S nim nimble pkgconf wayland libxkbcommon pixman

# Debian / Ubuntu
sudo apt install nim nimble pkg-config libwayland-dev libxkbcommon-dev libpixman-1-dev

# Fedora
sudo dnf install nim nimble pkgconf wayland-devel libxkbcommon-devel pixman-devel
```

If your distribution ships an older Nim, install a current release with
`choosenim`:

```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
choosenim 2.2.4
```

Make sure `~/.nimble/bin` is on your `PATH` before building Triad. Fedora
packages in particular may ship an older Nim.

Build and install Triad:

```bash
git clone https://github.com/greenm01/triad.git
cd triad
nimble installSession
```

Before you log out, test Triad from your current desktop:

```bash
WLR_BACKENDS=wayland river -c ~/.local/bin/triad-manager-loop
```

This catches missing River, Triad, and config setup before you switch login
sessions. See [Try Triad from an Existing Desktop](#try-triad-from-an-existing-desktop)
and [Nested Wayland Smoke Test](#nested-wayland-smoke-test).

After the smoke test passes, log out and choose **River (Triad)** from your
display manager's session menu. By default, the installer writes the session
entry to `/usr/share/wayland-sessions/river-triad.desktop` and writes the
manager script and optimized Triad binaries to `~/.local/bin`. It uses `sudo`
or `doas` only for the system session file when needed. Release builds clear
`TRIAD_DEV_MODE` by default. Run the installer as your normal user, not with
`sudo`, so binaries and config files land under your home directory.

`tools/install_live_session.sh` expects `river` 0.4+ on `PATH`. To use a
specific River build, set:

```bash
TRIAD_RIVER_BIN=/path/to/river tools/install_live_session.sh
```

The installer creates a starter config only when
`~/.config/triad/config.kdl` does not already exist. Existing config files and
symlinks are left in place.

The starter config makes no assumptions about your Linux distribution. It does
not choose your status bar, launcher, notification daemon, wallpaper tool,
browser, terminal, or application rules. It keeps shell integration disabled
and uses `foot` only as an example terminal. Install the tools you want, or
edit `~/.config/triad/config.kdl` so the commands match your system.

For a fuller personal setup, see
`examples/config/niltempus_config.kdl` in the GitHub repository. It shows shell
profiles, browser bindings, and app-specific window rules. Treat it as a
reference, not a drop-in config. Its shell commands and application rules are
for one user's machine.

## First Run

With the starter config, Triad opens to an empty desktop with a cursor and the
startup hotkey overlay. That is expected. The default config does not start a
shell, status bar, launcher, notification daemon, PipeWire, or desktop portals.
The `Super+Return` terminal binding is commented out until you set it to a
terminal installed on your system.

Before your first login session, edit `~/.config/triad/config.kdl` and set at
least one terminal binding inside the `bindings` block:

```kdl
bind "Super+Return" "spawn foot"
```

Replace `foot` with the terminal you installed. Use `Super+?` to show the
hotkey overlay again. If keybindings appear dead, check the session logs first.
A config parse error or missing manager process will show up there. If Triad is
running but no terminal, launcher, or shell is configured, the session can look
empty even though the compositor started.

## Optional Nix Dev Shell

Nix is only a contributor convenience here. It provides the Triad
compiler/toolchain dependencies, not River or the live compositor session:

```bash
nix develop
nimble build
nimble buildRelease
```

You still need River 0.4+ installed natively before running the live session
installer or live reload.

## Add Triad to Your Login Screen

The local installer writes a system session file here:

```bash
/usr/share/wayland-sessions/river-triad.desktop
```

This is the most portable location for display managers on Void, Arch, Debian,
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

## Try Triad from an Existing Desktop

The safest first live test is a separate TTY. A nested Wayland session can also
work if your current compositor and wlroots backend support it.

### TTY Smoke Test

1. Press `Ctrl+Alt+F3`.
2. Log in.
3. Start River with Triad:

```bash
~/.local/bin/river-triad-session
```

Return to your main desktop with `Ctrl+Alt+F1` or `Ctrl+Alt+F2`, depending on
your distribution and display manager.

To start River directly with a custom init, use the native River binary:

```bash
river -c ~/.local/bin/triad-manager-loop
```

### Nested Wayland Smoke Test

From an existing Wayland desktop:

```bash
WLR_BACKENDS=wayland river -c ~/.local/bin/triad-manager-loop
```

This is useful for quick smoke testing. For daily use, prefer a real login
session; it gives River direct ownership of the Wayland session.

### Development Diagnostics

Normal sessions keep behavior JSON logs off. For diagnostics, enable dev mode
before starting River:

```bash
TRIAD_SESSION_DEV_MODE=1 ~/.local/bin/river-triad-session
```

Installed display-manager sessions clear inherited `TRIAD_DEV_MODE` and
`TRIAD_BEHAVIOR_LOG`, which prevents accidental diagnostic login sessions. To
opt in, set `TRIAD_SESSION_DEV_MODE=1` in the session environment before
launch.

Dev mode enables compact behavior JSONL logs unless
`TRIAD_BEHAVIOR_LOG=0` is set. You can also run `triad --dev-mode` directly
when starting the daemon by hand.

In a running Triad session, use `triad msg dev-mode status`,
`triad msg dev-mode on`, `triad msg dev-mode off`, or
`triad msg dev-mode toggle` to inspect or change the live diagnostics mode.

## Test in QEMU

For the most isolated test, run Triad in a VM. This is slower than a TTY smoke
test, but it avoids your current graphical session and is better for checking
VT switching, compositor startup, recovery, and session behavior.

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

Two symlinks point to the newest logs. The session wrapper writes
`river-triad-session-latest.log` first; the manager loop writes
`triad-latest.log` once it starts. If startup fails, check the session wrapper
log first.

## Shell Profiles

Shell integration is disabled in the default config. To add a status bar,
enable shell integration and configure a profile. Waybar is the most widely
packaged option:

```kdl
shells {
  enabled #true
  active "waybar"
  cycle "waybar"

  watchdog {
    enabled #true
    fallback "waybar"
  }

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }
}
```

The profile commands are plain argv-style entries. Replace them with the shell
or bar commands you use. See `examples/config/niltempus_config.kdl` in the
GitHub repository for a setup with multiple profiles, including Noctalia and
DankMaterialShell.

### Noctalia on Fedora

Triad does not install Noctalia. Install Noctalia first, then add a Triad shell
profile that launches its command.

Noctalia's v4 Fedora docs install `noctalia-shell` from the Terra repository:

```bash
sudo dnf install --nogpgcheck --repofrompath \
  'terra,https://repos.fyralabs.com/terra$releasever' terra-release
sudo dnf install noctalia-shell
```

Then enable a profile in `~/.config/triad/config.kdl`:

```kdl
shells {
  enabled #true
  active "noctalia"
  cycle "noctalia"

  watchdog {
    enabled #true
    fallback "noctalia"
  }

  profile "noctalia" {
    launch "noctalia-shell"
    stop "pkill" "-f" "noctalia-shell"
    niri-compat #true
  }
}
```

`niri-compat #true` is required for shells that consume Niri-compatible
workspace IPC.

See [docs/configuration.md](docs/configuration.md) for the full config surface.

## Updating

To check the Nix package:

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

If Triad starts but the shell does not, inspect the session and behavior logs:

```bash
ls -la ~/.local/state/triad/
tail -n 200 ~/.local/state/triad/river-triad-session-latest.log
tail -n 200 ~/.local/state/triad/triad-latest.log
```

If a config edit breaks startup:

```bash
triad validate-config --config ~/.config/triad/config.kdl
```

If a configured shell or helper command is missing from `PATH`, Triad logs the
failed launch. Install the missing program or update the relevant command in
`~/.config/triad/config.kdl`.
