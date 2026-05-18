# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a programmable Wayland window manager for River. Built-in dynamic layouts are one policy layer; Janet lets users define their own placement models. Triad separates display from policy: River handles the Wayland protocol while Triad manages window placement. This decoupling ensures resilience; if Triad restarts, your windows remain in place.

Triad treats your session as flat data. Windows carry tags rather than living in a rigid hierarchy. This makes conditional logic efficient, turning window management into a scriptable engine.

Need a screen lock? See [LockMe](https://github.com/greenm01/lockme).

### The Triad

Triad is built on **Tags**, **Rules**, and **IPC**.

Tags provide stable, concurrent labels for windows. Rules, written in KDL, provide declarative defaults. IPC exposes a snapshot of the model over a Unix socket. Together, they allow external scripts to serve as a policy layer. A script can query the number of windows on a tag or the current layout before placing a new application.

### Scriptable Policy with Janet

Static rules cover the predictable. [Janet](https://janet-lang.org/) covers everything else.

Some window behavior can't be expressed as a rule: send GIMP to a dedicated workspace, but only if one exists; float a dialog when its parent is already open; switch the layout when a particular app arrives. Triad embeds Janet—a small Lisp—so you can write that logic directly, in plain code, without running a separate process or piping commands through a shell.

Scripts live in `~/.config/triad/janet/` and react to session events as they happen. Open an app and it lands where you want it. Close it and the workspace cleans up. Switch tags and the layout follows. All of it expressed once, in one place.

That scripting surface is also where users can create custom layouts: Janet can describe window placement across algorithmic tiling, scrollable strips, BSP/tree policies, frame/tab systems, and floating placement without baking every paradigm into the compositor. See the layout taxonomy in [docs/tiling_wm_categories.md](docs/tiling_wm_categories.md).

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

https://codeberg.org/river/river

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
