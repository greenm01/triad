+++
title = "Installation"
weight = 10
+++

# Installing Triad

Triad runs as a River session. River owns the Wayland compositor process;
Triad runs as the window-management client inside that session.

## Recommended Local Install

Install River 0.4+ from the upstream River source instructions:

[https://codeberg.org/river/river](https://codeberg.org/river/river)

Triad intentionally does not package River for non-NixOS systems. River owns
the compositor process and the GPU/session boundary, so install and validate it
as a normal host component before installing Triad. After River is installed,
`river -version` must report 0.4 or newer.
For daily use, build River with the upstream release-optimized install command
rather than running an unoptimized development binary.

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

Install Triad's local build requirements:

- Nim 2.2.4 or newer
- Nimble
- `pkg-config`
- Wayland development headers
- `libxkbcommon`
- `pixman`

### Void Linux

```bash
sudo xbps-install -S nim nimble pkg-config wayland-devel libxkbcommon-devel pixman-devel
```

### Arch Linux

```bash
sudo pacman -S nim nimble pkgconf wayland libxkbcommon pixman
```

### Debian / Ubuntu

```bash
sudo apt install nim nimble pkg-config libwayland-dev libxkbcommon-dev libpixman-1-dev
```

If your distribution's `nim` package is older than 2.2.4, install a newer Nim
with `choosenim` before building Triad.

Then build and install Triad:

```bash
git clone https://github.com/greenm01/triad.git
cd triad
nimble installSession
```

Then log out and choose **River (Triad)** from your display manager's session
menu. The installer writes the session entry to
`/usr/share/wayland-sessions/river-triad.desktop` by default, writes the
manager script and optimized Triad binaries to `~/.local/bin`, and uses `sudo`
or `doas` only for the system session file when needed. Release builds clear
`TRIAD_DEV_MODE` by default. Run the installer as your normal user, not with
`sudo`, so the binaries and config land under your home directory.

`tools/install_live_session.sh` expects `river` 0.4+ on `PATH`. To use a
specific River build, set:

```bash
TRIAD_RIVER_BIN=/path/to/river tools/install_live_session.sh
```

The installer creates a starter config only when
`~/.config/triad/config.kdl` does not already exist. Existing config files and
symlinks are left in place. The starter config avoids host-specific output and
input policy, but it references common session tools such as `kitty`,
`fuzzel`, Noctalia, DankMaterialShell, and Waybar. Install the tools you want
or edit the shell/binding commands in `~/.config/triad/config.kdl`. Use
`examples/config/niltempus_config.kdl` as an example for a fuller personal
setup with browser, file-manager, and app-specific window rules.

## Optional Nix Dev Shell

On non-NixOS systems, Nix is only a contributor convenience. It provides the
Triad compiler/toolchain dependencies, not River or the live compositor
session:

```bash
nix develop
nimble build
nimble buildRelease
```

You still need River 0.4+ installed natively before running the live session
installer or live reload.

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

To start River directly with a custom init, use the native River binary:

```bash
river -c ~/.local/bin/triad-manager-loop
```

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

For QEMU testing details, see the qemu-vt-smoke harness in the source tree.

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
as switchable shell profiles, and uses Waybar as the watchdog fallback. Waylee
can be added as another Niri-compatible profile. These programs are normal host
dependencies; install them or replace the commands in your config.

The profile commands are plain argv-style config entries, so users can replace
them with any shell or bar they want:

```kdl
shells {
  active "noctalia"
  cycle "noctalia" "waylee" "dank" "waybar"

  watchdog {
    enabled #true
    fallback "waybar"
  }

  profile "waybar" {
    launch "waybar"
    stop "pkill" "-x" "waybar"
    niri-compat #true
  }

  profile "waylee" {
    launch "wayle"
    stop "pkill" "-x" "wayle"
    niri-compat #true
  }
}
```

The full config surface is described in the source tree under docs/configuration.md.

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
