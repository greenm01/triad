# Triad

https://github.com/user-attachments/assets/27e4bde8-95fc-40cf-9830-5373ac0bcc74

Triad is a dynamic window-management client for the River 0.4+ compositor.
It is written in Nim and built around a data-oriented runtime model. River
keeps the display alive. Triad decides where windows go. Shells get clean
state projections. Everyone has a job. Everyone stays in their lane.

Need a good screen lock? See LockMe at https://github.com/greenm01/lockme.

### The Triad

Triad's architecture has three parts:

* **Protocol:** River owns the Wayland session, input, outputs, and atomic
  surface placement.
* **Model:** Triad owns window-management policy in one canonical,
  data-oriented runtime model.
* **Projection:** IPC clients like Waybar and Quickshell consume snapshots of that model,
  including Niri-shaped JSON for existing shell ecosystems.

That is the trinity: protocol, model, projection. Not a theme. A boundary.

### Why the River Protocol?

River is a dynamic tiling Wayland compositor whose window management is driven
by an external layout generator. It uses tags instead of fixed workspaces. That
is the opening Triad needs.

The compositor keeps doing compositor work: outputs, input, surfaces, and
atomic commits. Triad does manager work: tags, columns, focus, scratchpads,
restore state, layout policy, and shell state. If the manager is restarted, the
display does not have to be. This is not glamorous. It is better than glamorous.

| Technical Benefit    | Monolithic Compositor                      | River Layout Client              |
|:-------------------- |:------------------------------------------ |:-------------------------------- |
| **Crash safety**     | Layout bugs can end the session.           | The manager can restart alone.   |
| **Atomic placement** | Policy and rendering share one process.    | River commits final placements.  |
| **Language choice**  | Policy is tied to compositor internals.    | Triad can be Nim.                |
| **Hot swapping**     | Policy changes usually change the session. | The client can restart in place. |
| **Trust**            | More behavior lives inside the compositor. | Movement uses a narrow protocol. |

### Why DOD for a Window Manager?

Window managers are relationship engines. A window may belong to several tags.
A tag owns columns. A column orders windows. Focus has history. Scratchpads
come and go. Outputs appear, disappear, and return with opinions.

An object tree is comfortable until those relationships stop being a tree.
Triad stores runtime state as flat data with logical IDs and indexed
relationships. Systems read through queries and iterators, then mutate through
operations that keep the indexes correct. The daemon translates compositor
events into model messages and translates model effects back into compositor
actions.

The result is dull in the right places:

* **Stable identity:** Triad IDs are independent of River, Wayland, or shell
  handles.
* **Fast lookup:** hot paths use indexed tables instead of walking display
  objects and hoping.
* **Explicit relationships:** tags, columns, groups, focus, and restore state
  are modeled directly.
* **Deterministic updates:** events enter the model; effects and snapshots
  leave it.
* **Portable projections:** shell IPC is derived from canonical state, not
  from a second private truth.

Different window managers choose different shapes. Triad borrows the useful
lessons and keeps its own center.

| Manager   | Language | Design Paradigm | Role                | Layout Model               | Key Trait                                     |
| --------- | -------- | --------------- | ------------------- | -------------------------- | --------------------------------------------- |
| **Triad** | Nim      | DOD             | River layout client | Hybrid                     | Hot-restartable policy; native IPC projection |
| Mango     | C        | Suckless        | Wayland compositor  | Hybrid                     | Rich per-tag layout vocabulary                |
| niri      | Rust     | Event-driven    | Wayland compositor  | Infinite horizontal scroll | New windows never resize existing ones        |
| Hyprland  | C++      | OOP             | Wayland compositor  | Hybrid                     | Plugin ecosystem; polished UX                 |
| Sway/i3   | C        | Tree-based      | Wayland compositor  | Container tree             | Mature, predictable keyboard workflow         |
| dwm       | C        | Suckless        | X11 compositor      | Tag-based monocle/tile     | Policy lives in patched source                |
| bspwm     | C        | IPC-driven      | X11 compositor      | Binary space partition     | Precise split control via IPC                 |

[river]: https://www.mankier.com/1/river
[mango]: https://mangowm.github.io/docs/
[niri]: https://github.com/niri-wm/niri
[hyprland]: https://hypr.land/
[sway]: https://swaywm.org/
[dwm]: https://dwm.suckless.org/
[bspwm]: https://www.mankier.com/1/bspwm

### Shell Integration

Triad emits native Triad JSON and Niri-shaped JSON from the same shell snapshot.
Quickshell themes such as **Noctalia-shell** and **DankMaterialShell** can read
the Niri-shaped stream without forks. Triad provides the state. The shell makes
it presentable. A fair division of labor, and frankly overdue.

### Features

* **Hybrid Layouts:** Toggle between Scroller, Vertical Scroller,
  Master-Stack, Grid, and Monocle modes independently for each workspace.
* **Dynamic Workspaces:** Start with a configurable workspace floor, then grow
  and prune extra workspaces as they are used.
* **Smooth Animations:** Experience fluid window movement driven by a 60FPS
  internal clock and exponential easing.
* **Interactive Controls:** Use keyboard and mouse controls for resizing,
  moving, and reordering windows within stacks and columns.
* **Scratchpad:** Send utility windows away and summon them instantly as
  centered overlays.
* **KDL Configuration:** Use robust, hot-reloadable configuration through the
  KDL 2.0 document language.

### Installation

The easiest path for development is Nix. The flake provides Nim, River,
Noctalia-shell, DankMaterialShell, Waybar, and the small Wayland utilities used
by the default config.

```bash
nix develop
nimble build
nix build .#triad
```

To install a login session for your user:

```bash
nix run .#install-session
```

That writes a `River (Triad)` desktop entry under your user data directory and
installs a starter config only when `~/.config/triad/config.kdl` does not
already exist. The default config starts Noctalia first, includes Dank and
Waybar as switchable profiles, and uses Waybar as the watchdog fallback.

Without Nix, ensure you have a working River 0.4+ session. Triad is built using
Nim 2.2.10+ and requires the `nimkdl`, `wayland`, `fsnotify`, `chronicles`, and
`pixie` packages.

```bash
nimble build
./triad
```

For a local live-session install, use:

```bash
tools/install_live_session.sh
```

The live-session installer builds `nimble build -d:release` first, then installs
the optimized binaries to `~/.local/bin/triad` and `~/.local/bin/triad_niri`.

### Toolchain

Triad tracks stable Nim through `choosenim`.

```bash
choosenim update self
choosenim update stable
nim --version
```

The compiler must report Nim 2.2.10 or newer before running the full preflight.

### Development Checks

Use the normal test and build tasks while iterating:

```bash
nimble test
nimble build
nimble tidy
```

Before publishing changes, run the full local preflight:

```bash
nimble verify
nimble liveReload
```

`verify` requires a clean working tree, runs tests and builds, tidies generated
artifacts, and fails if executable binaries are tracked or left in the project.
For runtime-facing work, run `nimble liveReload` last from inside the live
session so the installed manager replacement path is covered.

For the first real compositor run, follow the live test runbook in
`docs/live-testing.md`.

For config structure and naming conventions, see `docs/configuration.md`.

For VT switching and compositor recovery checks, use the QEMU runbook in
`docs/qemu-vt-smoke.md`.

For daily-driver risk gates and optional `nimble verify` integrations, see
`docs/daily-driver-gates.md`.

### IPC & Navigation

Triad exposes a Unix domain socket for external control. You may interact with
it using the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg layout-tile
```

For a comprehensive guide to commands and the JSON state protocol, refer to
`docs/ipc.md`.

### License

Triad is released under the MIT License.
