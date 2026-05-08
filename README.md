# Triad

Triad is a dynamic window management client for the River 0.4+ compositor. It is written in Nim, driven by data-oriented design, and architected using The Elm Architecture to ensure frame-perfect stability.

### The Triad

The name is no accident. Triad represents the synthesis of three great software philosophies: the robust Wayland foundation of **River**, the versatile per-workspace tiling of **Mango**, and the infinite, animated scrolling ribbon of **Niri**. 

It is a hybrid manager that refuses to compromise. Whether you require a traditional master-stack layout for development or an expansive scrolling canvas for research, Triad adapts to your workflow on a per-tag basis.

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

Ensure you have a working River 0.4+ session. Triad is built using Nim and requires the `nimkdl`, `wayland`, `fsnotify`, and `chronicles` packages.

```bash
nimble build
./triad
```

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
