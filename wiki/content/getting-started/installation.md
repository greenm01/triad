+++
title = "Installation"
weight = 10
+++

# Install Triad

Triad lives inside River. River handles the pixels; Triad handles the windows. 

## Get River First

Triad doesn't install River for you. Get River 0.4 or newer. River owns the GPU and the session. If River doesn't work, Triad won't either. 

### Dependencies
Install what you need for your distribution.

**Void Linux**
```bash
sudo xbps-install -S git zig pkg-config wayland-devel wayland-protocols \
  wlroots-devel libxkbcommon-devel libevdev-devel pixman-devel scdoc
```

**Arch Linux**
```bash
sudo pacman -S git zig pkgconf wayland wayland-protocols wlroots \
  libxkbcommon libevdev pixman scdoc
```

**Debian / Ubuntu**
```bash
sudo apt install git zig pkg-config libwayland-dev wayland-protocols \
  libwlroots-dev libxkbcommon-dev libevdev-dev libpixman-1-dev scdoc
```

**Fedora**
```bash
sudo dnf install git zig pkgconf wayland-devel wayland-protocols-devel \
  wlroots-devel libxkbcommon-devel libevdev-devel pixman-devel scdoc
```

### Build River
Build it for speed. 
```bash
git clone https://codeberg.org/river/river.git
cd river
zig build -Doptimize=ReleaseSafe -Dcpu=baseline -Dstrip -Dpie \
  -Dxwayland --prefix "$HOME/.local" install
```

## Get Nim and Triad

Triad is written in Nim. You need Nim 2.2.4 or newer.

### Dependencies
**Void Linux**
```bash
sudo xbps-install -S nim nimble pkg-config wayland-devel libxkbcommon-devel pixman-devel
```

**Arch Linux**
```bash
sudo pacman -S nim nimble pkgconf wayland libxkbcommon pixman
```

**Debian / Ubuntu**
```bash
sudo apt install nim nimble pkg-config libwayland-dev libxkbcommon-dev libpixman-1-dev
```

**Fedora**
```bash
sudo dnf install nim nimble pkgconf wayland-devel libxkbcommon-devel pixman-devel
```

If your Nim is old, use `choosenim`:
```bash
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
choosenim 2.2.4
```

### Build Triad
```bash
git clone https://github.com/greenm01/triad.git
cd triad
nimble installSession
```

## Test Before You Leap

Don't log out yet. Test Triad from your current desktop. 
```bash
WLR_BACKENDS=wayland ~/.local/bin/triad session
```
If it opens a window, you're golden. If it fails, check your config.

Once it passes, log out. Choose **River (Triad)** at your login screen. The installer puts the session file in `/usr/share/wayland-sessions/` and the binaries in `~/.local/bin`. 

## Your First Run

Triad starts empty. No bar. No wallpaper. Just a cursor and a hotkey guide. This is normal. 

Before you dive in, edit `~/.config/triad/config.kdl`. Set your terminal.
```kdl
bind "Super+Return" "spawn foot"
```
Replace `foot` with whatever you use. Press `Super+?` to see your keys. 

## The Starter Config

We don't choose your tools. We don't pick your bar or your browser. Our starter config is a skeleton. Install what you like, then tell Triad where to find it. 

Check `examples/config/niltempus_config.kdl` for a full setup. It’s a reference, not a law.

## TTY Smoke Test

Still unsure? Try a TTY.
1. `Ctrl+Alt+F3`.
2. Log in.
3. Run `~/.local/bin/triad session`.

If it works, you’re ready.

## Keep It Valid

Always check your config after an edit:
```bash
triad validate-config
```

If things go wrong, check the logs:
```bash
triad logs
```
Look at `triad-session-latest.log` first.

## Update

Stay current.
```bash
git pull
nimble liveReload
```
`liveReload` builds the new version, checks the running session, saves your
state, and restarts the manager while you work. If the session is stale, it tells
you when to restart River/Triad.
