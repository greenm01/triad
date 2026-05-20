# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a programmable Wayland window manager for River. River handles
Wayland; Triad handles placement, policy, IPC, and scripting. If Triad
restarts, your windows stay where they are.

Triad treats your session as data. Windows carry tags instead of living in a
fixed tree, so rules and scripts can make placement decisions from the current
state.

Need a screen lock? See [LockMe](https://github.com/greenm01/lockme).

### Multi-Paradigm Layouts

Triad ships with `scroller`, `dwindle`, `bsp`, `i3`, `notion`, `tile`,
`grid`, `monocle`, `deck`, `spiral`, `tgmix`, and
[many other built-in layouts](docs/tiling_wm_categories.md#layout-index). Each
workspace can choose its own layout.

You can also set layout-specific key bindings.

The layout model is not tied to one tiling family. Built-in and Janet layouts
can express algorithmic tiling, scrollable strips, BSP/tree policies, frame/tab
systems, and floating placement from the same session data.

### Features at a Glance

* **Crash resilience:** Layout errors do not affect your compositor session.
* **Waybar and Quickshell ready:** Niri-shaped JSON works with popular shell ecosystems.
* **Dynamic workspaces:** Spawns workspaces when needed and prunes them when empty.
* **Smooth motion:** Uses configurable frame pacing and exponential easing for window movement.
* **Scratchpad:** Manages utility windows as centered overlays.
* **Stable identity:** Keeps tag and window IDs stable for long-running scripts.

### Tags, Rules, and IPC

Triad is built on **tags**, **rules**, and **IPC**.

Tags are stable, concurrent labels for windows. Rules, written in KDL, provide
declarative defaults. IPC exposes a snapshot of the model over a Unix socket.
Together, they let external scripts act as a policy layer. A script can query
the number of windows on a tag or the current layout before placing a new
application.

### Scriptable Policy with Janet

Static rules cover the predictable. [Janet](https://janet-lang.org/) covers the
rest.

Some window behavior cannot be expressed as a rule: send GIMP to a dedicated
workspace, but only if one exists; float a dialog when its parent is already
open; switch the layout when a particular app arrives. Triad embeds Janet, a
small, fast Lisp, so you can write that logic directly without running a
separate process or piping commands through a shell.

Janet fits Triad's architecture: it is data-oriented, and its immutable values
map cleanly onto Triad's snapshot-in, messages-out runtime model.

Janet is a modern, executable successor to the static ICCCM and EWMH hints that
X11 apps used to describe their placement preferences. Instead of rigid binary
properties, a script can read context and respond to it.

Scripts live in `~/.config/triad/janet/` and react to session events as they
happen. Open an app and it lands where you want it. Close it and the workspace
cleans up. Switch tags and the layout follows. All of it is expressed once, in
one place.

You can also use Janet to create custom layouts. For the layout taxonomy, see
[docs/tiling_wm_categories.md](docs/tiling_wm_categories.md).

### The Shell Ecosystem

Triad natively supports both Waybar and Quickshell.

Triad has a native JSON stream, and it also projects state as Niri-shaped JSON.
You can use existing Waybar configurations or Quickshell themes, such as
**Noctalia-shell** or **DankMaterialShell**, without modification.

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

`verify` requires a clean working tree, runs tests and builds, tidies generated
artifacts, and ensures no executable binaries are left behind. For
runtime-facing work, run `nimble liveReload` from inside a live session.

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

For the full command and JSON state protocol guide, see `docs/ipc.md`.

### License

Triad is released under the MIT License.
