# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a dynamic window manager for Wayland, built for the River compositor. It separates display from policy: River handles the Wayland protocol while Triad manages window placement. This decoupling ensures resilience; if Triad restarts, your windows remain in place.

Triad treats your session as flat data. Windows carry tags rather than living in a rigid hierarchy. This makes conditional logic efficient, turning window management into a scriptable engine.

Need a screen lock? See [LockMe](https://github.com/greenm01/lockme).

### The Triad

Triad is built on **Tags**, **Rules**, and **IPC**.

Tags provide stable, concurrent labels for windows. Rules, written in KDL, provide declarative defaults. IPC exposes a snapshot of the model over a Unix socket. Together, they allow external scripts to serve as a policy layer. A script can query the number of windows on a tag or the current layout before placing a new application.

### Scriptable Policy with Janet

Configuration handles the predictable; code handles the exceptions.

Triad embeds Janet—a small, data-oriented Lisp—to support conditional logic. Janet scripts receive Triad's state as native tables and execute placement functions directly, avoiding the overhead of socket communication and JSON parsing.

This enables **App Manifests**: sandboxed Janet scripts that evaluate the desktop context to dictate layout. They are executable alternatives to X11 window hints, allowing your environment to adapt based on active windows.

### Scrolling and Other Layouts

Triad features a scrolling layout that provides a fluid canvas for your workflow.

It also supports 11 other layout modes, including Master-Stack, Grid, and Monocle. You can toggle between them independently for every workspace.

### The Shell Ecosystem

Triad natively supports both Waybar and Quickshell.

While it has a native JSON stream, it also projects state as Niri-shaped JSON. You can use existing Waybar configurations or Quickshell themes—such as **Noctalia-shell** or **DankMaterialShell**—without modification.

### Features at a Glance

* **Crash Resilience:** Decoupling policy from the compositor means layout errors do not affect your session.
* **Waybar & Quickshell Ready:** Niri-shaped JSON projection ensures compatibility with popular shell ecosystems.
* **Dynamic Workspaces:** Spawns workspaces when needed and prunes them when empty.
* **Smooth Motion:** Uses configurable frame pacing and exponential easing for window movements.
* **The Scratchpad:** Manages utility windows as centered overlays.
* **Stable Identity:** Tag and window IDs remain constant for use in long-running scripts.

### Installation

For complete installation and session setup instructions, see
[INSTALL.md](INSTALL.md).

The recommended path is to install River 0.4+ from the upstream River source
instructions, then build Triad locally:

```bash
git clone https://github.com/greenm01/triad.git
cd triad
nimble installSession
```

`nimble installSession` builds optimized binaries with dev mode off by default,
then installs the session. It expects `river` 0.4+ on `PATH`, or
`TRIAD_RIVER_BIN=/path/to/river`. Nix remains available for contributors via
`nix develop`, and NixOS users can use the flake module.

### Toolchain

Triad tracks stable Nim via `choosenim`.

```bash
choosenim update self
choosenim update stable
nim --version
```

The compiler must report Nim 2.2.4 or newer before running the full preflight.

### Development Checks

Use the standard tasks while iterating:

```bash
nimble test
nimble build
nimble buildRelease
nimble tidy
```

Before publishing changes, run the full local preflight:

```bash
nimble verify
nimble liveReload
```

`verify` requires a clean working tree, runs tests and builds, tidies generated artifacts, and ensures no executable binaries are left behind. For runtime-facing work, execute `nimble liveReload` from inside a live session.

**Additional Resources:**
* **Live Testing:** `docs/live-testing.md`
* **Configuration Guide:** `docs/configuration.md`
* **VT Switching & Recovery:** `docs/qemu-vt-smoke.md`
* **Daily-Driver Gates:** `docs/daily-driver-gates.md`

### IPC & Navigation

You can interact with Triad's IPC socket directly using the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg layout-tile
```

For a comprehensive guide to commands and the JSON state protocol, see `docs/ipc.md`.

### License

Triad is released under the MIT License.
