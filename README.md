# Triad

Triad is a dynamic window management client for the River 0.4+ compositor. It is written in Nim, driven by data-oriented design, and architected using The Elm Architecture to ensure frame-perfect stability.

### The Triad

Triad draws its architectural harmony from three distinct inspirations—each contributing a vital note to form a complete chord:

*   **The Root (The River Protocol):** A lean, principled Wayland compositor that provides the rock-solid foundation for Triad's tag-based workspace model.
*   **The Major Third (Mango):** Triad adopts Mango's per-workspace hybrid tiling algorithms, giving the window manager its distinct, flexible shape.
*   **The Perfect Fifth (Niri & Quickshell):** Triad natively speaks Niri's JSON IPC language, enabling seamless integration with the rich, Qt-based Quickshell ecosystem (like Noctalia or Dank Material Shell) without the need for custom forks.

Three distinct philosophies, orchestrated by one independent manager to hold them perfectly in tune.

### Why the River protocol? A Brief Defense of the Non-Monolithic Compositor

Consider the monolithic Wayland compositor. It is the architectural equivalent of a Swiss Army knife that has somehow swallowed a blender: it manages your rendering, routes your inputs, paints your wallpapers, summons your applications, and calculates your window geometries, all while staggering under the weight of its own bloated ambition. It is, to put it mildly, a lot.

River proposes a more civilized arrangement. By embracing a non-monolithic design, River acts strictly as the competent, uncomplaining stage manager of your display. It handles the low-level indignities of hardware abstraction—talking to your monitor, parsing your keystrokes, and shuttling pixels—and then cleanly washes its hands of the matter. 

For the actual business of arranging windows, it delegates authority via a standard protocol to a dedicated layout client (such as Triad). This separation of church and state means that if your window manager crashes while attempting some avant-garde mathematical tiling algorithm, your screen does not go dark, your applications do not evaporate, and your compositor simply waits, unbothered, for the manager to restart. It is the triumph of modularity over hubris.

| Technical Benefit | The Monolithic Way | The River Protocol Way |
| :--- | :--- | :--- |
| **Crash Survivability** | A bug in the tiling math brings down the entire display server. Your unsaved work vanishes. | The layout client crashes. The compositor keeps running, your apps stay open, and the layout client quietly restarts. |
| **Atomic Rendering** | Layout calculations can result in visible jitter as windows resize unevenly across frames. | Global double-buffering ensures multi-window geometry changes are applied simultaneously. Frame-perfect perfection. |
| **Language Agnosticism** | To change how windows tile, you must rewrite C/C++/Rust inside the compositor's core. | The window manager is merely a client. You may write it in Nim, Rust, Python, or bash, and the compositor will not judge you. |
| **Hot-Swapping** | Changing core window management paradigms requires logging out and switching sessions. | You can kill one window management client and start a completely different one on the fly without losing your active windows. |
| **Security Surface** | Every client implicitly trusts the massive, omnipotent display server. | Access to the layout protocol is strictly walled off. Only the designated manager is permitted to move the furniture. |

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
