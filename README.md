# Triad

Triad is a dynamic window management client for the River 0.4+ compositor. It is written in Nim, driven by data-oriented design, and architected using The Elm Architecture to ensure frame-perfect stability.

### The Triad

Triad is built on the shoulders of three compositors, each contributing one note to the chord.

River protocol is the root. A lean, principled Wayland compositor whose tag-based workspace model and clean architecture provide the foundation everything else stands on. Without it there is no key.

Mango is the third. Its per-workspace tiling is Triad's dominant character — the difference between a session with shape and one without. Triad leans into Mango heavily, and makes no apology for it.

Niri is the fifth. Not its scrolling ribbon, but its JSON IPC protocol. By speaking Niri's language over Quickshell Triad gains access to a rich shell ecosystem — Noctalia, Dankshell, and whatever comes next. The fifth is what makes harmony with other instruments possible. Here it does exactly that.

Three projects. Three philosophies. One manager that holds them in tune.

### The Quickshell Trick

Triad employs a clever architectural gambit for shell integration. It speaks fluent "Niri," broadcasting its internal state changes in a native Niri JSON stream. 

This means themes and shells built for Quickshell—such as **Noctalia-shell** or **DankMaterialShell**—integrate with Triad natively. No forks or custom modules are required. Triad provides the brain, and Quickshell provides the beauty.

### Features

*   **Hybrid Layouts:** Toggle between Scroller, Vertical Scroller, Master-Stack, Grid, and Monocle modes independently for each workspace.
*   **Smooth Animations:** Experience fluid window movement driven by a 60FPS internal clock and exponential easing.
*   **Interactive Controls:** Full keyboard and mouse support for resizing, moving, and reordering windows within stacks and columns.
*   **Scratchpad:** Banish utility windows to the shadows and summon them instantly as centered overlays.
*   **KDL Configuration:** Robust, hot-reloadable configuration using the KDL 2.0 document language.

### Installation

Ensure you have a working River 0.4+ session. Triad is built using Nim 2.2.10+ and requires the `nimkdl`, `wayland`, `fsnotify`, and `chronicles` packages.

```bash
nimble build
./triad
```

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
```

`verify` requires a clean working tree, runs tests and builds, tidies generated
artifacts, and fails if executable binaries are tracked or left in the project.

For the first real compositor run, follow the live test runbook in
`docs/live-testing.md`.

For VT switching and compositor recovery checks, use the QEMU runbook in
`docs/qemu-vt-smoke.md`.

For daily-driver risk gates and optional `nimble verify` integrations, see
`docs/daily-driver-gates.md`.

### IPC & Navigation

Triad exposes a Unix domain socket for external control. You may interact with it using the CLI:

```bash
triad msg focus-next
triad msg toggle-overview
triad msg layout-tile
```

For a comprehensive guide to commands and the JSON state protocol, refer to `docs/ipc.md`.

### License

Triad is released under the MIT License.
